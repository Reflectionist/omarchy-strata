#include "strata.hpp"
#include "cross.hpp"
#include "overview.hpp"
#include "pip.hpp"
#include "wallpaper.hpp"
#include "anim.hpp"
#include "input.hpp"

#include <format>

#include <lua.hpp>

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/space/Space.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/config/shared/animation/AnimationTree.hpp>

using namespace Strata;

static CFunctionHook*      g_recalcHook = nullptr;
static CHyprSignalListener g_onFocus, g_onFullscreen, g_onWorkspace, g_onRenderPre, g_onRenderStage, g_onKey, g_onOpen, g_onClose, g_onMoveWs;

using FRecalc = void (*)(Layout::Tiled::SScrollingData*, bool);

// Every scrolling placement ends here; strata rows place their own windows.
static void hkRecalculate(Layout::Tiled::SScrollingData* self, bool forceInstant) {
    if (auto* a = dynamic_cast<CStrataAlgorithm*>(self->algorithm)) {
        a->strataRecalc(forceInstant);
        return;
    }
    ((FRecalc)g_recalcHook->m_original)(self, forceInstant);
}

static int dirArg(lua_State* L, int i) {
    const std::string D = luaL_checkstring(L, i);
    return D == "r" || D == "right" || D == "next" || D == "+" ? 1 : -1;
}

// hl.plugin.strata.nav("l"|"r", wrap?) -> "window" | "blank" | "edge" | "none"
static int luaNav(lua_State* L) {
    lua_pushstring(L, nav(dirArg(L, 1), lua_toboolean(L, 2)).c_str());
    return 1;
}

// hl.plugin.strata.settle(): ease the camera onto the step grid (after a swipe)
static int luaSettle(lua_State* L) {
    settle();
    return 0;
}

// hl.plugin.strata.home()
static int luaHome(lua_State* L) {
    lua_pushstring(L, home().c_str());
    return 1;
}

// hl.plugin.strata.pan(units): positive moves the view right
static int luaPan(lua_State* L) {
    lua_pushstring(L, pan(luaL_checknumber(L, 1)).c_str());
    return 1;
}

// hl.plugin.strata.move("l"|"r", fine?): step-move the focused window
static int luaMove(lua_State* L) {
    auto* a = activeStrata();
    bool  ok = a && a->stepMove(Desktop::focusState()->window(), dirArg(L, 1), lua_toboolean(L, 2));
    emit();
    lua_pushboolean(L, ok);
    return 1;
}

// hl.plugin.strata.hint(n): how the next stratum switch lands (-1 bottom of
// the column, going up; +1 top, going down; 0 the window last used there)
static int luaHint(lua_State* L) {
    if (const auto MON = Desktop::focusState()->monitor())
        viewFor(MON->m_id).landHint = (int)luaL_checkinteger(L, 1);
    return 0;
}

// hl.plugin.strata.expect(address, x, stack?, dir?): where a window arriving
// on a stratum goes (vertical moves)
static int luaExpect(lua_State* L) {
    CStrataAlgorithm::SExpect e;
    e.x     = luaL_checknumber(L, 2);
    e.stack = lua_toboolean(L, 3);
    e.dir   = (int)luaL_optinteger(L, 4, 0);
    expect(luaL_checkstring(L, 1), e);
    return 0;
}

// hl.plugin.strata.place(address, x): put a window's column at x
static int luaPlace(lua_State* L) {
    const auto W = windowByAddress(luaL_checkstring(L, 1));
    auto*      a = W ? strataFor(W->m_workspace) : nullptr;
    const auto C = a ? a->columnOf(W) : nullptr;
    if (!C) {
        lua_pushboolean(L, false);
        return 1;
    }
    a->setX(C, luaL_checknumber(L, 2));
    // Keep order consistent with x: re-sort columns by position.
    auto& cols = a->m_scrollingData->columns;
    for (size_t i = 0; i < cols.size(); ++i) {
        for (size_t j = i + 1; j < cols.size(); ++j) {
            if (a->xOf(cols[j]) < a->xOf(cols[i]) - EPS) {
                std::swap(cols[i], cols[j]);
                a->m_scrollingData->controller->swapStrips(i, j);
            }
        }
    }
    a->normalize();
    recalcMonitor(a->monitorID());
    emit();
    lua_pushboolean(L, true);
    return 1;
}

