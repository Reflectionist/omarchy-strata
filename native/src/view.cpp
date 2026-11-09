#include "strata.hpp"

#include <algorithm>
#include <cmath>
#include <format>
#include <filesystem>
#include <unistd.h>

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/layout/algorithm/Algorithm.hpp>
#include <hyprland/src/layout/space/Space.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/pointer/PointerController.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>

#include "cross.hpp"
#include "overview.hpp"

namespace Strata {

    static std::unordered_map<MONITORID, SView>               g_views;
    static std::unordered_map<std::string, CStrataAlgorithm::SExpect> g_expect;
    static bool                                               g_selfFocus = false;
    static std::unordered_map<std::string, std::deque<std::string>> g_eventFiles;

    SView& viewFor(MONITORID id) {
        return g_views[id];
    }

    void postEvent(const std::string& name, const std::string& json) {
        if (!g_pEventManager)
            return;
        if (json.size() < 900) {
            g_pEventManager->postEvent(SHyprIPCEvent{name, json});
            return;
        }
        // A new file per event (readers cache by path). The last few stay: a
        // reader a few events behind (two posted in one frame) must still
        // find its file, or it drops that event.
        static uint64_t   seq  = 0;
        const char*       RT   = getenv("XDG_RUNTIME_DIR");
        const std::string PATH = std::format("{}/strata-{}-{}-{}.json", RT ? RT : "/tmp", name, getpid(), ++seq);
        {
            std::ofstream f(PATH + ".tmp", std::ios::trunc);
            f << json;
        }
        std::rename((PATH + ".tmp").c_str(), PATH.c_str());
        auto& files = g_eventFiles[name];
        files.push_back(PATH);
        while (files.size() > 8) {
            std::remove(files.front().c_str());
            files.pop_front();
        }
        g_pEventManager->postEvent(SHyprIPCEvent{name, "@" + PATH});
    }

    // On unload: this instance's files, and any a crashed one left behind.
    void eventFilesCleanup() {
        for (auto& [_, files] : g_eventFiles) {
            for (const auto& f : files)
                std::remove(f.c_str());
        }
        g_eventFiles.clear();
    }

    void eventFilesSweep() {
        const char* RT = getenv("XDG_RUNTIME_DIR");
        std::error_code ec;
        for (const auto& e : std::filesystem::directory_iterator(RT ? RT : "/tmp", ec)) {
            static const std::regex RE{R"(^strata-strata[-a-z]*-(\d+)-\d+\.json(\.tmp)?$)"};
            std::smatch             m;
            const auto              NAME = e.path().filename().string();
            if (std::regex_match(NAME, m, RE) && !std::filesystem::exists("/proc/" + m[1].str()))
                std::filesystem::remove(e.path(), ec);
        }
    }

    PHLWORKSPACE workspaceByID(WORKSPACEID id) {
        if (id == WORKSPACE_INVALID)
            return nullptr;
        for (const auto& ref : State::workspaceState()->workspaces()) {
            const auto WS = ref.lock();
            if (WS && WS->m_id == id)
                return WS;
        }
        return nullptr;
    }

    std::string addressOf(const PHLWINDOW& w) {
        return std::format("0x{:x}", reinterpret_cast<uintptr_t>(w.get()));
    }

    PHLWINDOW windowByAddress(const std::string& address) {
        for (const auto& w : Desktop::windowState()->windows()) {
            if (addressOf(w) == address)
                return w;
        }
        return nullptr;
    }

    CStrataAlgorithm* strataFor(const PHLWORKSPACE& ws) {
        if (!ws || ws->m_isSpecialWorkspace || !ws->m_space)
            return nullptr;
        const auto A = ws->m_space->algorithm();
        if (!A || !A->tiledAlgo())
            return nullptr;
        return dynamic_cast<CStrataAlgorithm*>(A->tiledAlgo().get());
    }

    CStrataAlgorithm* activeStrata(PHLMONITOR* monOut) {
        const auto MON = Desktop::focusState()->monitor();
        if (!MON)
            return nullptr;
        if (monOut)
            *monOut = MON;
        if (MON->m_activeSpecialWorkspace)
            return nullptr;
        return strataFor(MON->m_activeWorkspace);
    }

