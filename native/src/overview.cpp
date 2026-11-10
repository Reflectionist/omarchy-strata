// The overview (SUPER+TAB): the whole grid, every stratum a band, zoomed out
// continuously from exactly what's on screen (and back into wherever you
// pick). Hyprland draws the bands and live windows; Strata's shell plugin
// draws names, selection and search on top and takes the input, using the
// layout posted as a "strata-overview" event.

#include "strata.hpp"

#define private public
#define protected public
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/Pass.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#undef protected
#undef private

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>

#include "anim.hpp"
#include "cross.hpp"
#include "overview.hpp"
#include "wallpaper.hpp"

namespace Strata {

    struct SOverview {
        bool                     open = false;
        Time::steady_tp          since;      // when the current zoom started
        float                    from = 0.F; // zoom at that moment (0 screen, 1 overview)
        float                    to   = 0.F;
        std::vector<WORKSPACEID> rows;       // the stack, top to bottom (INVALID: no workspace yet)
        int                      row0     = 0;   // the row the zoom starts from / lands on
        double                   camera0  = 0.0; // the camera there
        bool                     search   = false; // opened to search (SUPER+SHIFT+TAB)
        CBox                     refOpen, refLand; // the work areas of the row it opened from / lands on
        // The grid's extent it fits, as shown: eased, so a move that grows or
        // shrinks the grid rescales smoothly; held still while dragging, so
        // the pointer keeps meaning the same spot.
        double                   lo = 0.0, hi = 1.0;
        bool                     haveBounds = false;
        std::optional<std::pair<double, double>> hold;
        Time::steady_tp          lastFrame;
        float                    k = 1.F; // this frame's step towards where things are going
    };

    static std::unordered_map<MONITORID, SOverview> g_ov;

    // Windows gliding somewhere other than their live position (displaced by
    // a drag, or just dropped), in absolute virtual px.
    struct SShown {
        CBox         box;
        PHLWINDOWREF w;
    };
    static std::unordered_map<const Desktop::View::CWindow*, SShown> g_shown;

    static PHLMONITORREF                            g_ovFrameMon;

    constexpr float ZOOM_SECONDS = 0.32F;
    constexpr float ROW_GAP      = 0.08F; // between bands, in screen heights

    static float easeInOut(float x) {
        return x < 0.5F ? 4.F * x * x * x : 1.F - std::pow(-2.F * x + 2.F, 3.F) / 2.F;
    }

    static float zoomOf(const SOverview& o) {
        if (g_cfg.debugZoom && g_cfg.debugZoom->value() >= 0.F && (o.open || o.to > 0.F))
            return g_cfg.debugZoom->value();
        const float P = std::clamp(std::chrono::duration<float>(Time::steadyNow() - o.since).count() / ZOOM_SECONDS, 0.F, 1.F);
        return o.from + (o.to - o.from) * easeInOut(P);
    }

    static bool animating(const SOverview& o) {
        return std::chrono::duration<float>(Time::steadyNow() - o.since).count() < ZOOM_SECONDS;
    }

    bool overviewOpen(MONITORID id) {
        const auto IT = g_ov.find(id);
        return IT != g_ov.end() && (IT->second.open || animating(IT->second));
    }

    // Grid -> screen. A point in "virtual" space (x relative to the grid's
    // left end, y relative to the top of row 0) lands at O + s * v.
    struct STransform {
        double   s = 1.0;
        Vector2D O;
        double   u0 = 0.0; // grid x at virtual x = 0
        double   r0 = 0.0; // row at virtual y = 0
    };

    static CBox workOf(PHLMONITOR mon) {
        const auto* a = strataFor(mon->m_activeWorkspace);
        return a ? a->workRect() : CBox{mon->m_position, mon->m_size};
    }

    // The work area the overview measures the grid in at zoom z: the one of
    // the row it opened from, so that row zooms out of exactly what's on
    // screen; zooming into another row (with other gaps, e.g. a wide outer gap), it
    // blends into that row's, so the grid lands exactly with no jump first.
    static CBox refWork(const SOverview& o, float z) {
        if (o.open)
            return o.refOpen;
        const double K = std::clamp((double)z, 0.0, 1.0);
        const auto   L = [K](double land, double open) { return land + (open - land) * K; };
        return CBox{L(o.refLand.x, o.refOpen.x), L(o.refLand.y, o.refOpen.y), L(o.refLand.w, o.refOpen.w), L(o.refLand.h, o.refOpen.h)};
    }

    // Eased toward the held extent while dragging (it can be wider than the
    // grid: room past the outermost windows to drop or widen one there).
    static std::pair<double, double> shownBounds(PHLMONITOR mon, const SOverview& o) {
        if (o.haveBounds)
            return {o.lo, o.hi};
        if (o.hold)
            return *o.hold;
        return bounds(mon->m_id);
    }

    // Where the shown extent is going (what the shell is told).
    static std::pair<double, double> goalBounds(PHLMONITOR mon, const SOverview& o) {
        return o.hold ? *o.hold : bounds(mon->m_id);
    }

    static STransform transformFor(PHLMONITOR mon, const SOverview& o, float z, std::pair<double, double> B, double* lo, double* hi) {
        const auto  WORK = refWork(o, z);
        auto [LO, HI]    = B;
        // The whole travel range: everywhere SUPER+arrows can go (nav()'s
        // margin past the outermost windows) is on the band, and selectable.
        const double M   = g_cfg.margin->value() * std::max(0.01, (double)g_cfg.viewStep->value());
        LO -= M;
        HI += M;
        if (lo)
            *lo = LO;
        if (hi)
            *hi = HI;

        const double PITCH = mon->m_size.y * (1.0 + ROW_GAP);
        const double ROWS  = std::max<size_t>(1, o.rows.size());
        // The grid in virtual px: width (HI-LO) usable widths, plus the
        // gutter left of the usable area; height ROWS pitches.
        const double VW = (HI - LO) * WORK.w + (WORK.x - mon->m_position.x) * 2.0;
        const double VH = ROWS * PITCH - mon->m_size.y * ROW_GAP;

        // Zoomed out: fit, with room on the left for the names.
        const double PADL = 150.0, PADR = 40.0, PADT = 60.0, PADB = 40.0;
        const double S1   = std::min((mon->m_size.x - PADL - PADR) / VW, (mon->m_size.y - PADT - PADB) / VH);
        const Vector2D O1 = mon->m_position + Vector2D{PADL + (mon->m_size.x - PADL - PADR - VW * S1) / 2.0, PADT + (mon->m_size.y - PADT - PADB - VH * S1) / 2.0};

        // On screen: the start row at the camera fills the monitor exactly.
        const double   S0 = 1.0;
        const Vector2D O0 = mon->m_position - Vector2D{(o.camera0 - LO) * WORK.w, o.row0 * PITCH};

        STransform t;
        t.s  = std::exp(std::log(S0) * (1.0 - z) + std::log(S1) * z);
        // Interpolate the screen position of the start view's top-left
        // corner, so it shrinks smoothly into its band.
        const Vector2D A0 = O0 + Vector2D{(o.camera0 - LO) * WORK.w, o.row0 * PITCH} * S0;
        const Vector2D A1 = O1 + Vector2D{(o.camera0 - LO) * WORK.w, o.row0 * PITCH} * S1;
        const Vector2D A  = A0 + (A1 - A0) * z;
        t.O               = A - Vector2D{(o.camera0 - LO) * WORK.w, o.row0 * PITCH} * t.s;
        t.u0              = LO;
        return t;
    }