// hl.plugin.strata.width(address, w): set a window's column width (screens)
static int luaWidth(lua_State* L) {
    const auto W = windowByAddress(luaL_checkstring(L, 1));
    auto*      a = W ? strataFor(W->m_workspace) : nullptr;
    const auto C = a ? a->columnOf(W) : nullptr;
    if (!C) {
        lua_pushboolean(L, false);
        return 1;
    }
    C->setColumnWidth(std::clamp((float)luaL_checknumber(L, 2), MIN_COLUMN_WIDTH, MAX_COLUMN_WIDTH));
    a->normalize();
    recalcMonitor(a->monitorID());
    emit();
    lua_pushboolean(L, true);
    return 1;
}

// hl.plugin.strata.join(address, into_address): stack a window into the
// bottom of another window's column (same stratum)
static int luaJoin(lua_State* L) {
    const auto W = windowByAddress(luaL_checkstring(L, 1));
    const auto T = windowByAddress(luaL_checkstring(L, 2));
    auto*      a = W ? strataFor(W->m_workspace) : nullptr;
    if (!a || !T || T->m_workspace != W->m_workspace) {
        lua_pushboolean(L, false);
        return 1;
    }
    const auto WD = a->dataFor(W->layoutTarget());
    const auto TC = a->columnOf(T);
    if (!WD || !TC || WD->column.lock() == TC) {
        lua_pushboolean(L, false);
        return 1;
    }
    WD->column->remove(W->layoutTarget());
    TC->add(WD);
    a->normalize();
    recalcMonitor(a->monitorID());
    lua_pushboolean(L, true);
    return 1;
}

// hl.plugin.strata.reveal(address): focus a window and bring it into view
static int luaReveal(lua_State* L) {
    const auto W = windowByAddress(luaL_checkstring(L, 1));
    auto*      a = W ? strataFor(W->m_workspace) : nullptr;
    const auto C = a ? a->columnOf(W) : nullptr;
    if (!C) {
        lua_pushboolean(L, false);
        return 1;
    }
    setCursorTo(a, C);
    fitSlot(a->view(), a->xOf(C), a->effW(C));
    recalcMonitor(a->monitorID());
    focusWindow(W);
    emit();
    lua_pushboolean(L, true);
    return 1;
}

static std::vector<WORKSPACEID> rowsArg(lua_State* L, int i) {
    std::vector<WORKSPACEID> rows;
    if (!lua_istable(L, i))
        return rows;
    const auto N = luaL_len(L, i);
    for (lua_Integer k = 1; k <= N; ++k) {
        lua_geti(L, i, k);
        const auto ID = lua_tointeger(L, -1);
        rows.push_back(ID == 0 ? WORKSPACE_INVALID : ID);
        lua_pop(L, 1);
    }
    return rows;
}

// hl.plugin.strata.overview_open({ws ids top to bottom, 0 = none}, current_row (1-based))
static int luaOverviewOpen(lua_State* L) {
    overviewOpenRows(rowsArg(L, 1), (int)luaL_optinteger(L, 2, 1) - 1, lua_toboolean(L, 3));
    return 0;
}

// hl.plugin.strata.overview_close(row (1-based), or 0 to stay)
static int luaOverviewClose(lua_State* L) {
    overviewClose((int)luaL_optinteger(L, 1, 0) - 1);
    return 0;
}