    static std::vector<CStrataAlgorithm*> rowsOn(MONITORID id) {
        std::vector<CStrataAlgorithm*> out;
        for (const auto& ref : State::workspaceState()->workspaces()) {
            const auto WS = ref.lock();
            if (!WS || !WS->m_monitor || WS->m_monitor->m_id != id)
                continue;
            if (auto* a = strataFor(WS))
                out.push_back(a);
        }
        return out;
    }

    void recalcMonitor(MONITORID id, bool animate) {
        for (auto* a : rowsOn(id))
            a->m_scrollingData->recalculate(!animate);
    }

    void fitSlot(SView& v, double x, double w) {
        if (w >= 1.0 - EPS)
            v.camera = x + (w - 1.0) / 2.0;
        else if (x < v.camera)
            v.camera = x;
        else if (x + w > v.camera + 1.0)
            v.camera = x + w - 1.0;
    }

    std::pair<double, double> bounds(MONITORID id) {
        double lo = INFINITY, hi = -INFINITY;
        for (auto* a : rowsOn(id)) {
            a->normalize();
            for (const auto& c : a->m_scrollingData->columns) {
                lo = std::min(lo, a->xOf(c));
                hi = std::max(hi, a->xOf(c) + a->effW(c));
            }
        }
        if (lo > hi)
            return {0.0, 1.0};
        return {lo, hi};
    }

    double slotWidth() {
        static const auto PCOLWIDTH = CConfigValue<Config::FLOAT>("scrolling:column_width");
        const double      W         = g_cfg.slotWidth->value();
        return std::clamp(W > 0.0 ? W : (double)*PCOLWIDTH, 0.05, 1.0);
    }

    void setCursorTo(CStrataAlgorithm* a, const SP<SColumnData>& c) {
        auto& v   = a->view();
        v.cursorX = a->xOf(c);
        v.cursorW = a->effW(c);
        v.blank   = false;
    }

    static void warp(const Vector2D& pos) {
        static const auto PNOWARPS = CConfigValue<Config::INTEGER>("cursor:no_warps");
        if (!*PNOWARPS)
            Pointer::pointerController()->warpTo(pos);
    }

    void focusWindow(PHLWINDOW w) {
        if (!w)
            return;
        g_selfFocus = true;
        Desktop::focusState()->fullWindowFocus(w, Desktop::FOCUS_REASON_KEYBIND);
        g_selfFocus = false;
        if (auto* a = strataFor(w->m_workspace)) {
            a->m_lastFocus = w;
            if (const auto D = a->dataFor(w->layoutTarget()); D && D->column)
                D->column->lastFocusedTarget = D;
        }
    }

    void unfocus() {
        g_selfFocus = true;
        Desktop::focusState()->fullWindowFocus(nullptr, Desktop::FOCUS_REASON_KEYBIND);
        g_selfFocus = false;
    }

    // Where the cursor slot is on screen, for the pointer and overlays.
    static Vector2D slotCenter(CStrataAlgorithm* a) {
        const auto& v    = a->view();
        const auto  WORK = a->workRect();
        return {WORK.x + (v.cursorX + v.cursorW / 2.0 - v.camera) * WORK.w, WORK.y + WORK.h / 2.0};
    }

    void emit() {
        PHLMONITOR MON;
        auto*      a = activeStrata(&MON);
        if (!a || !g_pEventManager)
            return;
        const auto& v       = a->view();
        const auto [lo, hi] = bounds(MON->m_id);
        const auto  WORK    = a->workRect();
        // The cursor slot on screen (monitor-local logical) for the reticle,
        // and this row's columns for the ruler.
        const double SX = WORK.x - MON->m_position.x + (v.cursorX - v.camera) * WORK.w;
        const double SY = WORK.y - MON->m_position.y;
        std::string  cols;
        for (const auto& c : a->m_scrollingData->columns) {
            if (!cols.empty())
                cols += ",";
            cols += std::format("[{:.4f},{:.4f}]", a->xOf(c), a->effW(c));
        }
        const double M = g_cfg.margin->value() * std::max(0.01, (double)g_cfg.viewStep->value());
        postEvent(
            "strata",
            std::format("{{\"ws\":{},\"camera\":{:.4f},\"x\":{:.4f},\"w\":{:.4f},\"blank\":{},\"lo\":{:.4f},\"hi\":{:.4f},\"margin\":{:.4f},"
                        "\"slot\":[{:.1f},{:.1f},{:.1f},{:.1f}],\"cols\":[{}],\"mon\":\"{}\"}}",
                        a->workspace()->m_id, v.camera, v.cursorX, v.cursorW, v.blank ? "true" : "false", lo, hi, M, SX, SY, v.cursorW * WORK.w, WORK.h, cols,
                        MON->m_name));
    }