    // Where a window sits in the overview, in virtual px (x from the grid's
    // left end, y from the top of row 0). Every row is laid out on the shared
    // grid in REF's units, whatever its own work area: a stratum with wider
    // gaps (a wide outer gap) still lines up column for column. Windows keep
    // their aspect; one from a row with a wider work area than REF shrinks to
    // fit its grid slot. A tiled window also gets its column on the grid, which
    // is what the selection moves by.
    struct SPlaced {
        CBox                  box;
        std::optional<double> gx, gw; // its column, in grid units (tiled only)
        int                   ci = 0, cn = 1; // its place in the column, top to bottom
    };

    static SPlaced placeWindow(PHLMONITOR mon, const CBox& REF, double u0, double y0, PHLWINDOW w, const Vector2D& pos, const Vector2D& size) {
        auto*        a    = strataFor(w->m_workspace);
        const CBox   WORK = a ? a->workRect() : REF;
        const double CAM  = viewFor(mon->m_id).camera;
        const double K    = std::min(1.0, REF.w / std::max(1.0, WORK.w));
        const double GUT  = REF.x - mon->m_position.x;

        SPlaced p;
        double  vx;
        if (const auto C = a && !w->m_isFloating ? a->columnOf(w) : nullptr; C) {
            p.gx = a->xOf(C);
            p.gw = a->effW(C);
            for (size_t i = 0; i < C->targetDatas.size(); ++i) {
                if (C->targetDatas[i]->target && C->targetDatas[i]->target->window() == w)
                    p.ci = (int)i;
            }
            p.cn = (int)C->targetDatas.size();
            // Its column's place on the grid, plus where it sits in that slot (gaps).
            const double SLOT = WORK.x + (*p.gx - CAM) * WORK.w;
            vx                = GUT + (*p.gx - u0) * REF.w + (pos.x - SLOT) * K;
        } else
            // Floating: where it is on its own screen, at the camera.
            vx = GUT + (CAM + (pos.x - WORK.x) / std::max(1.0, WORK.w) - u0) * REF.w;
        p.box = CBox{vx, y0 + (pos.y - mon->m_position.y) * K + mon->m_size.y * (1.0 - K) / 2.0, size.x * K, size.y * K};
        return p;
    }

    static void post(PHLMONITOR mon, const SOverview& o) {
        if (!g_pEventManager)
            return;
        double     lo = 0, hi = 1;
        const auto T    = transformFor(mon, o, o.open ? 1.F : 0.F, goalBounds(mon, o), &lo, &hi);
        const auto WORK = refWork(o, o.open ? 1.F : 0.F);
        const double PITCH = mon->m_size.y * (1.0 + ROW_GAP);

        std::string rows, wins;
        for (size_t r = 0; r < o.rows.size(); ++r) {
            const Vector2D TL = T.O + Vector2D{0.0, (double)r * PITCH} * T.s - mon->m_position;
            if (!rows.empty())
                rows += ",";
            rows += std::format("{{\"i\":{},\"ws\":{},\"y\":{:.1f},\"h\":{:.1f}}}", r, o.rows[r], TL.y, mon->m_size.y * T.s);
            const auto WS = workspaceByID(o.rows[r]);
            if (!WS)
                continue;
            for (const auto& w : Desktop::windowState()->windows()) {
                if (!w || !w->m_isMapped || w->m_workspace != WS || w->m_hidden)
                    continue;
                // Where it's going, not where an animation has it right now.
                const auto     PL = placeWindow(mon, WORK, T.u0, r * PITCH, w, w->positionAnimation()->goal() + w->m_floatingOffset, w->sizeAnimation()->goal());
                const Vector2D P  = T.O + PL.box.pos() * T.s - mon->m_position;
                std::string    title = w->m_title, cls = w->m_class;
                for (auto* str : {&title, &cls}) {
                    std::string esc;
                    for (char c : *str) {
                        if (c == '"' || c == '\\')
                            esc += '\\';
                        if ((unsigned char)c >= 0x20)
                            esc += c;
                    }
                    *str = esc;
                }
                if (!wins.empty())
                    wins += ",";
                const auto GRID = PL.gx ? std::format("\"gx\":{:.6f},\"gw\":{:.6f},\"ci\":{},\"cn\":{}", *PL.gx, *PL.gw, PL.ci, PL.cn) : std::string{"\"gx\":null"};
                wins += std::format("{{\"a\":\"{}\",\"r\":{},\"x\":{:.1f},\"y\":{:.1f},\"w\":{:.1f},\"h\":{:.1f},{},\"t\":\"{}\",\"c\":\"{}\",\"f\":{}}}",
                                    addressOf(w), r, P.x, P.y, PL.box.w * T.s, PL.box.h * T.s, GRID, title, cls,
                                    w->m_isFloating ? "true" : "false");
            }
        }

        // Where you are on the stratum you opened it from, so the selection
        // starts there (and Enter right away changes nothing).
        std::string focus;
        double      cx = o.camera0, cw = slotWidth();
        bool        blank = true;
        if (auto* a = strataFor(mon->m_activeWorkspace)) {
            const auto& v = a->view();
            cx = v.cursorX;
            cw = v.cursorW;
            blank = v.blank;
            if (const auto W = Desktop::focusState()->window(); W && !v.blank && W->m_workspace == mon->m_activeWorkspace)
                focus = addressOf(W);
        }

        // What a point maps back to: grid x = u0 + ((X - Ox)/s - gutter)/usable width.
        // The selection moves the way SUPER+arrows do, with the same steps.
        const double VSTEP = std::max(0.01, (double)g_cfg.viewStep->value());
        postEvent(
            "strata-overview",
            std::format("{{\"open\":{},\"mon\":\"{}\",\"s\":{:.6f},\"ox\":{:.2f},\"oy\":{:.2f},\"u0\":{:.4f},\"lo\":{:.4f},\"hi\":{:.4f},\"gutter\":{:.2f},\"uw\":{:.2f},\"pitch\":{:.2f},"
                        "\"step\":{:.4f},\"vstep\":{:.4f},\"sw\":{:.4f},\"near\":{:.4f},"
                        "\"row0\":{},\"camera\":{:.6f},\"cx\":{:.6f},\"cw\":{:.6f},\"blank\":{},\"focus\":\"{}\",\"search\":{},\"wrapv\":{},\"rows\":[{}],\"windows\":[{}]}}",
                        o.open ? "true" : "false", mon->m_name, T.s, T.O.x - mon->m_position.x, T.O.y - mon->m_position.y, T.u0, lo, hi, WORK.x - mon->m_position.x, WORK.w,
                        PITCH, std::max(0.01, (double)g_cfg.step->value()), VSTEP, slotWidth(), g_cfg.jumpNear->value() * VSTEP, o.row0, o.camera0, cx, cw, blank ? "true" : "false", focus, o.search ? "true" : "false",
                        animWrap() ? "true" : "false", rows, wins));
    }

