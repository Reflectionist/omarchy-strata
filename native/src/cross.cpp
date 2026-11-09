// The preview cross: the current view flanked by what's left/right of it on
// this stratum and by the strata above/below at the same x, drawn live by
// Hyprland after the windows. Strata's shell plugin draws the frames and
// labels on top (it gets the tile boxes as a "strata-cross" event).
//
// Each window is drawn by Hyprland's own renderWindow into a private pass,
// with its geometry set to its place in a tile for the duration and its
// surfaces clipped to the tile (the technique Hyprland overview plugins use).

#include "strata.hpp"

#define private public
#define protected public
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/pass/Pass.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/SurfacePassElement.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#undef protected
#undef private

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/layout/space/Space.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>
#include <hyprutils/utils/ScopeGuard.hpp>

#include "cross.hpp"
#include "overview.hpp"
#include "wallpaper.hpp"
#include "anim.hpp"

namespace Strata {

    struct SCross {
        Time::steady_tp shown;      // when it started appearing
        Time::steady_tp hideAt;     // when it starts fading out (move/change triggers)
        bool            visible = false;
        bool            held    = false; // shown until a key release ends it
        bool            hidePosted = false; // the shell has been told it's fading
    };

    static std::unordered_map<MONITORID, SCross> g_cross;
    static PHLMONITORREF                         g_frameMon;

    constexpr float FADE_IN  = 0.12F;
    constexpr float FADE_OUT = 0.18F;

    static float secondsSince(const Time::steady_tp& t) {
        return std::chrono::duration<float>(Time::steadyNow() - t).count();
    }

    static float crossAlpha(const SCross& c) {
        if (!c.visible && c.shown == Time::steady_tp{})
            return 0.F;
        const float IN = std::clamp(secondsSince(c.shown) / FADE_IN, 0.F, 1.F);
        if (c.held || Time::steadyNow() < c.hideAt)
            return c.visible ? IN : 0.F;
        const float OUT = 1.F - std::clamp(secondsSince(c.hideAt) / FADE_OUT, 0.F, 1.F);
        return IN * OUT;
    }

    static bool crossActive(MONITORID id) {
        const auto IT = g_cross.find(id);
        return IT != g_cross.end() && crossAlpha(IT->second) > 0.F;
    }

    // Tile boxes in monitor-local logical coordinates.
    std::vector<STile> crossTiles(PHLMONITOR mon) {
        std::vector<STile> t;
        if (!mon)
            return t;
        const auto  SIZE  = mon->m_size;
        const float S     = std::clamp(g_cfg.crossSize->value(), 0.05F, 0.45F);
        const float GAP   = 6.F;
        const float W     = SIZE.x * S;
        const float H     = W * SIZE.y / std::max(1.0, SIZE.x);
        const float TOTW  = 2.F * W + 2.F * GAP;
        const float TOTH  = 3.F * H + 2.F * GAP;
        const auto  PLACE = std::string{g_cfg.crossPlacement->value()};

        float x0 = (SIZE.x - TOTW) / 2.F, y0 = SIZE.y - TOTH - 28.F;
        if (PLACE == "center")
            y0 = (SIZE.y - TOTH) / 2.F;
        else if (PLACE == "topleft") {
            x0 = 14.F;
            y0 = 14.F;
            if (auto* a = strataFor(mon->m_activeWorkspace))
                y0 = std::max(14.0, a->workRect().y - mon->m_position.y);
        }

        const float CX  = x0 + W / 2.F + GAP;
        const float MY  = y0 + H + GAP;
        const auto  ACT = mon->m_activeWorkspace;
        // Above and below from the stack order (none outside the stack).
        WORKSPACEID up = WORKSPACE_INVALID, down = WORKSPACE_INVALID;
        int         upRow = -1, downRow = -1;
        if (ACT)
            stackNeighbours(ACT->m_id, up, down, &upRow, &downRow);
        t.push_back({"left", CBox{x0, MY, W / 2.F, H}, ACT ? ACT->m_id : WORKSPACE_INVALID, -0.5, 0.5});
        t.push_back({"center", CBox{CX, MY, W, H}, ACT ? ACT->m_id : WORKSPACE_INVALID, 0.0, 1.0});
        t.push_back({"right", CBox{CX + W + GAP, MY, W / 2.F, H}, ACT ? ACT->m_id : WORKSPACE_INVALID, 1.0, 0.5});
        t.push_back({"up", CBox{CX, y0, W, H}, up, 0.0, 1.0, upRow});
        t.push_back({"down", CBox{CX, MY + H + GAP, W, H}, down, 0.0, 1.0, downRow});
        return t;
    }

