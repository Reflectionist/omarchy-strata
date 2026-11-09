// Moving around the grid with the pointer:
//   - SUPER+drag on blank space pans the grid like a map, settling on the
//     step grid when you let go;
//   - dragging a window against the left/right edge of the screen scrolls
//     the grid that way, so a window can be carried anywhere by mouse;
//   - a tiled window dropped on blank space lands right there.
// (Trackpad swipes are hl.gesture callbacks in lua/strata.lua using pan().)

#include "strata.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/devices/IPointer.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/render/Renderer.hpp>

#include "input.hpp"
#include "overview.hpp"

namespace Strata {

    static CHyprSignalListener g_onButton, g_onMove;
    static bool                g_panning = false;
    static double              g_lastX   = 0.0;
    static Time::steady_tp     g_lastPush;

    static bool superHeld() {
        return g_pInputManager && (g_pInputManager->getModsFromAllKBs() & HL_MODIFIER_META);
    }

    static PHLWINDOW windowUnder(const Vector2D& pos) {
        return Desktop::viewState()->hitTest().windowAt(pos, Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS);
    }

    // The bar, a panel, a notification: a SUPER+click there is theirs.
    static bool layerUnder(PHLMONITOR mon, const Vector2D& pos) {
        for (const auto L : {ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_LAYER_SHELL_V1_LAYER_TOP}) {
            Vector2D local;
            PHLLS    found;
            if (Desktop::viewState()->hitTest().layerSurfaceAt(pos, &mon->m_layerSurfaceLayers[L], &local, &found))
                return true;
        }
        return false;
    }

    void inputInit() {
        g_onButton = Event::bus()->m_events.input.mouse.button.listen([](IPointer::SButtonEvent e, Event::SCallbackInfo& info) {
            if (e.button != 272 /* BTN_LEFT */)
                return;
            if (e.state == WL_POINTER_BUTTON_STATE_PRESSED) {
                PHLMONITOR MON;
                if (!superHeld() || !activeStrata(&MON) || overviewOpen(MON->m_id))
                    return;
                const auto POS = g_pInputManager->getMouseCoordsInternal();
                if (windowUnder(POS) || layerUnder(MON, POS))
                    return; // SUPER+drag on a window moves the window, as always
                g_panning   = true;
                g_lastX     = POS.x;
                info.cancelled = true;
            } else if (g_panning) {
                g_panning      = false;
                info.cancelled = true;
                settle();
            }
        });

        g_onMove = Event::bus()->m_events.input.mouse.move.listen([](Vector2D, Event::SCallbackInfo&) {
            if (!g_panning)
                return;
            PHLMONITOR MON;
            auto*      a = activeStrata(&MON);
            if (!a)
                return;
            const auto POS = g_pInputManager->getMouseCoordsInternal();
            const double DX = POS.x - g_lastX;
            g_lastX         = POS.x;
            if (DX != 0.0)
                pan(-DX / std::max(1.0, a->workRect().w));
        });
    }

    // Each frame: a tiled window dragged against the screen's side edge
    // pushes the grid that way (about two thirds of a screen per second).
    // Not a floating one (it belongs to the screen, not the grid), and not a
    // resize that happens to reach the edge.
    bool inputRenderPre(PHLMONITOR mon) {
        const auto& DRAG = g_layoutManager->dragController();
        if (!mon || !DRAG || !DRAG->target() || !strataFor(mon->m_activeWorkspace))
            return false;
        if (DRAG->mode() != MBIND_MOVE || !DRAG->draggingTiled() || !DRAG->dragThresholdReached()) {
            g_lastPush = {};
            return false;
        }
        const auto   POS  = g_pInputManager->getMouseCoordsInternal();
        const double EDGE = 28.0;
        int          dir  = 0;
        if (POS.x < mon->m_position.x + EDGE)
            dir = -1;
        else if (POS.x > mon->m_position.x + mon->m_size.x - EDGE)
            dir = 1;
        if (dir == 0) {
            g_lastPush = {};
            return false;
        }
        const auto NOW = Time::steadyNow();
        const float DT = g_lastPush == Time::steady_tp{} ? 0.F : std::min(0.1F, std::chrono::duration<float>(NOW - g_lastPush).count());
        g_lastPush     = NOW;
        if (DT > 0.F)
            pan(dir * 0.66 * DT);
        g_pHyprRenderer->damageMonitor(mon);
        mon->scheduleFrame(Aquamarine::IOutput::AQ_SCHEDULE_ANIMATION);
        return true;
    }

    void inputCleanup() {
        g_onButton.reset();
        g_onMove.reset();
        g_panning = false;
    }
}