    void overviewOpenRows(const std::vector<WORKSPACEID>& rows, int current, bool search) {
        const auto MON = Desktop::focusState()->monitor();
        if (!MON || !strataFor(MON->m_activeWorkspace))
            return;
        crossHide(MON);
        auto& o = g_ov[MON->m_id];
        o.from  = zoomOf(o);
        o.to    = 1.F;
        o.since = Time::steadyNow();
        o.open  = true;
        o.search = search;
        o.rows  = rows;
        o.row0  = std::clamp(current, 0, (int)std::max<size_t>(1, rows.size()) - 1);
        o.camera0 = strataFor(MON->m_activeWorkspace)->view().camera;
        o.refOpen = o.refLand = workOf(MON);
        o.haveBounds = false;
        o.hold.reset();
        g_shown.clear();
        post(MON, o);
        g_pHyprRenderer->damageMonitor(MON);
        MON->scheduleFrame(Aquamarine::IOutput::AQ_SCHEDULE_ANIMATION);
    }

    // Close, zooming into `row` at the current camera (the caller has already
    // switched strata and moved the camera if it picked somewhere else).
    void overviewClose(int row) {
        const auto MON = Desktop::focusState()->monitor();
        if (!MON)
            return;
        auto& o = g_ov[MON->m_id];
        if (!o.open)
            return;
        overviewDragCancel();
        o.from  = zoomOf(o);
        o.to    = 0.F;
        o.since = Time::steadyNow();
        o.open  = false;
        if (row >= 0 && row < (int)o.rows.size())
            o.row0 = row;
        // Back on the desktop: no view past the edges (a drag there may have
        // moved them in).
        keepInSpan(MON->m_id, true);
        if (auto* a = strataFor(MON->m_activeWorkspace))
            o.camera0 = a->view().camera;
        o.refLand = workOf(MON);
        post(MON, o);
        g_pHyprRenderer->damageMonitor(MON);
        MON->scheduleFrame(Aquamarine::IOutput::AQ_SCHEDULE_ANIMATION);
    }

    void overviewRefresh() {
        const auto MON = Desktop::focusState()->monitor();
        if (!MON)
            return;
        const auto IT = g_ov.find(MON->m_id);
        if (IT == g_ov.end() || !IT->second.open)
            return;
        post(MON, IT->second);
        g_pHyprRenderer->damageMonitor(MON);
    }

    void overviewRows(const std::vector<WORKSPACEID>& rows) {
        const auto MON = Desktop::focusState()->monitor();
        if (!MON)
            return;
        auto& o = g_ov[MON->m_id];
        if (!o.open)
            return;
        o.rows = rows;
        overviewRefresh();
    }

    // ── Dragging windows ─────────────────────────────────────────────────
    //
    // The shell says when a drag starts and ends; everything in between
    // happens here, every frame: the window follows the pointer, the landing
    // is worked out from what's under it, the windows it would displace slide
    // aside, and the drop applies exactly what was shown.
    //
    //   over a window  its middle: stack into its column (upper half of a
    //                  window above it, lower half below); its outer quarters:
    //                  in a column of its own just before / after it
    //   over blank     right there: flush against a neighbour within one
    //                  step of it, else on the step grid
    //
    // Room is made by pushing windows right, never left, and the spot it came
    // from stays blank. Grabbed by an edge, it resizes its column instead, in
    // fine steps and for real as you go (Esc puts it back).

    enum eLandKind : uint8_t {
        LAND_NONE,
        LAND_BLANK,
        LAND_INSERT,
        LAND_STACK,
    };

    struct SLanding {
        int          row  = -1;
        eLandKind    kind = LAND_NONE;
        double       x = 0.0, w = 0.0; // its column on the grid
        PHLWINDOWREF into;             // stacking: a window of that column
        int          at = 0;           // stacking: its place there, top to bottom

        bool         same(const SLanding& o) const {
            return row == o.row && kind == o.kind && std::abs(x - o.x) < EPS && std::abs(w - o.w) < EPS && into.lock() == o.into.lock() && at == o.at;
        }
    };

    struct SDrag {
        bool            active = false;
        MONITORID       mon    = MONITOR_INVALID;
        PHLWINDOWREF    win;
        int             edge = 0;       // 0 moving; -1 / +1 resizing by the left / right edge
        Vector2D        grab{0.5, 0.5}; // where it was picked up, as a fraction of its box
        Vector2D        size;           // its box then (virtual px)
        int             fromRow = -1;
        double          width = 0.5, colWidth = 0.5; // its column's width as shown, and as set
        double          inset = 0.0, top = 0.0, bottom = 0.0; // its place in that column (virtual px, row-relative)
        bool            onIt = false;   // the view was on it
        SView           view;           // the view before
        Time::steady_tp lastHeld;