    static void postCross(PHLMONITOR mon, bool show) {
        if (!g_pEventManager || !mon)
            return;
        std::string tiles;
        for (const auto& t : crossTiles(mon)) {
            if (!tiles.empty())
                tiles += ",";
            tiles += std::format("{{\"k\":\"{}\",\"x\":{:.1f},\"y\":{:.1f},\"w\":{:.1f},\"h\":{:.1f},\"ws\":{},\"row\":{}}}", t.kind, t.box.x, t.box.y, t.box.w, t.box.h, t.ws, t.row);
        }
        postEvent("strata-cross", std::format("{{\"show\":{},\"mon\":\"{}\",\"tiles\":[{}]}}", show ? "true" : "false", mon->m_name, tiles));
    }

    // Something moved the view. kind: "window", "blank", "stratum", "edge".
    void crossPoke(const std::string& kind) {
        const auto TRIGGER = std::string{g_cfg.crossTrigger->value()};
        if (TRIGGER == "off" || TRIGGER == "hold")
            return;
        if (TRIGGER == "change" && kind != "blank" && kind != "stratum")
            return;
        const auto MON = Desktop::focusState()->monitor();
        if (!MON || !strataFor(MON->m_activeWorkspace) || overviewOpen(MON->m_id))
            return;

        auto&      c      = g_cross[MON->m_id];
        const bool WASON  = c.visible && crossAlpha(c) > 0.F;
        if (!WASON) {
            c.shown   = Time::steadyNow();
            c.visible = true;
        }
        c.held       = TRIGGER == "held";
        c.hidePosted = false;
        c.hideAt     = Time::steadyNow() + std::chrono::milliseconds(std::max<int64_t>(150, g_cfg.crossFadeMs->value()));
        postCross(MON, true);
        g_pHyprRenderer->damageMonitor(MON);
        MON->scheduleFrame(Aquamarine::IOutput::AQ_SCHEDULE_ANIMATION);
    }

    void crossHide(PHLMONITOR mon) {
        if (!mon)
            return;
        auto& c = g_cross[mon->m_id];
        if (!c.visible)
            return;
        c.held       = false;
        c.hideAt     = Time::steadyNow();
        c.hidePosted = true;
        postCross(mon, false);
        g_pHyprRenderer->damageMonitor(mon);
        mon->scheduleFrame(Aquamarine::IOutput::AQ_SCHEDULE_ANIMATION);
    }

    // "hold" trigger: SUPER held alone for a moment shows the cross; any other
    // key cancels; letting go hides it. "held": letting go of SUPER hides it.
    static wl_event_source* g_holdTimer = nullptr;
    static bool             g_holdArmed = false;

    static int onHoldTimer(void*) {
        if (!g_holdArmed)
            return 0;
        g_holdArmed    = false;
        const auto MON = Desktop::focusState()->monitor();
        if (!MON || !strataFor(MON->m_activeWorkspace))
            return 0;
        auto& c   = g_cross[MON->m_id];
        c.shown   = Time::steadyNow();
        c.visible    = true;
        c.held       = true;
        c.hidePosted = false;
        postCross(MON, true);
        g_pHyprRenderer->damageMonitor(MON);
        MON->scheduleFrame(Aquamarine::IOutput::AQ_SCHEDULE_ANIMATION);
        return 0;
    }

    void crossKey(uint32_t keycode, bool pressed) {
        const auto TRIGGER = std::string{g_cfg.crossTrigger->value()};
        // evdev codes: 125 left meta, 126 right meta
        const bool SUPER = keycode == 125 || keycode == 126;
        const auto MON   = Desktop::focusState()->monitor();

        if (TRIGGER == "hold") {
            if (SUPER && pressed) {
                if (!g_holdTimer && g_pCompositor && g_pCompositor->m_wlEventLoop)
                    g_holdTimer = wl_event_loop_add_timer(g_pCompositor->m_wlEventLoop, onHoldTimer, nullptr);
                g_holdArmed = true;
                if (g_holdTimer)
                    wl_event_source_timer_update(g_holdTimer, 400);
            } else {
                g_holdArmed = false;
                if (SUPER && !pressed)
                    crossHide(MON);
            }
            return;
        }
        if (TRIGGER == "held" && SUPER && !pressed)
            crossHide(MON);
    }

    // ── Drawing ──────────────────────────────────────────────────────────