// hl.plugin.strata.overview_rows({ws ids}): the stack changed while open
static int luaOverviewRows(lua_State* L) {
    overviewRows(rowsArg(L, 1));
    return 0;
}

// hl.plugin.strata.move_animation() -> {enabled, speed, bezier}: the
// windowsMove animation as configured (inherited values resolved), which
// strata reuse for sliding vertically
static int luaMoveAnimation(lua_State* L) {
    const auto C = Config::animationTree()->getAnimationPropertyConfig("windowsMove");
    const auto V = C ? C->pValues.lock() : nullptr;
    if (!V) {
        lua_pushnil(L);
        return 1;
    }
    lua_newtable(L);
    lua_pushboolean(L, V->internalEnabled != 0);
    lua_setfield(L, -2, "enabled");
    lua_pushnumber(L, V->internalSpeed);
    lua_setfield(L, -2, "speed");
    lua_pushstring(L, V->internalBezier.c_str());
    lua_setfield(L, -2, "bezier");
    return 1;
}

// hl.plugin.strata.overview_drag(address, edge, fx, fy): start dragging a
// window in the overview (edge -1/1: resizing by that edge; fx, fy: where it
// was grabbed, as a fraction of its box)
static int luaOverviewDrag(lua_State* L) {
    lua_pushboolean(L, overviewDragBegin(windowByAddress(luaL_checkstring(L, 1)), (int)luaL_optinteger(L, 2, 0), luaL_optnumber(L, 3, 0.5), luaL_optnumber(L, 4, 0.5)));
    return 1;
}

// hl.plugin.strata.overview_drag_end() -> nothing, or (row, address) when it
// was dropped on another stratum: move it there, then overview_drag_finish()
static int luaOverviewDragEnd(lua_State* L) {
    std::string addr;
    const int   ROW = overviewDragEnd(&addr);
    if (ROW < 0)
        return 0;
    lua_pushinteger(L, ROW + 1);
    lua_pushstring(L, addr.c_str());
    return 2;
}

static int luaOverviewDragFinish(lua_State* L) {
    overviewDragFinish();
    return 0;
}

static int luaOverviewDragCancel(lua_State* L) {
    overviewDragCancel();
    return 0;
}

// hl.plugin.strata.move_window(address, "l"|"r"|"u"|"d") -> "ok" | "edge" | "":
// the SUPER+SHIFT+arrow moves for any window (the overview's selection),
// leaving the view alone unless it's on that window. "edge": up or down off
// its column, which is a move to the next stratum (Lua's)
static int luaMoveWindow(lua_State* L) {
    lua_pushstring(L, moveWindow(windowByAddress(luaL_checkstring(L, 1)), luaL_checkstring(L, 2)[0]).c_str());
    return 1;
}

// hl.plugin.strata.widen(address, +1|-1): its column a fine step wider or narrower
static int luaWiden(lua_State* L) {
    lua_pushboolean(L, widenWindow(windowByAddress(luaL_checkstring(L, 1)), (int)luaL_checkinteger(L, 2)));
    return 1;
}

// hl.plugin.strata.aim(x, w?): visual focus to grid x on this stratum (the
// window there, or a blank slot: exactly [x, x + w] when w is given)
static int luaAim(lua_State* L) {
    lua_pushstring(L, aim(luaL_checknumber(L, 1), luaL_optnumber(L, 2, 0.0)).c_str());
    return 1;
}

// hl.plugin.strata.match(regex, subject) -> bool (ECMAScript regex, like
// Hyprland's window rules use)
static int luaMatch(lua_State* L) {
    static std::unordered_map<std::string, std::optional<std::regex>> cache;
    const std::string                                                PAT = luaL_checkstring(L, 1);
    const std::string                                                SUB = luaL_optstring(L, 2, "");
    auto                                                             IT  = cache.find(PAT);
    if (IT == cache.end()) {
        std::optional<std::regex> re;
        try {
            re = std::regex(PAT);
        } catch (...) {}
        IT = cache.emplace(PAT, re).first;
        if (cache.size() > 512)
            cache.clear();
    }
    lua_pushboolean(L, IT != cache.end() && IT->second && std::regex_search(SUB, *IT->second));
    return 1;
}