        SLanding        land;
        CBox            ghost;   // where it's drawn (absolute virtual px)
        CBox            landBox; // where it lands
        std::unordered_map<const Desktop::View::CWindow*, CBox> preview; // the windows it moves aside

        // Resizing: the row as it was.
        std::vector<std::tuple<WP<SColumnData>, double, float>> saved;
        double          left0 = 0.0, right0 = 0.0, resizeW = 0.0;

        // Dropped on another stratum: Lua moves it, then overviewDragFinish().
        PHLWINDOWREF    pending;
        PHLWORKSPACEREF fromWs;
    };
    static SDrag g_drag;

    constexpr double LIFT       = 1.03; // a dragged window, a little larger
    constexpr double STACK_GAP  = 10.0; // between windows stacked in a preview (virtual px)
    constexpr double EASE_SECS  = 0.065;

    static Vector2D goalPos(const PHLWINDOW& w) {
        return w->positionAnimation()->goal() + w->m_floatingOffset;
    }

    // A window's box where the layout is taking it, absolute virtual px.
    static CBox goalBox(PHLMONITOR mon, const CBox& REF, const PHLWINDOW& w, int row) {
        const double PITCH = mon->m_size.y * (1.0 + ROW_GAP);
        return placeWindow(mon, REF, 0.0, row * PITCH, w, goalPos(w), w->sizeAnimation()->goal()).box;
    }

    static int rowOf(const SOverview& o, const PHLWORKSPACE& ws) {
        for (size_t r = 0; r < o.rows.size(); ++r) {
            if (ws && o.rows[r] == ws->m_id)
                return (int)r;
        }
        return -1;
    }

    // A row's columns without the window being dragged (a column it had to
    // itself is gone: that spot is blank now).
    struct SRowCol {
        SP<SColumnData>        c;
        double                 x = 0.0, w = 0.0; // w as shown
        double                 cw = 0.0;         // its set width: what it has once the row has another column
        std::vector<PHLWINDOW> wins;
        bool                   had = false; // the dragged window was in it
    };

    static std::vector<SRowCol> rowColumns(const PHLWORKSPACE& ws, const PHLWINDOW& skip) {
        std::vector<SRowCol> out;
        auto*                a = ws ? strataFor(ws) : nullptr;
        if (!a)
            return out;
        for (const auto& c : a->m_scrollingData->columns) {
            SRowCol rc{.c = c, .x = a->xOf(c), .w = a->effW(c), .cw = c->getColumnWidth()};
            for (const auto& td : c->targetDatas) {
                const auto T = td->target.lock();
                const auto W = T ? T->window() : nullptr;
                if (W == skip)
                    rc.had = true;
                else if (W)
                    rc.wins.push_back(W);
            }
            if (!rc.wins.empty())
                out.push_back(std::move(rc));
        }
        return out;
    }

    static SLanding landingFor(PHLMONITOR mon, const SOverview& o, const CBox& REF, const Vector2D& AV, const PHLWINDOW& W) {
        auto&        d     = g_drag;
        const double PITCH = mon->m_size.y * (1.0 + ROW_GAP);
        const double GUT   = REF.x - mon->m_position.x;
        const double STEP  = std::max(0.01, (double)g_cfg.step->value());

        SLanding     l;
        l.row = std::clamp((int)std::floor((AV.y + mon->m_size.y * ROW_GAP / 2.0) / PITCH), 0, (int)std::max<size_t>(1, o.rows.size()) - 1);

        const double PX   = (AV.x - GUT) / REF.w;            // the pointer on the grid
        const double GL   = (d.ghost.x - GUT) / REF.w;       // the window's left edge, as drawn
        const auto   WS   = workspaceByID(o.rows.empty() ? WORKSPACE_INVALID : o.rows[l.row]);
        const auto   COLS = rowColumns(WS, W);
        // In a column of its own it keeps its width (a full screen when it
        // would be the row's only column and those fill the screen).
        static const auto PFSONONE = CConfigValue<Config::INTEGER>("scrolling:fullscreen_on_one_column");
        const double      WIDTH    = COLS.empty() && *PFSONONE ? 1.0 : d.colWidth;
        l.w                        = WIDTH;

        for (size_t i = 0; i < COLS.size(); ++i) {
            const auto& C = COLS[i];
            if (PX < C.x - EPS || PX >= C.x + C.w - EPS)
                continue;
            const double F = (PX - C.x) / std::max(EPS, C.w);
            if (F < 0.25) {
                l.kind = LAND_INSERT;
                l.x    = std::max(i > 0 ? COLS[i - 1].x + COLS[i - 1].cw : -INFINITY, C.x - WIDTH);
            } else if (F > 0.75) {
                l.kind = LAND_INSERT;
                l.x    = C.x + C.cw;
            } else {
                l.kind = LAND_STACK;
                l.x    = C.x;
                l.w    = C.w;
                l.into = C.wins.front();
                l.at   = (int)C.wins.size();
                for (size_t k = 0; k < C.wins.size(); ++k) {
                    const auto B = goalBox(mon, REF, C.wins[k], l.row);
                    if (AV.y < B.y + B.h / 2.0) {
                        l.at = (int)k;
                        break;
                    }
                }
            }
            return l;
        }

        l.kind                = LAND_BLANK;
        const SRowCol* prev = nullptr;
        const SRowCol* next = nullptr;
        for (const auto& C : COLS) {
            if (C.x + C.w <= PX + EPS)
                prev = &C;
            else if (!next)
                next = &C;
        }
        double x    = std::round(GL / STEP) * STEP;
        double best = STEP;
        if (prev && std::abs(GL - (prev->x + prev->cw)) < best) {
            best = std::abs(GL - (prev->x + prev->cw));
            x    = prev->x + prev->cw;
        }
        if (next && std::abs(GL + WIDTH - next->x) < best)
            x = next->x - WIDTH;
        if (prev)
            x = std::max(x, prev->x + prev->cw);
        l.x = x;
        return l;
    }

