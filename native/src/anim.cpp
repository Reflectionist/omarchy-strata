// Strata slide the way the stack runs. Hyprland picks a workspace switch's
// slide direction by comparing workspace ids, and named strata get negative
// ids in the order they were created, so Games (bottom of the stack) could
// slide in from above. Between two strata the direction comes from the stack
// instead: the way you travelled (SUPER+UP/DOWN), else stack order.

#include "strata.hpp"

#include <hyprland/src/animation/WorkspaceAnimationController.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/output/Monitor.hpp>

#include "anim.hpp"
#include "pip.hpp"

namespace Strata {

    static CFunctionHook*           g_changeHook = nullptr;
    static CFunctionHook*           g_animHook   = nullptr;
    static std::vector<WORKSPACEID> g_order;
    static std::optional<bool>      g_left; // set for the duration of one switch

    using FChange = void (*)(void*, const PHLWORKSPACE&, bool, bool, bool);
    using FAnim   = void (*)(PHLWORKSPACE, Animation::Workspace::eAnimationType, bool, bool, std::optional<std::string>);

    static int indexOf(WORKSPACEID id) {
        for (size_t i = 0; i < g_order.size(); ++i) {
            if (g_order[i] == id)
                return (int)i;
        }
        return -1;
    }

    static bool g_wrap = true;

    bool animWrap() {
        return g_wrap;
    }

    void animOrder(std::vector<WORKSPACEID> ids, bool wrap) {
        g_order = std::move(ids);
        g_wrap  = wrap;
    }

    // The strata directly above and below `id` in the stack (wrapping like
    // SUPER+UP/DOWN do); INVALID where there's none (or it has no workspace
    // yet). upRow/downRow: their places in the stack (-1 for none).
    bool stackNeighbours(WORKSPACEID id, WORKSPACEID& up, WORKSPACEID& down, int* upRow, int* downRow) {
        const int I = indexOf(id);
        const int N = (int)g_order.size();
        if (I < 0 || N == 0)
            return false;
        const auto row = [&](int j) -> int {
            if (j < 0 || j >= N)
                return g_wrap ? (j + N) % N : -1;
            return j;
        };
        const auto at = [&](int j) -> WORKSPACEID { return j < 0 || g_order[j] == 0 ? WORKSPACE_INVALID : g_order[j]; };
        up   = at(row(I - 1));
        down = at(row(I + 1));
        if (upRow)
            *upRow = row(I - 1);
        if (downRow)
            *downRow = row(I + 1);
        return true;
    }


    static void hkChangeWorkspace(void* thisptr, const PHLWORKSPACE& ws, bool internal, bool noMouseMove, bool noFocus) {
        auto* mon = static_cast<Monitor::CMonitor*>(thisptr);
        g_left.reset();
        const auto OLD = mon->m_activeWorkspace;
        // Before anything moves: a playing picture on the stratum being left
        // starts shrinking into its card from where it is now.
        if (mon->m_self)
            pipSwitch(mon->m_self.lock(), OLD, ws);
        if (OLD && ws && !internal && strataFor(OLD) && strataFor(ws)) {
            const int FROM = indexOf(OLD->m_id), TO = indexOf(ws->m_id);
            const int HINT = viewFor(mon->m_id).landHint;
            // left == the new stratum comes in from below (down the stack).
            if (HINT != 0)
                g_left = HINT > 0;
            else if (FROM >= 0 && TO >= 0 && FROM != TO)
                g_left = TO > FROM;
        }
        ((FChange)g_changeHook->m_original)(thisptr, ws, internal, noMouseMove, noFocus);
        g_left.reset();
    }

    static void hkStartAnimation(PHLWORKSPACE ws, Animation::Workspace::eAnimationType type, bool left, bool instant, std::optional<std::string> style) {
        ((FAnim)g_animHook->m_original)(std::move(ws), type, g_left.value_or(left), instant, std::move(style));
    }

    bool animInit() {
        for (const auto& m : HyprlandAPI::findFunctionsByName(PHANDLE, "changeWorkspace")) {
            if (m.demangled.find("Monitor::CMonitor::changeWorkspace(Hyprutils::Memory::CSharedPointer<CWorkspace> const&") != std::string::npos) {
                g_changeHook = HyprlandAPI::createFunctionHook(PHANDLE, m.address, (void*)&hkChangeWorkspace);
                break;
            }
        }
        for (const auto& m : HyprlandAPI::findFunctionsByName(PHANDLE, "startAnimation")) {
            if (m.demangled.find("Animation::Workspace::startAnimation(") != std::string::npos) {
                g_animHook = HyprlandAPI::createFunctionHook(PHANDLE, m.address, (void*)&hkStartAnimation);
                break;
            }
        }
        if (!g_changeHook || !g_animHook)
            return false;
        return g_changeHook->hook() && g_animHook->hook();
    }
}