// hl.plugin.strata.private({workspace names}): strata whose windows previews
// hide (numbers are taken as numbered workspaces' names)
static int luaPrivate(lua_State* L) {
    g_private.clear();
    if (!lua_istable(L, 1))
        return 0;
    const auto N = luaL_len(L, 1);
    for (lua_Integer k = 1; k <= N; ++k) {
        lua_geti(L, 1, k);
        if (lua_type(L, -1) == LUA_TSTRING || lua_type(L, -1) == LUA_TNUMBER) {
            std::string name = lua_tostring(L, -1);
            if (name.starts_with("name:"))
                name = name.substr(5);
            if (!name.empty() && name != "0")
                g_private.insert(name);
        }
        lua_pop(L, 1);
    }
    return 0;
}

// hl.plugin.strata.widths({ [workspace name] = width, ... }): the column width
// windows get when they open on that stratum (unless their own rule sets one)
static int luaWidths(lua_State* L) {
    g_widths.clear();
    if (!lua_istable(L, 1))
        return 0;
    lua_pushnil(L);
    while (lua_next(L, 1)) {
        if (lua_type(L, -2) == LUA_TSTRING && lua_isnumber(L, -1)) {
            std::string name = lua_tostring(L, -2);
            if (name.starts_with("name:"))
                name = name.substr(5);
            if (!name.empty())
                g_widths[name] = lua_tonumber(L, -1);
        }
        lua_pop(L, 1);
    }
    return 0;
}

// hl.plugin.strata.opening(address): a window Lua is routing as it opens; it
// arrives as an opening (with the window width of the stratum it lands on)
static int luaOpening(lua_State* L) {
    opening(luaL_checkstring(L, 1));
    return 0;
}

// hl.plugin.strata.pip_watch(address, playing): a window on the stratum
// you're on plays video (or stopped)
static int luaPipWatch(lua_State* L) {
    pipWatch(windowByAddress(luaL_checkstring(L, 1)), lua_toboolean(L, 2));
    return 0;
}

// hl.plugin.strata.pip_config(corner, width, "#rrggbb"): where new cards
// start, how wide (fraction of the screen), the edge colour
static int luaPipConfig(lua_State* L) {
    const std::string HEX = luaL_optstring(L, 3, "#8cb4ff");
    CHyprColor        c{0.55F, 0.7F, 1.F, 1.F};
    if (HEX.size() == 7 && HEX[0] == '#') {
        try {
            const auto V = std::stoul(HEX.substr(1), nullptr, 16);
            c            = CHyprColor{((V >> 16) & 0xFF) / 255.F, ((V >> 8) & 0xFF) / 255.F, (V & 0xFF) / 255.F, 1.F};
        } catch (...) {}
    }
    pipConfig(luaL_optstring(L, 1, "bottom-right"), luaL_optnumber(L, 2, 0.25), c);
    return 0;
}

static int luaPipCard(lua_State* L) {
    lua_pushboolean(L, pipCard(luaL_checknumber(L, 1), luaL_checknumber(L, 2), luaL_checknumber(L, 3), luaL_checknumber(L, 4)));
    return 1;
}

static int luaPipScale(lua_State* L) {
    lua_pushboolean(L, pipScale(luaL_checknumber(L, 1)));
    return 1;
}

static int luaPipDrag(lua_State* L) {
    lua_pushboolean(L, pipDrag((int)luaL_optinteger(L, 1, 0)));
    return 1;
}

static int luaPipDragEnd(lua_State*) {
    pipDragEnd();
    return 0;
}

static int luaPipHome(lua_State* L) {
    lua_pushboolean(L, pipHome());
    return 1;
}