    // Where everything goes if it drops here, worked out the way the drop
    // would: the rows it leaves and lands on.
    static void buildPreview(PHLMONITOR mon, const SOverview& o, const CBox& REF) {
        auto& d = g_drag;
        d.preview.clear();
        const auto W = d.win.lock();
        if (!W)
            return;
        const double PITCH = mon->m_size.y * (1.0 + ROW_GAP);
        const double GUT   = REF.x - mon->m_position.x;

        std::vector<int> rows{d.fromRow};
        if (d.land.row != d.fromRow)
            rows.push_back(d.land.row);

        struct SPCol {
            double                 x0 = NAN, x = 0.0, w = 0.0;
            double                 now = 0.0; // the width it shows now (a lone column can fill the screen)
            std::vector<PHLWINDOW> wins;
            bool                   changed = false;
            double                 top = 0.0, bottom = 0.0, inset = 0.0, boxW = 0.0, gap = STACK_GAP;
        };

        for (const int r : rows) {
            if (r < 0 || r >= (int)o.rows.size())
                continue;
            std::vector<SPCol> cols;
            for (const auto& rc : rowColumns(workspaceByID(o.rows[r]), W)) {
                SPCol pc{.x0 = rc.x, .x = rc.x, .w = rc.cw, .now = rc.w, .wins = rc.wins, .changed = rc.had};
                std::vector<CBox> boxes;
                for (const auto& w : rc.wins)
                    boxes.push_back(goalBox(mon, REF, w, r));
                if (rc.had)
                    boxes.push_back(goalBox(mon, REF, W, r));
                pc.top    = INFINITY;
                pc.bottom = -INFINITY;
                for (const auto& b : boxes) {
                    pc.top    = std::min(pc.top, b.y);
                    pc.bottom = std::max(pc.bottom, b.y + b.h);
                }
                pc.inset = boxes.front().x - (GUT + rc.x * REF.w);
                pc.boxW  = boxes.front().w;
                std::ranges::sort(boxes, {}, &CBox::y);
                for (size_t i = 0; i + 1 < boxes.size(); ++i)
                    pc.gap = i == 0 ? boxes[1].y - (boxes[0].y + boxes[0].h) : std::min(pc.gap, boxes[i + 1].y - (boxes[i].y + boxes[i].h));
                pc.gap = std::max(0.0, pc.gap);
                cols.push_back(std::move(pc));
            }

            if (r == d.land.row) {
                if (d.land.kind == LAND_STACK) {
                    const auto INTO = d.land.into.lock();
                    for (auto& pc : cols) {
                        if (std::ranges::find(pc.wins, INTO) == pc.wins.end())
                            continue;
                        pc.wins.insert(pc.wins.begin() + std::clamp(d.land.at, 0, (int)pc.wins.size()), W);
                        pc.changed = true;
                    }
                } else if (d.land.kind != LAND_NONE) {
                    SPCol pc{.x = d.land.x, .w = d.land.w, .now = d.land.w, .wins = {W}, .changed = true};
                    pc.top    = d.top + r * PITCH;
                    pc.bottom = d.bottom + r * PITCH;
                    pc.inset  = d.inset;
                    pc.boxW   = std::max(1.0, d.size.x + (d.land.w - d.width) * REF.w);
                    size_t at = 0;
                    while (at < cols.size() && cols[at].x < d.land.x - EPS)
                        ++at;
                    cols.insert(cols.begin() + at, std::move(pc));
                    double prevEnd = -INFINITY;
                    for (auto& c : cols) {
                        c.x     = std::max(c.x, prevEnd);
                        prevEnd = c.x + c.w;
                    }
                }
            }

            // What each column will show: its own width, or the whole screen
            // when it's the row's only column and those fill it. One whose
            // shown width changes (it's left alone, or joined) is laid out
            // anew, its boxes that much wider or narrower.
            static const auto PFSONONE = CConfigValue<Config::INTEGER>("scrolling:fullscreen_on_one_column");
            for (auto& pc : cols) {
                const double SHOWN = *PFSONONE && cols.size() == 1 ? 1.0 : pc.w;
                if (std::abs(SHOWN - pc.now) > EPS) {
                    pc.boxW    = std::max(1.0, pc.boxW + (SHOWN - pc.now) * REF.w);
                    pc.now     = SHOWN;
                    pc.changed = true;
                }
            }

            for (const auto& pc : cols) {
                if (!pc.changed) {
                    if (std::abs(pc.x - pc.x0) < EPS)
                        continue;
                    for (const auto& w : pc.wins) {
                        auto b = goalBox(mon, REF, w, r);
                        b.x += (pc.x - pc.x0) * REF.w;
                        d.preview[w.get()] = b;
                    }
                    continue;
                }
                const double N = (double)pc.wins.size();
                const double H = std::max(1.0, (pc.bottom - pc.top - pc.gap * (N - 1.0)) / N);
                for (size_t i = 0; i < pc.wins.size(); ++i) {
                    const CBox B{GUT + pc.x * REF.w + pc.inset, pc.top + (double)i * (H + pc.gap), pc.boxW, H};
                    if (pc.wins[i] == W)
                        d.landBox = B;
                    else
                        d.preview[pc.wins[i].get()] = B;
                }
            }
        }
    }

    static void postDrag(PHLMONITOR mon, const SOverview& o) {
        const auto& d = g_drag;
        const auto  W = d.win.lock();
        if (!d.active || !W) {
            postEvent("strata-overview-drag", "{\"active\":false}");
            return;
        }
        if (d.edge != 0) {
            postEvent("strata-overview-drag", std::format("{{\"active\":true,\"a\":\"{}\",\"edge\":{}}}", addressOf(W), d.edge));
            return;
        }
        const auto  WORK = refWork(o, 1.F);
        const auto  T    = transformFor(mon, o, 1.F, shownBounds(mon, o), nullptr, nullptr);
        const auto  P    = T.O + (d.landBox.pos() - Vector2D{T.u0 * WORK.w, 0.0}) * T.s - mon->m_position;
        const char* KIND = d.land.kind == LAND_STACK ? "stack" : d.land.kind == LAND_INSERT ? "insert" : "blank";
        postEvent("strata-overview-drag",
                  std::format("{{\"active\":true,\"a\":\"{}\",\"edge\":0,\"row\":{},\"kind\":\"{}\",\"x\":{:.1f},\"y\":{:.1f},\"w\":{:.1f},\"h\":{:.1f}}}", addressOf(W), d.land.row, KIND,
                              P.x, P.y, d.landBox.w * T.s, d.landBox.h * T.s));
    }

    static void restoreRow(CStrataAlgorithm* a) {
        for (const auto& [wc, x, w] : g_drag.saved) {
            if (const auto C = wc.lock(); C) {
                a->setX(C, x);
                C->setColumnWidth(w);
            }
        }
    }