    // Focus a column, picking the window level with the one you came from.
    static std::string goTo(CStrataAlgorithm* a, const SP<SColumnData>& c, PHLWINDOW from) {
        auto&                    v = a->view();
        SP<SScrollingTargetData> td;
        if (const auto FD = from && from->layoutTarget() ? a->dataFor(from->layoutTarget()) : nullptr; FD)
            td = a->findBestNeighbor(FD, c);
        if (!td)
            td = a->bestIn(c, 0);
        setCursorTo(a, c);
        fitSlot(v, a->xOf(c), a->effW(c));
        recalcMonitor(a->monitorID());
        if (td && td->target && td->target->window()) {
            focusWindow(td->target->window());
            warp(td->target->window()->middle());
        }
        emit();
        crossPoke("window");
        return "window";
    }

    // The overview's selector (moveH in shell/OverviewLayer.qml) mirrors these
    // rules: change them together.
    std::string nav(int dir, bool forceWrap) {
        PHLMONITOR MON;
        auto*      a = activeStrata(&MON);
        if (!a)
            return "none";

        auto& v = a->view();
        a->normalize();

        const auto FW = Desktop::focusState()->window();
        if (const auto C = a->columnOf(FW); C && FW->m_workspace == a->workspace())
            setCursorTo(a, C);

        const double L = v.cursorX, R = v.cursorX + v.cursorW;
        const double VSTEP = std::max(0.01, (double)g_cfg.viewStep->value());
        const double NEAR  = g_cfg.jumpNear->value() * VSTEP;
        const double SW    = slotWidth();
        const auto&  cols  = a->m_scrollingData->columns;

        SP<SColumnData> cand;
        for (const auto& c : cols) {
            const double X = a->xOf(c), E = X + a->effW(c);
            if (dir > 0 && X >= R - EPS && (!cand || X < a->xOf(cand)))
                cand = c;
            if (dir < 0 && E <= L + EPS && (!cand || E > a->xOf(cand) + a->effW(cand)))
                cand = c;
        }
        const double GAP = !cand ? INFINITY : dir > 0 ? a->xOf(cand) - R : L - (a->xOf(cand) + a->effW(cand));

        if (cand && GAP <= NEAR + EPS)
            return goTo(a, cand, FW);

        // Into blank space: from a window the slot starts at its edge, from
        // blank space it moves by the view step.
        const double NL = v.blank ? L + dir * VSTEP : (dir > 0 ? R : L - SW);
        const double NW = SW;

        if (cand && ((dir > 0 && NL + NW > a->xOf(cand) + EPS) || (dir < 0 && NL < a->xOf(cand) + a->effW(cand) - EPS)))
            return goTo(a, cand, FW);

        const auto [LO, HI] = bounds(MON->m_id);
        const double M      = g_cfg.margin->value() * VSTEP;
        if (NL < LO - M - EPS || NL + NW > HI + M + EPS) {
            if (!(g_cfg.wrap->value() || forceWrap)) {
                crossPoke("edge");
                return "edge";
            }
            if (!cols.empty())
                return goTo(a, dir > 0 ? cols.front() : cols.back(), FW);
            v.cursorX = dir > 0 ? LO - M : HI + M - NW;
        } else
            v.cursorX = NL;

        v.cursorW = NW;
        v.blank   = true;
        fitSlot(v, v.cursorX, v.cursorW);
        recalcMonitor(MON->m_id);
        unfocus();
        warp(slotCenter(a));
        emit();
        crossPoke("blank");
        return "blank";
    }