static int luaPipWorkspace(lua_State* L) {
    lua_pushstring(L, pipWorkspace().c_str());
    return 1;
}

// hl.plugin.strata.pip_crop(address, x0, y0, x1, y1): the picture inside a
// window that redraws all of itself (fractions of it, black bars left out)
static int luaPipCrop(lua_State* L) {
    pipCrop(windowByAddress(luaL_checkstring(L, 1)), luaL_checknumber(L, 2), luaL_checknumber(L, 3), luaL_checknumber(L, 4), luaL_checknumber(L, 5));
    return 0;
}

static int luaPipAnnounce(lua_State*) {
    pipAnnounce();
    return 0;
}

static int luaPipState(lua_State* L) {
    lua_pushstring(L, pipState().c_str());
    return 1;
}

// hl.plugin.strata.wallpapers({ [ws_id] = path, ... }, base, mode, parallax, strength)
static int luaWallpapers(lua_State* L) {
    std::unordered_map<WORKSPACEID, std::string> paths;
    std::unordered_map<std::string, std::string> named;
    if (lua_istable(L, 1)) {
        lua_pushnil(L);
        while (lua_next(L, 1)) {
            // Integer keys are workspace ids; string keys workspace names.
            if (lua_type(L, -2) == LUA_TNUMBER && lua_isinteger(L, -2) && lua_type(L, -1) == LUA_TSTRING)
                paths[lua_tointeger(L, -2)] = lua_tostring(L, -1);
            else if (lua_type(L, -2) == LUA_TSTRING && lua_type(L, -1) == LUA_TSTRING)
                named[lua_tostring(L, -2)] = lua_tostring(L, -1);
            lua_pop(L, 1);
        }
    }
    std::vector<std::string> rows;
    if (lua_istable(L, 6)) {
        const auto N = luaL_len(L, 6);
        for (lua_Integer k = 1; k <= N; ++k) {
            lua_geti(L, 6, k);
            rows.emplace_back(lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "");
            lua_pop(L, 1);
        }
    }
    wallpaperSet(std::move(paths), std::move(named), std::move(rows), luaL_optstring(L, 2, ""), luaL_optstring(L, 3, "crossfade"), lua_toboolean(L, 4),
                 (float)luaL_optnumber(L, 5, 0.08));
    return 0;
}

// hl.plugin.strata.order({ws ids top to bottom}, wrap): the stack, for slide
// directions and the cross's strata above and below
static int luaOrder(lua_State* L) {
    animOrder(rowsArg(L, 1), lua_isnone(L, 2) || lua_toboolean(L, 2));
    return 0;
}

static int luaOverviewIsOpen(lua_State* L) {
    const auto MON = Desktop::focusState()->monitor();
    lua_pushboolean(L, MON && overviewOpen(MON->m_id));
    return 1;
}

// hl.plugin.strata.state() -> { camera, x, w, blank, lo, hi, step, view_step, slot }
static int luaState(lua_State* L) {
    PHLMONITOR MON;
    auto*      a = activeStrata(&MON);
    if (!a) {
        lua_pushnil(L);
        return 1;
    }
    const auto& v = a->view();
    const auto [LO, HI] = bounds(MON->m_id);
    lua_newtable(L);
    const auto num = [L](const char* k, double n) {
        lua_pushnumber(L, n);
        lua_setfield(L, -2, k);
    };
    num("camera", v.camera);
    num("x", v.cursorX);
    num("w", v.cursorW);
    num("lo", LO);
    num("hi", HI);
    num("step", g_cfg.step->value());
    num("view_step", g_cfg.viewStep->value());
    num("slot", slotWidth());
    num("workspace", a->workspace()->m_id);
    lua_pushboolean(L, v.blank);
    lua_setfield(L, -2, "blank");
    return 1;
}