    // Resizing by an edge: the column's width in fine steps, the other edge
    // where it was, and whatever is on the side it grows moved over.
    static void resizeTick(const PHLWINDOW& W, double px) {
        auto&      d = g_drag;
        auto*      a = strataFor(W->m_workspace);
        const auto C = a ? a->columnOf(W) : nullptr;
        if (!C)
            return;
        const double F  = std::max(0.01, (double)g_cfg.fineStep->value());
        const double NW = std::clamp(std::round((d.edge > 0 ? px - d.left0 : d.right0 - px) / F) * F, F, 1.0);
        if (std::abs(NW - d.resizeW) < EPS)
            return;
        d.resizeW = NW;
        restoreRow(a);
        C->setColumnWidth((float)NW);
        if (d.edge < 0) {
            a->setX(C, d.right0 - NW);
            auto& cols = a->m_scrollingData->columns;
            for (int64_t i = a->m_scrollingData->idx(C) - 1; i >= 0; --i) {
                const double NEXT = a->xOf(cols[i + 1]);
                if (a->xOf(cols[i]) + a->effW(cols[i]) > NEXT + EPS)
                    a->setX(cols[i], NEXT - a->effW(cols[i]));
            }
        }
        a->normalize();
        if (d.onIt)
            setCursorTo(a, C);
        recalcMonitor(a->monitorID());
    }

    static void dragTick(PHLMONITOR mon, SOverview& o) {
        auto& d = g_drag;
        if (!d.active || d.mon != mon->m_id)
            return;
        const auto W = d.win.lock();
        if (!W || !W->m_isMapped || !W->m_workspace || W->m_isFloating) {
            overviewDragCancel();
            return;
        }
        // A release the shell never got to tell us about: let go.
        const auto NOW = Time::steadyNow();
        if (g_pInputManager->hasHeldButtons())
            d.lastHeld = NOW;
        else if (std::chrono::duration<float>(NOW - d.lastHeld).count() > 1.5F) {
            overviewDragCancel();
            return;
        }

        const float  Z    = zoomOf(o);
        const auto   WORK = refWork(o, Z);
        const auto   T    = transformFor(mon, o, Z, shownBounds(mon, o), nullptr, nullptr);
        const auto   AV   = (g_pInputManager->getMouseCoordsInternal() - T.O) / T.s + Vector2D{T.u0 * WORK.w, 0.0};
        if (d.edge != 0) {
            resizeTick(W, (AV.x - (WORK.x - mon->m_position.x)) / WORK.w);
            return;
        }
        d.ghost = CBox{AV.x - d.grab.x * d.size.x * LIFT, AV.y - d.grab.y * d.size.y * LIFT, d.size.x * LIFT, d.size.y * LIFT};
        const auto L       = landingFor(mon, o, WORK, AV, W);
        const bool CHANGED = !L.same(d.land);
        d.land             = L;
        buildPreview(mon, o, WORK);
        if (CHANGED)
            postDrag(mon, o);
    }

    bool overviewDragBegin(PHLWINDOW w, int edge, double fx, double fy) {
        const auto MON = Desktop::focusState()->monitor();
        if (!MON || !w || w->m_isFloating || Fullscreen::controller()->isFullscreen(w))
            return false;
        const auto IT = g_ov.find(MON->m_id);
        auto*      a  = strataFor(w->m_workspace);
        const auto C  = a ? a->columnOf(w) : nullptr;
        if (IT == g_ov.end() || !IT->second.open || !C)
            return false;
        auto&     o   = IT->second;
        const int ROW = rowOf(o, w->m_workspace);
        if (ROW < 0)
            return false;
        if (g_drag.active)
            overviewDragCancel();

        auto& d    = g_drag;
        d          = SDrag{};
        d.active   = true;
        d.mon      = MON->m_id;
        d.win      = w;
        d.edge     = edge < 0 ? -1 : edge > 0 ? 1 : 0;
        d.grab     = {std::clamp(fx, 0.0, 1.0), std::clamp(fy, 0.0, 1.0)};
        d.fromRow  = ROW;
        d.fromWs   = w->m_workspace;
        d.lastHeld = Time::steadyNow();
        d.view     = a->view();
        d.onIt     = !a->view().blank && Desktop::focusState()->window() == w;
        d.width    = a->effW(C);
        d.colWidth = C->getColumnWidth();

        const auto   WORK  = refWork(o, 1.F);
        const double PITCH = MON->m_size.y * (1.0 + ROW_GAP);
        const auto   B     = goalBox(MON, WORK, w, ROW);
        d.size             = B.size();
        d.inset            = B.x - (WORK.x - MON->m_position.x + a->xOf(C) * WORK.w);
        d.top              = INFINITY;
        d.bottom           = -INFINITY;
        for (const auto& td : C->targetDatas) {
            const auto T  = td->target.lock();
            const auto TW = T ? T->window() : nullptr;
            if (!TW)
                continue;
            const auto TB = goalBox(MON, WORK, TW, ROW);
            d.top         = std::min(d.top, TB.y - ROW * PITCH);
            d.bottom      = std::max(d.bottom, TB.y + TB.h - ROW * PITCH);
        }
        d.ghost = B;

        if (d.edge != 0) {
            for (const auto& c : a->m_scrollingData->columns)
                d.saved.emplace_back(c, a->xOf(c), c->getColumnWidth());
            d.left0   = a->xOf(C);
            d.right0  = a->xOf(C) + a->effW(C);
            d.resizeW = a->effW(C);
        }

        // The band holds still while dragging, with room past the outermost
        // windows (beyond any travel margin) to carry this one out there, or
        // widen it to a full screen.
        const double M     = g_cfg.margin->value() * std::max(0.01, (double)g_cfg.viewStep->value());
        const double ROOM  = std::max(0.0, (d.edge != 0 ? 1.0 - d.width : d.colWidth) - M);
        const auto [LO, HI] = goalBounds(MON, o);
        o.hold              = std::pair{LO - ROOM, HI + ROOM};
        postDrag(MON, o);
        return true;
    }

    // The view after a drop on the stratum it's on: on the window if it was
    // on it before, else where it was.
    static void settleView(CStrataAlgorithm* a, const PHLWINDOW& w) {
        auto& v = a->view();
        if (g_drag.onIt) {
            if (const auto C = a->columnOf(w); C) {
                setCursorTo(a, C);
                fitSlot(v, a->xOf(C), a->effW(C));
            }
            return;
        }
        v.restoreFrom(g_drag.view);
    }