    std::string home() {
        PHLMONITOR MON;
        auto*      a = activeStrata(&MON);
        if (!a)
            return "none";

        PHLWINDOW w = Desktop::focusState()->window();
        if (!w || w->m_workspace != a->workspace() || !a->columnOf(w)) {
            w = a->m_lastFocus.lock();
            if (!w || w->m_workspace != a->workspace() || !a->columnOf(w)) {
                // Nothing remembered: the window nearest the cursor.
                w = nullptr;
                double best = INFINITY;
                for (const auto& c : a->m_scrollingData->columns) {
                    const double D = std::abs(a->xOf(c) + a->effW(c) / 2.0 - (a->view().cursorX + a->view().cursorW / 2.0));
                    if (D < best && !c->targetDatas.empty() && c->targetDatas.front()->target) {
                        best = D;
                        w    = c->targetDatas.front()->target->window();
                    }
                }
            }
        }
        if (!w)
            return "empty";

        const auto C = a->columnOf(w);
        setCursorTo(a, C);
        fitSlot(a->view(), a->xOf(C), a->effW(C));
        recalcMonitor(MON->m_id);
        focusWindow(w);
        warp(w->middle());
        emit();
        return "window";
    }

    std::string pan(double du) {
        PHLMONITOR MON;
        auto*      a = activeStrata(&MON);
        if (!a)
            return "none";
        auto&        v       = a->view();
        const auto [LO, HI]  = bounds(MON->m_id);
        const double M       = g_cfg.margin->value() * std::max(0.01, (double)g_cfg.viewStep->value());
        v.camera             = std::clamp(v.camera + du, std::min(LO - M, v.camera), std::max(HI + M - 1.0, v.camera));
        recalcMonitor(MON->m_id);
        emit();
        crossPoke("pan");
        return "ok";
    }

    // Round the camera to the nearest view step, smoothly (windows animate):
    // after a swipe or a SUPER+drag pan.
    std::string settle() {
        auto* a = activeStrata();
        if (!a)
            return "none";
        const double STEP = std::max(0.01, (double)g_cfg.viewStep->value());
        const double CAM  = a->view().camera;
        return pan(std::round(CAM / STEP) * STEP - CAM);
    }

    // After a switch to another stratum: keep the camera, focus what's under
    // the cursor there (or nothing).
    std::string land(int hint) {
        PHLMONITOR MON;
        auto*      a = activeStrata(&MON);
        if (!a)
            return "none";
        auto& v = a->view();
        a->normalize();
        v.lastWs = a->workspace()->m_id;

        if (g_cfg.landFocus->value() == std::string{"last"} && hint == 0) {
            if (const auto W = a->m_lastFocus.lock(); W && W->m_workspace == a->workspace() && a->columnOf(W)) {
                const auto C = a->columnOf(W);
                setCursorTo(a, C);
                fitSlot(v, a->xOf(C), a->effW(C));
                recalcMonitor(MON->m_id);
                focusWindow(W);
                emit();
                return "window";
            }
        }

        // The column with the most overlap with the cursor slot.
        SP<SColumnData> best;
        double          bestO = 0.0;
        for (const auto& c : a->m_scrollingData->columns) {
            const double O = std::min(v.cursorX + v.cursorW, a->xOf(c) + a->effW(c)) - std::max(v.cursorX, a->xOf(c));
            if (O > bestO + EPS) {
                bestO = O;
                best  = c;
            }
        }

        if (best) {
            const auto TD = a->bestIn(best, hint);
            setCursorTo(a, best);
            fitSlot(v, a->xOf(best), a->effW(best));
            recalcMonitor(MON->m_id);
            if (TD && TD->target && TD->target->window())
                focusWindow(TD->target->window());
            emit();
            crossPoke("stratum");
            return "window";
        }

        v.blank = true;
        unfocus();
        emit();
        crossPoke("stratum");
        return "blank";
    }