// hl.plugin.strata.columns(workspace_id) -> { { x, w, cw, windows = { addr... } }, ... }
static int luaColumns(lua_State* L) {
    const WORKSPACEID ID = luaL_checkinteger(L, 1);
    CStrataAlgorithm* a  = strataFor(workspaceByID(ID));
    lua_newtable(L);
    if (!a)
        return 1;
    a->normalize();
    int i = 1;
    for (const auto& c : a->m_scrollingData->columns) {
        lua_newtable(L);
        lua_pushnumber(L, a->xOf(c));
        lua_setfield(L, -2, "x");
        lua_pushnumber(L, a->effW(c));
        lua_setfield(L, -2, "w");
        // Its own width (w is what it takes on screen: a lone column fills it).
        lua_pushnumber(L, c->getColumnWidth());
        lua_setfield(L, -2, "cw");
        lua_newtable(L);
        int j = 1;
        for (const auto& td : c->targetDatas) {
            if (td->target && td->target->window()) {
                lua_pushstring(L, addressOf(td->target->window()).c_str());
                lua_rawseti(L, -2, j++);
            }
        }
        lua_setfield(L, -2, "windows");
        lua_rawseti(L, -2, i++);
    }
    return 1;
}

// hl.plugin.strata.*
static const std::pair<const char*, PLUGIN_LUA_FN> LUA_FNS[] = {
    {"nav", luaNav},
    {"home", luaHome},
    {"pan", luaPan},
    {"settle", luaSettle},
    {"move", luaMove},
    {"hint", luaHint},
    {"aim", luaAim},
    {"expect", luaExpect},
    {"place", luaPlace},
    {"width", luaWidth},
    {"join", luaJoin},
    {"reveal", luaReveal},
    {"state", luaState},
    {"columns", luaColumns},
    {"overview_open", luaOverviewOpen},
    {"overview_close", luaOverviewClose},
    {"overview_rows", luaOverviewRows},
    {"overview_is_open", luaOverviewIsOpen},
    {"overview_drag", luaOverviewDrag},
    {"overview_drag_end", luaOverviewDragEnd},
    {"overview_drag_finish", luaOverviewDragFinish},
    {"overview_drag_cancel", luaOverviewDragCancel},
    {"move_window", luaMoveWindow},
    {"widen", luaWiden},
    {"move_animation", luaMoveAnimation},
    {"match", luaMatch},
    {"private", luaPrivate},
    {"widths", luaWidths},
    {"pip_watch", luaPipWatch},
    {"pip_config", luaPipConfig},
    {"pip_card", luaPipCard},
    {"pip_scale", luaPipScale},
    {"pip_drag", luaPipDrag},
    {"pip_drag_end", luaPipDragEnd},
    {"pip_home", luaPipHome},
    {"pip_workspace", luaPipWorkspace},
    {"pip_state", luaPipState},
    {"pip_announce", luaPipAnnounce},
    {"pip_crop", luaPipCrop},
    {"opening", luaOpening},
    {"wallpapers", luaWallpapers},
    {"order", luaOrder},
};

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    if (__hyprland_api_get_hash() != std::string{__hyprland_api_get_client_hash()}) {
        HyprlandAPI::addNotification(PHANDLE, "Strata: built for a different Hyprland version. Rebuild it: Strata settings > Setup > Rebuild.", CHyprColor{1.0, 0.2, 0.2, 1.0}, 8000);
        throw std::runtime_error("[strata] version mismatch");
    }

    using namespace Config::Values;
    g_cfg.step      = makeShared<CFloatValue>("plugin:strata:step", "How far one step-move carries a window (fraction of the screen width)", 0.5F,
                                              SFloatValueOptions{.min = 0.05F, .max = 2.F});
    g_cfg.viewStep  = makeShared<CFloatValue>("plugin:strata:view_step", "How far visual focus moves through blank space per press (fraction of the screen width)", 0.5F,
                                              SFloatValueOptions{.min = 0.05F, .max = 2.F});
    g_cfg.fineStep  = makeShared<CFloatValue>("plugin:strata:fine_step", "Fine nudge distance (fraction of the screen width)", 0.125F, SFloatValueOptions{.min = 0.01F, .max = 1.F});
    g_cfg.slotWidth = makeShared<CFloatValue>("plugin:strata:slot_width", "Width of the blank slot visual focus sits on; 0 = scrolling:column_width", 0.F,
                                              SFloatValueOptions{.min = 0.F, .max = 1.F});
    g_cfg.jumpNear  = makeShared<CIntValue>("plugin:strata:jump_near", "Jump straight to the next window when it is within this many view steps", 2,
                                            SIntValueOptions{.min = 0, .max = 100});
    g_cfg.margin    = makeShared<CIntValue>("plugin:strata:margin", "View steps you can travel past the outermost window", 0, SIntValueOptions{.min = 0, .max = 100});
    g_cfg.wrap      = makeShared<CBoolValue>("plugin:strata:wrap", "Wrap around at the left/right travel limits", false);
    g_cfg.closeGap  = makeShared<CBoolValue>("plugin:strata:close_gap", "Closing a window pulls the windows to its right in", false);
    g_cfg.landFocus = makeShared<CStringValue>("plugin:strata:land_focus", "Switching strata focuses the window under the view (grid) or the one last used there (last)", "grid");
    g_cfg.landPast  = makeShared<CStringValue>("plugin:strata:land_past", "Landing past all of a stratum's windows: stay on blank (blank) or go to its nearest window (nearest)", "blank");
    g_cfg.crossTrigger   = makeShared<CStringValue>("plugin:strata:cross_trigger", "When the preview cross shows: move, held, change, hold or off", "move");
    g_cfg.crossPlacement = makeShared<CStringValue>("plugin:strata:cross_placement", "Where the preview cross sits: bottom, center or topleft", "bottom");
    g_cfg.crossSize      = makeShared<CFloatValue>("plugin:strata:cross_size", "Width of the cross's centre tile as a fraction of the screen", 0.16F,
                                                   SFloatValueOptions{.min = 0.05F, .max = 0.45F});
    g_cfg.debugZoom      = makeShared<CFloatValue>("plugin:strata:debug_zoom", "Hold the overview zoom at this value (0..1) for screenshots; -1 = off", -1.F,
                                                   SFloatValueOptions{.min = -1.F, .max = 1.F});
    g_cfg.crossFadeMs    = makeShared<CIntValue>("plugin:strata:cross_fade_ms", "How long the cross stays after the last move (ms)", 800, SIntValueOptions{.min = 150, .max = 10000});

    for (const SP<IValue>& v : std::initializer_list<SP<IValue>>{g_cfg.step, g_cfg.viewStep, g_cfg.fineStep, g_cfg.slotWidth, g_cfg.jumpNear, g_cfg.margin, g_cfg.wrap, g_cfg.closeGap,
                                                                  g_cfg.landFocus, g_cfg.landPast, g_cfg.crossTrigger, g_cfg.crossPlacement, g_cfg.crossSize, g_cfg.crossFadeMs, g_cfg.debugZoom})
        HyprlandAPI::addConfigValueV2(PHANDLE, v);

    for (const auto& m : HyprlandAPI::findFunctionsByName(PHANDLE, "recalculate")) {
        if (m.demangled.find("Layout::Tiled::SScrollingData::recalculate(bool)") != std::string::npos) {
            g_recalcHook = HyprlandAPI::createFunctionHook(PHANDLE, m.address, (void*)&hkRecalculate);
            break;
        }
    }
    if (!g_recalcHook || !g_recalcHook->hook()) {
        HyprlandAPI::addNotification(PHANDLE, "Strata: couldn't hook the scrolling layout; the strata layout is not available.", CHyprColor{1.0, 0.2, 0.2, 1.0}, 8000);
        throw std::runtime_error("[strata] hook failed");
    }

    if (!animInit())
        HyprlandAPI::addNotification(PHANDLE, "Strata: couldn't hook workspace animations; strata slide by workspace id.", CHyprColor{1.0, 0.6, 0.2, 1.0}, 6000);

    HyprlandAPI::addTiledAlgo(PHANDLE, "strata", &typeid(CStrataAlgorithm), [] { return makeUnique<CStrataAlgorithm>(); });

    for (const auto& [name, fn] : LUA_FNS)
        HyprlandAPI::addLuaFunction(PHANDLE, "strata", name, fn);

    g_onFocus     = Event::bus()->m_events.window.active.listen([](PHLWINDOW w, Desktop::eFocusReason r) { onFocus(w, r); });
    g_onFullscreen = Event::bus()->m_events.window.fullscreen.listen([](PHLWINDOW w) { onFullscreen(w); });
    g_onWorkspace = Event::bus()->m_events.workspace.active.listen([](PHLWORKSPACE ws) { onWorkspace(ws); });
    g_onRenderPre   = Event::bus()->m_events.render.pre.listen([](PHLMONITOR m) {
        crossRenderPre(m);
        overviewRenderPre(m);
        wallpaperRenderPre(m);
        inputRenderPre(m);
        pipRenderPre(m);
    });
    g_onRenderStage = Event::bus()->m_events.render.stage.listen([](eRenderStage s) {
        wallpaperRenderStage(s);
        overviewRenderStage(s);
        crossRenderStage(s);
        pipRenderStage(s);
    });
    // The overview's layout changes with the windows.
    const auto later = [] { afterEvent([] { overviewRefresh(); }); };
    g_onOpen   = Event::bus()->m_events.window.open.listen([later](PHLWINDOW) { later(); });
    g_onClose  = Event::bus()->m_events.window.close.listen([later](PHLWINDOW w) {
        pipWindowClosed(w);
        later();
    });
    g_onMoveWs = Event::bus()->m_events.window.moveToWorkspace.listen([later](PHLWINDOW, PHLWORKSPACE) { later(); });
    g_onKey         = Event::bus()->m_events.input.keyboard.key.listen([](IKeyboard::SKeyEvent e, Event::SCallbackInfo&) { crossKey(e.keycode, e.state == WL_KEYBOARD_KEY_STATE_PRESSED); });

    inputInit();
    eventFilesSweep();
    markExisting();

    HyprlandAPI::reloadConfig();

    return {"hypr-strata", "Strata: a 2D workspace grid layout", "Reflectionist", "1.11.2"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    afterEventCleanup();
    g_onFocus.reset();
    g_onFullscreen.reset();
    g_onWorkspace.reset();
    g_onRenderPre.reset();
    g_onRenderStage.reset();
    g_onKey.reset();
    g_onOpen.reset();
    g_onClose.reset();
    g_onMoveWs.reset();
    crossCleanup();
    overviewCleanup();
    eventFilesCleanup();
    wallpaperCleanup();
    inputCleanup();
    pipCleanup();
    // The last frame's pass is cleared only when the next one begins; a cross
    // element left in it would then run destructor code that's been unloaded.
    if (g_pHyprRenderer)
        g_pHyprRenderer->m_renderPass.removeAllOfType("CStrataCrossPass");
    if (g_pHyprRenderer)
        g_pHyprRenderer->m_renderPass.removeAllOfType("CStrataOverviewPass");
    if (g_pHyprRenderer)
        g_pHyprRenderer->m_renderPass.removeAllOfType("CStrataWallpaperPass");
    if (g_pHyprRenderer)
        g_pHyprRenderer->m_renderPass.removeAllOfType("CStrataPipPass");
    for (const auto& [name, fn] : LUA_FNS)
        HyprlandAPI::removeLuaFunction(PHANDLE, "strata", name);
    HyprlandAPI::removeAlgo(PHANDLE, "strata");
}