    class CCrossPass : public IPassElement {
      public:
        CCrossPass(PHLMONITOR mon, float alpha) : m_mon(mon), m_alpha(alpha) {}
        virtual ~CCrossPass() = default;

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
            return "CStrataCrossPass";
        }
        virtual ePassElementType type() {
            return EK_CUSTOM;
        }

      private:
        PHLMONITORREF m_mon;
        float         m_alpha;
    };

    // A nested pass render rewrites the frame's damage and final damage (what
    // is copied to the screen at the end); without putting them back only
    // the last tile drawn would reach the screen.
    void renderNested(Render::CRenderPass& pass, const CRegion& region) {
        auto&      rd        = g_pHyprRenderer->m_renderData;
        const auto DAMAGE    = rd.damage;
        const auto FINAL     = rd.finalDamage;
        const auto MON       = rd.pMonitor.lock();
        const bool BLURFB    = MON ? MON->m_blurFBShouldRender : false;
        pass.render(region);
        rd.damage      = DAMAGE;
        rd.finalDamage = FINAL;
        if (MON)
            MON->m_blurFBShouldRender = BLURFB;
    }

    // Draw window w with its logical box mapped from `region` (global
    // logical) into `tile` (monitor-local logical), clipped to the tile.
    void drawWindowInto(PHLMONITOR mon, PHLWINDOW w, const CBox& region, const CBox& tile, float alpha, const Time::steady_tp& now) {
        const CBox WBOX{w->positionAnimation()->value() + w->m_floatingOffset, w->sizeAnimation()->value()};
        if (!WBOX.overlaps(region))
            return;
        const double K = tile.w / std::max(1.0, region.w);
        drawWindowAt(mon, w, CBox{tile.x + (WBOX.x - region.x) * K, tile.y + (WBOX.y - region.y) * K, WBOX.w * K, WBOX.h * K}, tile, alpha, now);
    }

    // Draw window w into TARGET (monitor-local logical), clipped to `clip`.
    void drawWindowAt(PHLMONITOR mon, PHLWINDOW w, const CBox& TARGET, const CBox& clip, float alpha, const Time::steady_tp& now) {
        if (!TARGET.overlaps(clip))
            return;
        const auto POS    = w->positionAnimation()->value();
        const auto SIZE   = w->sizeAnimation()->value();
        const CBox CLIPPX = clip.copy().scale(mon->m_scale).round();

        // A private stratum: a card where the window is, nothing of its content.
        if (w->m_workspace && isPrivate(w->m_workspace)) {
            CRectPassElement::SRectData card;
            card.box     = TARGET.copy().scale(mon->m_scale).round().intersection(CLIPPX);
            card.color   = CHyprColor{0.32F, 0.35F, 0.40F, 0.55F * alpha};
            card.round   = sc<int>(std::round(4 * mon->m_scale));
            Render::CRenderPass cardPass;
            cardPass.add(makeUnique<CRectPassElement>(card));
            renderNested(cardPass, CRegion{card.box});
            return;
        }

        const auto WS        = w->m_workspace;
        const bool WASVIS    = WS ? WS->m_visible : false;
        const bool WASFORCE  = WS ? WS->m_forceRendering : false;
        const auto WSOFFSET  = WS ? WS->m_renderOffset->value() : Vector2D{};
        const auto WSALPHA   = WS ? WS->m_alpha->value() : 1.F;
        const bool WASHIDDEN = w->m_hidden;
        const bool WASANIMIN = w->m_animatingIn;

        w->positionAnimation()->value() = mon->m_position + TARGET.pos() - w->m_floatingOffset;
        w->sizeAnimation()->value()     = TARGET.size();
        w->m_hidden                     = false;
        w->m_animatingIn                = true;
        if (WS) {
            WS->m_visible        = true;
            WS->m_forceRendering = true;
            WS->m_renderOffset->value() = {};
            // A stratum made in the background (an app routed there, a
            // window sent there) is at alpha 0 until you first go there.
            WS->m_alpha->value() = 1.F;
        }

        auto restore = Hyprutils::Utils::CScopeGuard([&] {
            w->positionAnimation()->value() = POS;
            w->sizeAnimation()->value()     = SIZE;
            w->m_hidden                     = WASHIDDEN;
            w->m_animatingIn                = WASANIMIN;
            if (WS) {
                WS->m_visible               = WASVIS;
                WS->m_forceRendering        = WASFORCE;
                WS->m_renderOffset->value() = WSOFFSET;
                WS->m_alpha->value()        = WSALPHA;
            }
        });

        Render::CRenderPass pass;
        {
            auto redirect = g_pHyprRenderer->redirectPass(&pass);
            g_pHyprRenderer->renderWindow(w, mon, now, false, Render::RENDER_PASS_ALL, false, false);
        }

        for (auto& e : pass.m_passElements) {
            if (auto* s = dynamic_cast<CSurfacePassElement*>(e.element.get())) {
                s->m_data.clipBox = CLIPPX;
                s->m_data.alpha *= alpha;
                s->getTexBox();
            }
        }

        renderNested(pass, CRegion{CLIPPX});
    }

    std::vector<UP<IPassElement>> CCrossPass::draw() {
        const auto MON = m_mon.lock();
        if (!MON || m_alpha <= 0.F)
            return {};

        const auto  NOW     = Time::steadyNow();
        const auto  MONBOX  = CBox{MON->m_position, MON->m_size};
        static auto PROUND  = CConfigValue<Config::INTEGER>("decoration:rounding");
        const auto  ROUNDPX = sc<int>(std::round(std::max<int64_t>(4, *PROUND) * MON->m_scale));

        for (const auto& t : crossTiles(MON)) {
            const auto WS = workspaceByID(t.ws);

            // Backdrop: the tile reads as a little screen even where it's empty.
            CRectPassElement::SRectData bg;
            bg.box   = t.box.copy().scale(MON->m_scale).round();
            bg.color = CHyprColor{0.02F, 0.03F, 0.04F, 0.82F * m_alpha};
            bg.round = ROUNDPX;
            Render::CRenderPass bgPass;
            bgPass.add(makeUnique<CRectPassElement>(bg));
            renderNested(bgPass, CRegion{bg.box});

            // The stratum's wallpaper behind its windows, like the real thing.
            SP<Render::ITexture> wtex;
            Vector2D             wsize;
            if (wallpaperTexture(t.ws, wtex, wsize, t.row))
                drawCover(MON, wtex, wsize, t.box, t.box, 0.9F * m_alpha);

            if (!WS)
                continue;

            // The region of the grid this tile shows: a screen (or half) to
            // the side of the view, in global logical coordinates. Strata
            // rows are all laid out against the same camera, so a row above
            // shows the same x by using the same region.
            const CBox REGION{MONBOX.x + t.offset * MONBOX.w, MONBOX.y, MONBOX.w * t.width, MONBOX.h};

            for (const auto& w : Desktop::windowState()->windows()) {
                if (!w || !w->m_isMapped || w->m_workspace != WS || w->m_hidden)
                    continue;
                drawWindowInto(MON, w, REGION, t.box, m_alpha, NOW);
            }

            if (!WS->isVisible())
                g_pHyprRenderer->sendFrameEventsToWorkspace(MON, WS, NOW);
        }
        return {};
    }

    // ── Frame plumbing ───────────────────────────────────────────────────

    void crossRenderPre(PHLMONITOR mon) {
        g_frameMon = mon;
        if (!mon)
            return;
        // The timed fade started: the shell fades its frames with it.
        if (auto IT = g_cross.find(mon->m_id); IT != g_cross.end()) {
            auto& c = IT->second;
            if (c.visible && !c.held && !c.hidePosted && Time::steadyNow() >= c.hideAt) {
                c.hidePosted = true;
                postCross(mon, false);
            }
        }
        if (crossActive(mon->m_id))
            g_pHyprRenderer->damageMonitor(mon);
    }

    void crossRenderStage(eRenderStage stage) {
        if (stage == RENDER_POST) {
            // A frame requested here, inside the frame, is kept (one requested
            // later, from a timer, can be dropped while the output is idle).
            const auto MON = g_frameMon.lock();
            if (MON && crossActive(MON->m_id))
                MON->scheduleFrame(Aquamarine::IOutput::AQ_SCHEDULE_ANIMATION);
            else if (MON) {
                auto& c = g_cross[MON->m_id];
                if (c.visible && crossAlpha(c) <= 0.F && !c.held && Time::steadyNow() >= c.hideAt) {
                    c.visible = false;
                    c.shown   = {};
                }
            }
            return;
        }
        if (stage != RENDER_POST_WINDOWS)
            return;
        const auto MON = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!MON)
            return;
        const auto IT = g_cross.find(MON->m_id);
        if (IT == g_cross.end())
            return;
        const float A = crossAlpha(IT->second);
        if (A > 0.F)
            g_pHyprRenderer->currentPass().add(makeUnique<CCrossPass>(MON, A));
    }

    void crossCleanup() {
        if (g_holdTimer) {
            wl_event_source_remove(g_holdTimer);
            g_holdTimer = nullptr;
        }
        g_cross.clear();
    }
}