    int overviewDragEnd(std::string* address) {
        auto& d = g_drag;
        if (!d.active)
            return -1;
        d.active      = false;
        const auto W  = d.win.lock();
        const auto IT = g_ov.find(d.mon);
        if (IT != g_ov.end())
            IT->second.hold.reset();
        postEvent("strata-overview-drag", "{\"active\":false}");
        d.preview.clear();
        if (!W || IT == g_ov.end())
            return -1;
        const auto& o = IT->second;
        auto*       a = strataFor(W->m_workspace);
        if (!a)
            return -1;

        if (d.edge != 0) {
            emit();
            overviewRefresh();
            return -1;
        }

        // It glides into place from where it was let go.
        g_shown[W.get()] = SShown{d.ghost, W};

        const auto L = d.land;
        if (L.kind == LAND_NONE || L.row < 0 || L.row >= (int)o.rows.size())
            return -1;
        const auto TO = workspaceByID(o.rows[L.row]);
        if (TO && TO == W->m_workspace) {
            const auto INTO = L.into.lock();
            if (L.kind == LAND_STACK)
                a->stackInto(W, INTO ? a->columnOf(INTO) : nullptr, L.at);
            else
                a->dropAt(W, L.x, d.colWidth);
            settleView(a, W);
            recalcMonitor(a->monitorID());
            emit();
            overviewRefresh();
            return -1;
        }

        // Another stratum: Lua moves it there (a normal move, so its rules and
        // the rest see it), and it arrives like this.
        CStrataAlgorithm::SExpect e;
        e.x = L.x;
        if (L.kind == LAND_STACK) {
            e.stack = true;
            e.at    = L.at;
        } else
            e.width = d.colWidth;
        if (address)
            *address = addressOf(W);
        expect(addressOf(W), e);
        d.pending = W;
        return L.row;
    }

    void overviewDragFinish() {
        auto&      d = g_drag;
        const auto W = d.pending.lock();
        d.pending.reset();
        if (!W)
            return;
        // Not moved after all (the stratum went from the stack meanwhile):
        // drop the landing it would have used, or its next move takes it.
        if (W->m_workspace == d.fromWs.lock())
            takeExpect(W);
        // Moved off the stratum it was on, the view stays where it was
        // (unless it was on the window: then it's left on that blank spot).
        const auto MON = Desktop::focusState()->monitor();
        if (auto* a = MON ? strataFor(MON->m_activeWorkspace) : nullptr; a && !d.onIt) {
            a->view().restoreFrom(d.view);
            recalcMonitor(a->monitorID());
        }
        emit();
        overviewRefresh();
    }

    void overviewDragCancel() {
        auto& d = g_drag;
        if (!d.active)
            return;
        d.active      = false;
        const auto W  = d.win.lock();
        const auto IT = g_ov.find(d.mon);
        if (IT != g_ov.end())
            IT->second.hold.reset();
        postEvent("strata-overview-drag", "{\"active\":false}");
        d.preview.clear();
        if (!W)
            return;
        if (d.edge != 0) {
            if (auto* a = strataFor(W->m_workspace); a) {
                restoreRow(a);
                a->normalize();
                if (d.onIt)
                    if (const auto C = a->columnOf(W); C)
                        setCursorTo(a, C);
                recalcMonitor(a->monitorID());
                emit();
            }
            overviewRefresh();
            return;
        }
        g_shown[W.get()] = SShown{d.ghost, W}; // glides home
    }

    bool overviewDropping(PHLWINDOW w) {
        return w && g_drag.pending.lock() == w;
    }

    // ── Drawing ──────────────────────────────────────────────────────────

    class COverviewPass : public IPassElement {
      public:
        COverviewPass(PHLMONITOR mon, float z) : m_mon(mon), m_z(z) {}
        virtual ~COverviewPass() = default;
        virtual std::vector<UP<IPassElement>> draw();
        virtual bool                          needsLiveBlur() {
            return false;
        }
        virtual bool needsPrecomputeBlur() {
            return false;
        }
        virtual std::optional<CBox> boundingBox() {
            return std::nullopt;
        }
        virtual CRegion opaqueRegion() {
            return {};
        }
        virtual const char* passName() {
            return "CStrataOverviewPass";
        }
        virtual ePassElementType type() {
            return EK_CUSTOM;
        }

      private:
        PHLMONITORREF m_mon;
        float         m_z;
    };

    static void rect(PHLMONITOR mon, const CBox& logicalLocal, const CHyprColor& col, int round) {
        CRectPassElement::SRectData d;
        d.box   = logicalLocal.copy().scale(mon->m_scale).round();
        d.color = col;
        d.round = round;
        Render::CRenderPass p;
        p.add(makeUnique<CRectPassElement>(d));
        renderNested(p, CRegion{d.box});
    }