    // Put visual focus on grid x of the current stratum: the window there, or
    // a blank slot with nothing focused. Given a width, the slot is exactly
    // [x, x + w] (the overview's selection); without one it snaps to the view
    // step. Either way it moves into the gap it's in rather than cover part of
    // a window, and a gap too narrow for it means the nearest window.
    std::string aim(double x, double w) {
        PHLMONITOR MON;
        auto*      a = activeStrata(&MON);
        if (!a)
            return "none";
        a->normalize();
        if (const auto C = a->columnAt(x); C)
            return goTo(a, C, nullptr);

        const double VSTEP = std::max(0.01, (double)g_cfg.viewStep->value());
        const double SW    = w > EPS ? w : slotWidth();
        double       X     = w > EPS ? x : std::floor(x / VSTEP + EPS) * VSTEP;

        // The gap around x, and the nearest window either side of it.
        double          gl = -INFINITY, gr = INFINITY;
        SP<SColumnData> left, right;
        for (const auto& c : a->m_scrollingData->columns) {
            const double L = a->xOf(c), R = L + a->effW(c);
            if (R <= x + EPS && R > gl) {
                gl   = R;
                left = c;
            }
            if (L >= x - EPS && L < gr) {
                gr    = L;
                right = c;
            }
        }
        if (gr - gl < SW - EPS) {
            const auto NEAR = !left ? right : !right ? left : (x - gl <= gr - x ? left : right);
            if (NEAR)
                return goTo(a, NEAR, nullptr);
        }
        X = std::max(gl, std::min(X, gr - SW));

        auto& v   = a->view();
        v.cursorW = SW;
        v.cursorX = X;
        v.blank   = true;
        fitSlot(v, v.cursorX, v.cursorW);
        recalcMonitor(MON->m_id);
        unfocus();
        // Like stepping onto blank: the pointer goes there too, or whatever
        // window it was left over gets focus back half off screen.
        warp(slotCenter(a));
        emit();
        return "blank";
    }

    // The overview's SHIFT+arrows and CTRL+arrows: move or resize a window
    // that needn't have focus, by the same rules as SUPER+SHIFT+arrows. The
    // view only follows if it was on that window.
    std::string moveWindow(PHLWINDOW w, char dir) {
        auto*      a = w && !w->m_isFloating ? strataFor(w->m_workspace) : nullptr;
        const auto C = a ? a->columnOf(w) : nullptr;
        if (!C)
            return "";
        const SView BEFORE = a->view();
        const bool  ON     = !BEFORE.blank && Desktop::focusState()->window() == w;
        bool        ok     = false;
        if (dir == 'l' || dir == 'r')
            ok = a->stepMove(w, dir == 'r' ? 1 : -1, false);
        else {
            const auto   TD = a->dataFor(w->layoutTarget());
            const size_t I  = C->idx(w->layoutTarget());
            if (dir == 'u' && I > 0)
                ok = C->up(TD);
            else if (dir == 'd' && I + 1 < C->targetDatas.size())
                ok = C->down(TD);
            else
                return "edge";
        }
        if (!ON)
            a->view().restoreFrom(BEFORE);
        recalcMonitor(a->monitorID());
        emit();
        overviewRefresh();
        return ok ? "ok" : "";
    }

    bool widenWindow(PHLWINDOW w, int dir) {
        auto*      a = w && !w->m_isFloating ? strataFor(w->m_workspace) : nullptr;
        const auto C = a ? a->columnOf(w) : nullptr;
        if (!C)
            return false;
        const double F  = std::max(0.01, (double)g_cfg.fineStep->value());
        const double NW = std::clamp(std::round(C->getColumnWidth() / F + (dir > 0 ? 1 : -1)) * F, F, 1.0);
        if (std::abs(NW - C->getColumnWidth()) < EPS)
            return false;
        auto&      v  = a->view();
        const bool ON = !v.blank && std::abs(v.cursorX - a->xOf(C)) < EPS && Desktop::focusState()->window() == w;
        C->setColumnWidth((float)NW);
        a->normalize();
        if (ON)
            setCursorTo(a, C);
        recalcMonitor(a->monitorID());
        emit();
        overviewRefresh();
        return true;
    }

    void expect(const std::string& address, CStrataAlgorithm::SExpect e) {
        g_expect[address] = e;
    }

    std::optional<CStrataAlgorithm::SExpect> takeExpect(PHLWINDOW w) {
        if (!w)
            return std::nullopt;
        const auto IT = g_expect.find(addressOf(w));
        if (IT == g_expect.end())
            return std::nullopt;
        auto e = IT->second;
        g_expect.erase(IT);
        return e;
    }

    // Keyboard focus moved by something other than Strata: follow it with the
    // view (not for the pointer, which is already over the window).
    void onFocus(PHLWINDOW w, Desktop::eFocusReason reason) {
        if (g_selfFocus || !w || !w->m_workspace)
            return;
        auto* a = strataFor(w->m_workspace);
        if (!a)
            return;
        const auto C = a->columnOf(w);
        if (!C)
            return;
        a->m_lastFocus = w;

        // Switching strata keeps the camera; land() decides focus.
        if (reason == Desktop::FOCUS_REASON_WORKSPACE_CHANGE)
            return;
        if (!w->m_monitor || w->m_monitor->m_activeWorkspace != w->m_workspace)
            return;

        auto& v = a->view();

        // A window closed and Hyprland picked a replacement: keep the view.
        // One on screen takes focus; one off screen doesn't, you stay on the
        // spot you were looking at with nothing focused.
        if (reason == Desktop::FOCUS_REASON_UNMAP_WINDOW_TILING || reason == Desktop::FOCUS_REASON_UNMAP_WINDOW_FLOATING || reason == Desktop::FOCUS_REASON_UNMAP_GROUPED_WINDOW) {
            const double X = a->xOf(C), W = a->effW(C);
            if (X + W <= v.camera + EPS || X >= v.camera + 1.0 - EPS) {
                v.blank = true;
                g_pEventLoopManager->doLater([] {
                    if (auto* b = activeStrata(); b && b->view().blank)
                        unfocus();
                    emit();
                });
                return;
            }
            setCursorTo(a, C);
            emit();
            return;
        }

        setCursorTo(a, C);
        if (reason != Desktop::FOCUS_REASON_FFM && reason != Desktop::FOCUS_REASON_CLICK && !v.inhibited) {
            fitSlot(v, a->xOf(C), a->effW(C));
            recalcMonitor(a->monitorID());
        }
        emit();
    }

    // The focused window going fullscreen takes the view. Focus fitted it while
    // it was still a slot wide, so a game opened off to one side of the camera.
    // Coming back puts the view where it was: a fullscreen column is a little
    // wider than the view, and centring on it leaves the camera off the grid.
    void onFullscreen(PHLWINDOW w) {
        if (!w || !w->m_workspace || w != Desktop::focusState()->window())
            return;
        auto* a = strataFor(w->m_workspace);
        if (!a || !w->m_monitor || w->m_monitor->m_activeWorkspace != w->m_workspace)
            return;
        const auto C = a->columnOf(w);
        auto&      v = a->view();
        if (!C || v.inhibited)
            return;
        if (Fullscreen::controller()->isFullscreen(w))
            v.fsReturn = v.camera;
        else if (v.fsReturn) {
            v.camera = *v.fsReturn;
            v.fsReturn.reset();
        } else
            return;
        fitSlot(v, a->xOf(C), a->effW(C));
        recalcMonitor(a->monitorID());
        emit();
    }

    bool isPrivate(const PHLWORKSPACE& ws) {
        return ws && !g_private.empty() && g_private.contains(ws->m_name);
    }

    void onWorkspace(PHLWORKSPACE ws) {
        if (!ws || ws->m_isSpecialWorkspace || !strataFor(ws))
            return;
        auto& v = viewFor(ws->m_monitor ? ws->m_monitor->m_id : MONITOR_INVALID);
        if (v.lastWs == ws->m_id)
            return;
        const int HINT = v.landHint;
        v.landHint     = 0;
        // After Hyprland has picked its own focus for the switch.
        g_pEventLoopManager->doLater([HINT] { land(HINT); });
    }
}