    std::vector<UP<IPassElement>> COverviewPass::draw() {
        const auto MON = m_mon.lock();
        if (!MON)
            return {};
        const auto IT = g_ov.find(MON->m_id);
        if (IT == g_ov.end())
            return {};
        const auto& o = IT->second;

        const auto  NOW   = Time::steadyNow();
        const auto  WORK  = refWork(o, m_z);
        double      lo = 0, hi = 1;
        const auto  T     = transformFor(MON, o, m_z, shownBounds(MON, o), &lo, &hi);
        // Boxes are kept in absolute virtual px (not moving with the grid's
        // left end, which eases); this puts one on screen.
        const auto  SCREEN = [&](const CBox& b) { return CBox{T.O + (b.pos() - Vector2D{T.u0 * WORK.w, 0.0}) * T.s - MON->m_position, b.size() * T.s}; };
        const auto  DRAGGED = g_drag.active && g_drag.edge == 0 && g_drag.mon == MON->m_id ? g_drag.win.lock() : nullptr;
        std::erase_if(g_shown, [](const auto& e) { return e.second.w.expired(); });
        const double PITCH = MON->m_size.y * (1.0 + ROW_GAP);
        static auto PROUND = CConfigValue<Config::INTEGER>("decoration:rounding");
        const int   ROUND  = sc<int>(std::round(std::max<int64_t>(2, *PROUND) * MON->m_scale * std::max(0.3, T.s)));

        // Everything behind becomes the cross-section: an opaque backdrop as
        // soon as it starts moving, so the shrinking view isn't doubled.
        rect(MON, CBox{{}, MON->m_size}, CHyprColor{0.015F, 0.02F, 0.03F, std::clamp(m_z * 6.F, 0.F, 1.F)}, 0);

        const double VW = (hi - lo) * WORK.w + (WORK.x - MON->m_position.x) * 2.0;

        for (size_t r = 0; r < o.rows.size(); ++r) {
            // The band: the stratum's extent at this zoom.
            const Vector2D TL = T.O + Vector2D{0.0, (double)r * PITCH} * T.s - MON->m_position;
            const CBox     BAND{TL, Vector2D{VW, MON->m_size.y} * T.s};
            if (BAND.y > MON->m_size.y || BAND.y + BAND.h < 0)
                continue;
            // Each stratum on its own wallpaper, fading into its neighbours
            // across the gap instead of stopping at a hard edge.
            SP<Render::ITexture> wtex;
            Vector2D             wsize;
            const double         GAPPX = MON->m_size.y * ROW_GAP * T.s;
            if (wallpaperTexture(o.rows[r], wtex, wsize, (int)r)) {
                // Reach across the whole gap and fade out over it, so two
                // neighbours meet in a crossfade rather than at an edge.
                // Bands draw top to bottom: each runs opaque through the gap
                // below it, and the next fades in over that, so the gap is
                // a true crossfade (no dark line where both are half on).
                const bool LAST = r + 1 == o.rows.size();
                const CBox WBOX{BAND.x, BAND.y - GAPPX, BAND.w, BAND.h + GAPPX * (LAST ? 1.0 : 2.0)};
                drawCoverFaded(MON, wtex, wsize, WBOX, CBox{{}, MON->m_size}, m_z, GAPPX * 2.0, 0.0);
            } else {
                const float BANDA = (int)r == o.row0 ? 0.18F : 0.10F;
                rect(MON, BAND, CHyprColor{0.55F, 0.62F, 0.70F, BANDA * m_z}, ROUND);
            }

            const auto WS = workspaceByID(o.rows[r]);
            if (!WS)
                continue;

            // Each window where the event told the shell it is (live
            // positions here, so moves animate), clipped to its band. One a
            // drag moves aside, or just dropped, glides to where it's going.
            for (const auto& w : Desktop::windowState()->windows()) {
                if (!w || !w->m_isMapped || w->m_workspace != WS || w->m_hidden || w == DRAGGED)
                    continue;
                const auto LIVE = placeWindow(MON, WORK, 0.0, r * PITCH, w, w->positionAnimation()->value() + w->m_floatingOffset, w->sizeAnimation()->value()).box;
                const auto PIT  = DRAGGED ? g_drag.preview.find(w.get()) : g_drag.preview.end();
                auto       SIT  = g_shown.find(w.get());
                if (PIT == g_drag.preview.end() && SIT == g_shown.end()) {
                    drawWindowAt(MON, w, SCREEN(LIVE), BAND, 1.F, NOW);
                    continue;
                }
                const CBox GOAL = PIT != g_drag.preview.end() ? PIT->second : goalBox(MON, WORK, w, (int)r);
                if (SIT == g_shown.end())
                    SIT = g_shown.emplace(w.get(), SShown{LIVE, w}).first;
                auto& b = SIT->second.box;
                b       = CBox{b.x + (GOAL.x - b.x) * o.k, b.y + (GOAL.y - b.y) * o.k, b.w + (GOAL.w - b.w) * o.k, b.h + (GOAL.h - b.h) * o.k};
                drawWindowAt(MON, w, SCREEN(b), CBox{{}, MON->m_size}, 1.F, NOW);
                const auto NEAR = [](const CBox& x, const CBox& y) { return std::abs(x.x - y.x) + std::abs(x.y - y.y) + std::abs(x.w - y.w) + std::abs(x.h - y.h) < 1.0; };
                if (PIT == g_drag.preview.end() && NEAR(b, GOAL) && NEAR(LIVE, GOAL))
                    g_shown.erase(SIT); // settled: back to its live position
            }
            if (!WS->isVisible())
                g_pHyprRenderer->sendFrameEventsToWorkspace(MON, WS, NOW);
        }

        // The window being dragged, over everything, lifted off the grid.
        if (DRAGGED) {
            const auto G = SCREEN(g_drag.ghost);
            rect(MON, CBox{G.x + 4.0, G.y + 8.0, G.w, G.h}, CHyprColor{0.F, 0.F, 0.F, 0.3F}, ROUND);
            drawWindowAt(MON, DRAGGED, G, CBox{{}, MON->m_size}, 0.88F, NOW);
            if (const auto WS = DRAGGED->m_workspace; WS && !WS->isVisible())
                g_pHyprRenderer->sendFrameEventsToWorkspace(MON, WS, NOW);
        }
        return {};
    }

    void overviewRenderPre(PHLMONITOR mon) {
        g_ovFrameMon = mon;
        if (!mon || !overviewOpen(mon->m_id))
            return;
        auto&       o   = g_ov[mon->m_id];
        const auto  NOW = Time::steadyNow();
        const float DT  = std::clamp(std::chrono::duration<float>(NOW - o.lastFrame).count(), 0.F, 0.1F);
        o.lastFrame     = NOW;
        o.k             = 1.F - std::exp(-DT / (float)EASE_SECS);
        {
            const auto [LO, HI] = o.hold ? *o.hold : bounds(mon->m_id);
            if (!o.haveBounds) {
                o.lo         = LO;
                o.hi         = HI;
                o.haveBounds = true;
            } else {
                o.lo = std::abs(LO - o.lo) < 1e-4 ? LO : o.lo + (LO - o.lo) * o.k;
                o.hi = std::abs(HI - o.hi) < 1e-4 ? HI : o.hi + (HI - o.hi) * o.k;
            }
        }
        dragTick(mon, o);
        g_pHyprRenderer->damageMonitor(mon);
    }

    void overviewRenderStage(eRenderStage stage) {
        if (stage == RENDER_POST) {
            const auto MON = g_ovFrameMon.lock();
            if (MON && overviewOpen(MON->m_id))
                MON->scheduleFrame(Aquamarine::IOutput::AQ_SCHEDULE_ANIMATION);
            return;
        }
        if (stage != RENDER_POST_WINDOWS)
            return;
        const auto MON = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!MON || !overviewOpen(MON->m_id))
            return;
        const float Z = zoomOf(g_ov[MON->m_id]);
        if (Z > 0.F)
            g_pHyprRenderer->currentPass().add(makeUnique<COverviewPass>(MON, Z));
    }

    void overviewCleanup() {
        g_ov.clear();
        g_shown.clear();
        g_drag = SDrag{};
    }
}
