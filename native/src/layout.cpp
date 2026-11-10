#include "strata.hpp"

#include <algorithm>
#include <cmath>

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/config/shared/workspace/WorkspaceRuleManager.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/rule/windowRule/WindowRuleApplicator.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/algorithm/Algorithm.hpp>
#include <hyprland/src/layout/space/Space.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/PointerConstraints.hpp>
#include <hyprland/src/helpers/MiscFunctions.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>

#include <hyprutils/string/VarList.hpp>

#include "cross.hpp"
#include "overview.hpp"

using namespace Strata;
using namespace Layout;
using namespace Layout::Tiled;
using Hyprutils::String::CVarList;

CStrataAlgorithm::CStrataAlgorithm() = default;

CStrataAlgorithm::~CStrataAlgorithm() = default;

PHLWORKSPACE CStrataAlgorithm::workspace() const {
    if (!m_parent || !m_parent->space())
        return nullptr;
    return m_parent->space()->workspace();
}

MONITORID CStrataAlgorithm::monitorID() const {
    const auto WS = workspace();
    return WS && WS->m_monitor ? WS->m_monitor->m_id : MONITOR_INVALID;
}

bool CStrataAlgorithm::visibleNow() const {
    const auto WS = workspace();
    return WS && WS->isVisible();
}

CBox CStrataAlgorithm::workRect() const {
    return m_parent && m_parent->space() ? m_parent->space()->workArea() : CBox{};
}

SView& CStrataAlgorithm::view() const {
    return viewFor(monitorID());
}

double CStrataAlgorithm::effW(const SP<SColumnData>& c) const {
    static const auto PFSONONE = CConfigValue<Config::INTEGER>("scrolling:fullscreen_on_one_column");
    if (*PFSONONE && m_scrollingData->columns.size() == 1)
        return 1.0;
    return c->getColumnWidth();
}

double CStrataAlgorithm::xOf(const SP<SColumnData>& c) {
    const auto IT = m_x.find(c.get());
    if (IT == m_x.end()) {
        normalize();
        return m_x[c.get()];
    }
    return IT->second;
}

void CStrataAlgorithm::setX(const SP<SColumnData>& c, double x) {
    m_x[c.get()] = x;
}

// Where each window's column was when it left a row (floated, unmapped for a
// moment, moved away), so it comes back to its own spot. By workspace name:
// a stratum it left empty is destroyed, and made anew when it comes back.
struct SLeftAt {
    WP<Desktop::View::CWindow> window;
    std::string                workspace;
    double                     x = 0.0;
};
static std::vector<SLeftAt> g_leftAt;

// Keep the positions in step with the scrolling data: drop columns that are
// gone, place new ones right after their predecessor (or at the seed for a
// first column), and push columns right so none overlap. Gaps are never
// closed here.
void CStrataAlgorithm::normalize() {
    auto& cols = m_scrollingData->columns;

    std::erase_if(m_x, [&cols](const auto& e) { return std::ranges::none_of(cols, [&e](const auto& c) { return c.get() == e.first; }); });

    double prevEnd = -INFINITY;
    for (size_t i = 0; i < cols.size(); ++i) {
        const auto& C  = cols[i];
        auto        IT = m_x.find(C.get());
        if (IT == m_x.end()) {
            double x = prevEnd;
            if (i == 0) {
                // first column: before the next known one, or at the seed / cursor
                double seed = m_seedX.value_or(view().cursorX);
                if (cols.size() > 1) {
                    const auto NIT = m_x.find(cols[1].get());
                    if (NIT != m_x.end())
                        seed = std::min(seed, NIT->second - effW(C));
                }
                x = seed;
            }
            IT = m_x.emplace(C.get(), x).first;
        }
        if (IT->second < prevEnd - EPS)
            IT->second = prevEnd;
        prevEnd = IT->second + effW(C);
    }
}

SP<SColumnData> CStrataAlgorithm::columnAt(double x) const {
    for (const auto& c : m_scrollingData->columns) {
        const auto IT = m_x.find(c.get());
        if (IT == m_x.end())
            continue;
        if (x >= IT->second - EPS && x < IT->second + effW(c) - EPS)
            return c;
    }
    return nullptr;
}

SP<SColumnData> CStrataAlgorithm::columnOf(PHLWINDOW w) const {
    if (!w || !w->layoutTarget())
        return nullptr;
    const auto D = dataFor(w->layoutTarget());
    return D ? D->column.lock() : nullptr;
}

// The window to focus in a column: the one last used there, else the bottom
// one when arriving from below (hint -1), else the top one.
SP<SScrollingTargetData> CStrataAlgorithm::bestIn(const SP<SColumnData>& c, int hint) const {
    if (!c || c->targetDatas.empty())
        return nullptr;
    if (hint < 0)
        return c->targetDatas.back();
    if (hint > 0)
        return c->targetDatas.front();
    const auto LAST = c->lastFocusedTarget.lock();
    if (LAST && LAST->column.lock() == c && LAST->target && Desktop::View::validMapped(LAST->target->window()))
        return LAST;
    return c->targetDatas.front();
}

void CStrataAlgorithm::strataRecalc(bool instant) {
    if (!m_parent || !m_parent->space() || !m_parent->space()->workspace() || !m_parent->space()->workspace()->m_monitor)
        return;

    const auto WORKSPACE = m_parent->space()->workspace();
    const auto MONITOR   = WORKSPACE->m_monitor.lock();
    const CBox USABLE    = usableArea();
    const auto WORKAREA  = m_parent->space()->workArea();
    const CBox MONBOX    = MONITOR->logicalBox();

    const auto  WORKSPACERULE = Config::workspaceRuleMgr()->getWorkspaceRuleFor(WORKSPACE);
    static auto PGAPSINDATA   = CConfigValue<Config::IComplexConfigValue>("general:gaps_in");
    auto* const PGAPSIN       = sc<Config::CCssGapData*>((PGAPSINDATA.ptr()));
    const auto  GAPSIN        = (WORKSPACERULE && WORKSPACERULE->m_gapsIn.has_value()) ? WORKSPACERULE->m_gapsIn.value() : *PGAPSIN;

    auto&       FS = m_scrollingFullscreenHandler;

    if (const auto FULLSCREEN_WINDOW = Fullscreen::controller()->getFullscreenWindow(WORKSPACE); FULLSCREEN_WINDOW && !Fullscreen::controller()->layoutManagedFS(FULLSCREEN_WINDOW)) {
        FS->setNoMembersAboveFullscreen();
        return;
    }

    m_scrollingData->controller->setDirection(Layout::Tiled::SCROLL_DIR_RIGHT);
    normalize();

    // Hidden rows warp: their windows move only so they're in place when the row slides in.
    instant = instant || !WORKSPACE->isVisible();

    const auto& cols   = m_scrollingData->columns;
    const auto  CAMERA = view().camera;

    const auto  stripBox = [&](size_t i) -> CBox {
        const double X = m_x[cols[i].get()];
        return CBox{WORKAREA.x + (X - CAMERA) * USABLE.w, WORKAREA.y, effW(cols[i]) * USABLE.w, USABLE.h};
    };

    // Inner gaps only where columns touch, so a packed row looks exactly like
    // stock scrolling and a lone window fills its slot.
    const auto touching = [&](size_t a, size_t b) { return std::abs(m_x[cols[a].get()] + effW(cols[a]) - m_x[cols[b].get()]) < EPS; };

    const auto withGaps = [&](const CBox& logical, size_t ci, size_t ti, bool fullscreenOrHidden) -> STargetBox {
        if (fullscreenOrHidden)
            return {.logicalBox = logical, .visualBox = logical};

        CBox       visual = logical;
        const bool LEFT   = ci > 0 && touching(ci - 1, ci);
        const bool RIGHT  = ci + 1 < cols.size() && touching(ci, ci + 1);
        const bool TOP    = ti > 0;
        const bool BOTTOM = ti + 1 < cols[ci]->targetDatas.size();

        const auto TL = Vector2D(LEFT ? (double)GAPSIN.m_left : 0.0, TOP ? (double)GAPSIN.m_top : 0.0);
        const auto BR = Vector2D(RIGHT ? (double)GAPSIN.m_right : 0.0, BOTTOM ? (double)GAPSIN.m_bottom : 0.0);

        visual.x += TL.x;
        visual.y += TL.y;
        visual.w = std::max(1.0, visual.w - TL.x - BR.x);
        visual.h = std::max(1.0, visual.h - TL.y - BR.y);
        return {.logicalBox = logical, .visualBox = visual};
    };

    // A fullscreen window covers the monitor when its column fills the view.
    // Stock's isFullscreen(..., covering) can't say: it reads scrolling's tape,
    // which the grid's camera doesn't move, and its "no" drops pointer locks, so
    // a game anywhere but the first column lost the mouse. A hidden row isn't
    // on screen to judge, and must not drop a lock held on the one that is.
    const auto fillsView = [&](size_t i) {
        const double X = m_x[cols[i].get()];
        return !WORKSPACE->isVisible() || (X <= CAMERA + EPS && X + effW(cols[i]) >= CAMERA + 1.0 - EPS);
    };

    bool                     coveringFS = false;
    SP<SScrollingTargetData> currentFsTdata;

    for (size_t i = 0; i < cols.size(); ++i) {
        const auto& COL    = cols[i];
        const auto  STRIP  = stripBox(i);
        const bool  HAS_FS = COL->targetDatas.size() == 1 && COL->targetDatas.at(0)->target && FS->isFullscreen(COL->targetDatas.at(0)->target.lock(), std::nullopt, std::nullopt);

        double y = 0.0;
        for (size_t j = 0; j < COL->targetDatas.size(); ++j) {
            const auto TDATA   = COL->targetDatas[j];
            const auto TARGET  = TDATA->target.lock();
            const auto FS_MODE = FS->getFullscreenModes(TARGET).internal;
            bool       covering = false;

            if (HAS_FS) {
                if (FS_MODE == Fullscreen::FSMODE_FULLSCREEN) {
                    if (fillsView(i)) {
                        TDATA->layoutBox = MONBOX;
                        currentFsTdata   = TDATA;
                        coveringFS = covering = true;
                    } else
                        TDATA->layoutBox = CBox{STRIP.x, MONBOX.y, STRIP.w, MONBOX.h};
                } else if (FS_MODE == Fullscreen::FSMODE_MAXIMIZED) {
                    if (FS->isFullscreen(TARGET, Fullscreen::FSMODE_MAXIMIZED, true)) {
                        TDATA->layoutBox = WORKAREA;
                        currentFsTdata   = TDATA;
                        coveringFS = covering = true;
                    } else
                        TDATA->layoutBox = CBox{STRIP.x, WORKAREA.y, STRIP.w, WORKAREA.h};
                } else
                    TDATA->layoutBox = CBox{WORKAREA.pos() - Vector2D{100000.0, 100000.0}, Vector2D{1.0, 1.0}};
            } else {
                const double H   = COL->getTargetSize(j) * USABLE.h;
                TDATA->layoutBox = CBox{STRIP.x, WORKAREA.y + y, STRIP.w, H};
                y += H;
            }

            if (TARGET) {
                if (covering)
                    Fullscreen::controller()->m_windowPosSettingQueued = true;
                TARGET->setPositionGlobal(withGaps(TDATA->layoutBox, i, j, HAS_FS && FS_MODE == Fullscreen::FSMODE_FULLSCREEN));
                if (instant)
                    TARGET->warpPositionSize();
            }
        }
    }

    FS->sScrollingDataRecalculateHelper(currentFsTdata, MONITOR, coveringFS);

    // The helper drops every pointer lock unless a fullscreen column covers the
    // view, windowed ones too, and nothing takes them back except a focus change
    // that needn't come. One taken while out of view left the pointer on the old
    // window, and motion follows the pointer: take that one again.
    if (const auto WIN = Desktop::focusState()->window(); WIN && WIN->m_workspace == WORKSPACE && !WIN->m_layoutFlags.cantLockCursor) {
        if (const auto SURF = WIN->wlSurface(); SURF && SURF->constraint()) {
            const auto LOCK = SURF->constraint();
            if (LOCK->isActive() && g_pSeatManager->m_state.pointerFocus != SURF->resource())
                LOCK->deactivate();
            LOCK->activate();
        }
    }
}

void CStrataAlgorithm::recalculate(Layout::eRecalculateReason reason) {
    // No camera fitting here: the view belongs to the grid, not the workspace.
    (void)reason;
    if (!m_parent || !m_parent->space() || !m_parent->space()->workspace() || !m_parent->space()->workspace()->m_monitor)
        return;
    m_scrollingData->recalculate();
}

void CStrataAlgorithm::newTarget(SP<ITarget> target) {
    const auto WIN     = target->window();
    const bool OPENING = firstPlacement(WIN);

    // Drag and drop between tiled windows: the stock drop logic decides the
    // column, positions follow from order.
    if (g_layoutManager->dragController()->wasDraggingWindow() && g_layoutManager->dragController()->draggingTiled()) {
        const auto MOUSE = g_pInputManager->getMouseCoordsInternal();
        const auto UNDER = Desktop::viewState()->hitTest().windowAt(MOUSE, Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS);
        if (!UNDER || UNDER->layoutTarget() == target || !dataFor(UNDER->layoutTarget())) {
            // Dropped on blank space: right there, on the step grid.
            const auto   WORK = workRect();
            const double STEP = std::max(0.01, (double)g_cfg.step->value());
            const double W    = WIN && WIN->m_ruleApplicator->static_.scrollingWidth ? *WIN->m_ruleApplicator->static_.scrollingWidth : defaultColumnWidth();
            const double AT   = view().camera + (MOUSE.x - WORK.x) / std::max(1.0, WORK.w) - W / 2.0;
            expect(addressOf(WIN), SExpect{.x = std::round(AT / STEP) * STEP});
        } else {
            CScrollingAlgorithm::newTarget(target);
            normalize();
            m_scrollingData->recalculate();
            return;
        }
    }

    auto&      v       = view();
    const bool VISIBLE = visibleNow();
    const auto EXP     = takeExpect(WIN);
    // Its width: an expected one (an overview drop), else its own window
    // rule's, else, opening here, this stratum's window width.
    auto WIDTH = EXP && EXP->width ? std::optional<float>((float)*EXP->width) : WIN ? WIN->m_ruleApplicator->static_.scrollingWidth : std::nullopt;
    if (!WIDTH && OPENING && workspace()) {
        if (const auto IT = g_widths.find(workspace()->m_name); IT != g_widths.end())
            WIDTH = (float)std::clamp(IT->second, (double)MIN_COLUMN_WIDTH, (double)MAX_COLUMN_WIDTH);
    }

    std::optional<double> back;
    if (WIN && workspace()) {
        const auto NAME = workspace()->m_name;
        if (const auto IT = std::ranges::find_if(g_leftAt, [&](const SLeftAt& e) { return e.window.lock() == WIN && e.workspace == NAME; }); IT != g_leftAt.end()) {
            back = IT->x;
            g_leftAt.erase(IT);
        }
    }

    normalize();

    double x;
    if (!EXP && back) {
        // Back on this row (re-tiled, or remapped): where it was, not where
        // you happen to be looking on another stratum.
        x = *back;
        if (const auto UNDER = columnAt(x + EPS); UNDER)
            x = xOf(UNDER) + UNDER->getColumnWidth();
    } else if (EXP) {
        x = EXP->x;
        if (EXP->stack) {
            // Stack into the column under x, landing on the side we came from.
            if (const auto UNDER = columnAt(x); UNDER) {
                if (EXP->at)
                    UNDER->add(target, std::clamp(*EXP->at, 0, (int)UNDER->targetDatas.size()) - 1);
                else if (EXP->dir < 0)
                    UNDER->add(target);
                else
                    UNDER->add(target, -1);
                m_scrollingData->recalculate();
                return;
            }
        }
    } else if (VISIBLE && v.blank)
        x = v.cursorX; // open where you're looking
    else if (const auto FC = VISIBLE ? columnOf(Desktop::focusState()->window()) : nullptr; FC)
        x = xOf(FC) + FC->getColumnWidth(); // beside the focused window (its real width: it won't be alone any more)
    else {
        // A stratum you're not on (routed windows): in view when you get there.
        x = v.cursorX;
        if (const auto UNDER = columnAt(x + EPS); UNDER)
            x = xOf(UNDER) + UNDER->getColumnWidth();
    }

    // Column order follows x.
    int64_t after = -1;
    for (size_t i = 0; i < m_scrollingData->columns.size(); ++i) {
        if (xOf(m_scrollingData->columns[i]) < x - EPS)
            after = i;
    }

    SP<SColumnData> col = after + 1 >= (int64_t)m_scrollingData->columns.size() ? m_scrollingData->add(WIDTH) : m_scrollingData->add(after, WIDTH);
    col->add(target);
    setX(col, x);
    m_seedX = x;
    normalize();
    m_seedX.reset();

    if (VISIBLE) {
        // Not while the overview is open: a window moved in from there (a
        // drop, SHIFT+arrows) doesn't take the view with it.
        if (!overviewOpen(monitorID())) {
            setCursorTo(this, col);
            if (!v.inhibited)
                fitSlot(v, xOf(col), effW(col));
        }
        recalcMonitor(monitorID());
    } else
        m_scrollingData->recalculate();
    emit();
}

void CStrataAlgorithm::removeTarget(SP<ITarget> target) {
    const auto DATA = dataFor(target);
    if (!DATA)
        return;

    if (m_scrollingFullscreenHandler->isFullscreen(target, std::nullopt, std::nullopt))
        Fullscreen::controller()->setFullscreenMode(target->window(), Fullscreen::FSMODE_NONE);

    const auto COL     = DATA->column.lock();
    const auto COUNT   = m_scrollingData->columns.size();
    const auto X       = COL ? xOf(COL) : 0.0;
    const auto W       = COL ? effW(COL) : 0.0;
    auto&      v       = view();
    const bool CURSOR  = COL && !v.blank && std::abs(v.cursorX - X) < EPS && visibleNow();

    if (const auto WIN = target->window(); WIN && COL && workspace()) {
        const auto NAME = workspace()->m_name;
        std::erase_if(g_leftAt, [&](const SLeftAt& e) { return e.window.expired() || (e.window.lock() == WIN && e.workspace == NAME); });
        g_leftAt.push_back({.window = WIN, .workspace = NAME, .x = X});
    }

    DATA->column->remove(target);

    if (m_scrollingData->columns.size() < COUNT) {
        // The column went with it. (Not for a window dragged off in the
        // overview: the spot it was dragged from stays blank.)
        if (g_cfg.closeGap->value() && !overviewDropping(target->window())) {
            for (const auto& c : m_scrollingData->columns) {
                if (m_x[c.get()] > X - EPS)
                    m_x[c.get()] -= W;
            }
        }
        if (CURSOR) {
            v.blank   = true;
            v.cursorX = X;
            v.cursorW = std::max(W, slotWidth());
        }
    }

    normalize();
    m_scrollingData->recalculate();
    emit();

    // The span may have shrunk: once Hyprland has picked its next focus.
    if (const auto MON = monitorID(); MON != MONITOR_INVALID)
        afterEvent([MON] { keepInSpan(MON); });
}

void CStrataAlgorithm::resizeTarget(const Vector2D& delta, SP<ITarget> target, Layout::eRectCorner corner) {
    const auto DATA = dataFor(target);
    const auto COL  = DATA ? DATA->column.lock() : nullptr;
    if (!COL) {
        CScrollingAlgorithm::resizeTarget(delta, target, corner);
        return;
    }

    // Widths are Strata's own. Stock measures the right edge against the
    // screen as scrolling sees it (strips packed in order, its own scroll
    // offset), which isn't where Strata puts them: a window could stop growing
    // anywhere, even with nothing but blank space beside it. Here a column
    // grows into blank space up to a screen wide and pushes whatever is on
    // that side along. Heights in a stack stay stock's (its width clamp would
    // still run, so the width is put back).
    const double X = xOf(COL), CW = COL->getColumnWidth();
    if (delta.y != 0.0 && COL->targetDatas.size() > 1) {
        CScrollingAlgorithm::resizeTarget({0.0, delta.y}, target, corner);
        COL->setColumnWidth((float)CW);
    }

    // A lone column that fills the screen (fullscreen_on_one_column) shows no
    // width to change.
    static const auto PFSONONE = CConfigValue<Config::INTEGER>("scrolling:fullscreen_on_one_column");
    const bool        FORCED   = *PFSONONE && m_scrollingData->columns.size() == 1;
    const bool        LEFT     = edgeLeft(corner);
    const double      USABLE_W = std::max(1.0, usableArea().w);
    const double      NW       = std::clamp(CW + (LEFT ? -delta.x : delta.x) / USABLE_W, (double)MIN_COLUMN_WIDTH, (double)MAX_COLUMN_WIDTH);

    if (!FORCED && delta.x != 0.0 && std::abs(NW - CW) > 1e-6) {
        COL->setColumnWidth((float)NW);
        if (LEFT) {
            // The right edge stays; columns on the left move over.
            setX(COL, X + CW - NW);
            auto& cols = m_scrollingData->columns;
            for (int64_t i = m_scrollingData->idx(COL) - 1; i >= 0; --i) {
                const double NEXT = xOf(cols[i + 1]);
                if (xOf(cols[i]) + effW(cols[i]) > NEXT + EPS)
                    setX(cols[i], NEXT - effW(cols[i]));
            }
        }
    }
    normalize();

    // From the keyboard (no pointer drag), the view keeps the window in sight.
    // Under the pointer it doesn't move: the edge stays under the pointer.
    const bool MOUSE = g_layoutManager->dragController()->target() != nullptr;
    const auto WIN   = target->window();
    if (!MOUSE && visibleNow() && WIN && WIN == Desktop::focusState()->window() && !view().inhibited) {
        setCursorTo(this, COL);
        fitSlot(view(), xOf(COL), effW(COL));
        recalcMonitor(monitorID());
    } else
        m_scrollingData->recalculate(true);
    emit();
    if (NW < CW)
        keepInSpan(monitorID());
}

// After a close: a window still on screen, nearest to the one that went;
// nothing if the view is empty (you stay where you were looking).
SP<ITarget> CStrataAlgorithm::getNextCandidate(SP<ITarget> old) {
    const auto  CENTER = old->position().middle();
    const auto& v      = view();
    SP<ITarget> best;
    double      bestD = INFINITY;

    for (const auto& c : m_scrollingData->columns) {
        const double X = xOf(c), W = effW(c);
        if (X + W <= v.camera + EPS || X >= v.camera + 1.0 - EPS)
            continue;
        for (const auto& td : c->targetDatas) {
            if (!td->target || !Desktop::View::validMapped(td->target->window()) || td->target == old)
                continue;
            const double D = vecToRectDistanceSquared(CENTER, td->layoutBox.pos(), td->layoutBox.pos() + td->layoutBox.size());
            if (D < bestD) {
                bestD = D;
                best  = td->target.lock();
            }
        }
    }
    return best;
}

// Step-move the window's column toward dir: through blank space by steps
// (snapped to the step grid), stacking into the neighbour once touching. A
// window sharing its column first pops out beside it.
bool CStrataAlgorithm::stepMove(PHLWINDOW w, int dir, bool fine) {
    const auto TDATA = w ? dataFor(w->layoutTarget()) : nullptr;
    const auto COL   = TDATA ? TDATA->column.lock() : nullptr;
    if (!COL)
        return false;

    auto&        cols = m_scrollingData->columns;
    const auto   IDX  = m_scrollingData->idx(COL);
    const double X = xOf(COL), W = effW(COL);

    if (COL->targetDatas.size() > 1) {
        // Pop out beside the column, on the side we're moving to.
        COL->remove(TDATA->target.lock());
        const auto NEW = dir > 0 ? (IDX + 1 >= (int64_t)cols.size() ? m_scrollingData->add() : m_scrollingData->add(IDX)) : m_scrollingData->add(IDX - 1);
        NEW->add(TDATA);
        const double NW = NEW->getColumnWidth();
        if (dir > 0)
            setX(NEW, X + W);
        else {
            double nx = X - NW;
            const auto PI = m_scrollingData->idx(NEW) - 1;
            if (PI >= 0) {
                const double PREVEND = xOf(cols[PI]) + effW(cols[PI]);
                if (nx < PREVEND - EPS) {
                    // No room on the left: make it by pushing this side right.
                    const double SHIFT = PREVEND - nx;
                    for (size_t i = m_scrollingData->idx(NEW) + 1; i < cols.size(); ++i)
                        m_x[cols[i].get()] += SHIFT;
                    nx = PREVEND;
                }
            }
            setX(NEW, nx);
        }
        normalize();
        setCursorTo(this, NEW);
        fitSlot(view(), xOf(NEW), effW(NEW));
        recalcMonitor(monitorID());
        return true;
    }

    const auto NB = dir > 0 ? m_scrollingData->next(COL) : m_scrollingData->prev(COL);

    if (NB) {
        const double NX = xOf(NB), NW = effW(NB);
        const bool   TOUCHING = dir > 0 ? std::abs(X + W - NX) < EPS : std::abs(NX + NW - X) < EPS;
        if (TOUCHING) {
            // Stack into the neighbour.
            COL->remove(TDATA->target.lock());
            NB->add(TDATA);
            normalize();
            setCursorTo(this, NB);
            fitSlot(view(), xOf(NB), effW(NB));
            recalcMonitor(monitorID());
            keepInSpan(monitorID());
            return true;
        }
    }

    const double STEP = std::max(0.01, (double)(fine ? g_cfg.fineStep->value() : g_cfg.step->value()));
    double       nx;
    if (fine)
        nx = X + dir * STEP;
    else if (dir > 0)
        nx = (std::floor(X / STEP + EPS) + 1) * STEP;
    else
        nx = (std::ceil(X / STEP - EPS) - 1) * STEP;

    if (NB)
        nx = dir > 0 ? std::min(nx, xOf(NB) - W) : std::max(nx, xOf(NB) + effW(NB));

    setX(COL, nx);
    normalize();
    setCursorTo(this, COL);
    fitSlot(view(), xOf(COL), W);
    recalcMonitor(monitorID());
    keepInSpan(monitorID()); // moved in from the edge: that space is gone
    crossPoke("window");
    return true;
}

// A window in its own column at x: the column it has to itself, or a new one
// (this wide) when it leaves a stack. It goes before any column already at x;
// whatever it overlaps on the right moves right.
bool CStrataAlgorithm::dropAt(PHLWINDOW w, double x, double width) {
    const auto TDATA = w ? dataFor(w->layoutTarget()) : nullptr;
    const auto COL   = TDATA ? TDATA->column.lock() : nullptr;
    if (!COL)
        return false;

    auto&           cols = m_scrollingData->columns;
    SP<SColumnData> col;
    if (COL->targetDatas.size() == 1) {
        if (std::abs(xOf(COL) - x) < EPS)
            return false;
        col = COL;
        int64_t to = 0;
        for (const auto& c : cols) {
            if (c != col && xOf(c) < x - EPS)
                ++to;
        }
        for (int64_t from = m_scrollingData->idx(col); from != to; from += from < to ? 1 : -1) {
            const int64_t NEXT = from < to ? from + 1 : from - 1;
            std::swap(cols[from], cols[NEXT]);
            m_scrollingData->controller->swapStrips(from, NEXT);
        }
    } else {
        COL->remove(TDATA->target.lock());
        int64_t after = -1;
        for (size_t i = 0; i < cols.size(); ++i) {
            if (xOf(cols[i]) < x - EPS)
                after = i;
        }
        col = after + 1 >= (int64_t)cols.size() ? m_scrollingData->add((float)width) : m_scrollingData->add(after, (float)width);
        col->add(TDATA);
    }
    setX(col, x);
    normalize();
    return true;
}

// Stack a window into a column, at place `at` (top to bottom, not counting
// the window itself). The spot it leaves stays blank.
bool CStrataAlgorithm::stackInto(PHLWINDOW w, const SP<SColumnData>& into, int at) {
    const auto TDATA = w ? dataFor(w->layoutTarget()) : nullptr;
    const auto COL   = TDATA ? TDATA->column.lock() : nullptr;
    if (!COL || !into)
        return false;
    if (COL == into && (int)COL->idx(TDATA->target.lock()) == at)
        return false;
    COL->remove(TDATA->target.lock());
    into->add(TDATA, std::clamp(at, 0, (int)into->targetDatas.size()) - 1);
    normalize();
    return true;
}

// Trade places with the neighbouring column, keeping the gap between them.
bool CStrataAlgorithm::swapColumn(PHLWINDOW w, int dir) {
    const auto COL = columnOf(w);
    if (!COL)
        return false;
    const auto NB = dir > 0 ? m_scrollingData->next(COL) : m_scrollingData->prev(COL);
    if (!NB)
        return false;

    const auto   L = dir > 0 ? COL : NB, R = dir > 0 ? NB : COL;
    const double LX = xOf(L), GAP = xOf(R) - (LX + effW(L));
    const auto   LI = m_scrollingData->idx(L), RI = m_scrollingData->idx(R);

    std::swap(m_scrollingData->columns.at(LI), m_scrollingData->columns.at(RI));
    m_scrollingData->controller->swapStrips(LI, RI);
    setX(R, LX);
    setX(L, LX + effW(R) + GAP);
    normalize();
    setCursorTo(this, COL);
    fitSlot(view(), xOf(COL), effW(COL));
    recalcMonitor(monitorID());
    return true;
}

Config::ErrorResult CStrataAlgorithm::layoutMsg(const std::string_view& sv) {
    const auto ARGS = CVarList(std::string{sv}, 0, ' ');
    const auto WIN  = Desktop::focusState()->window();
    auto&      v    = view();

    if (ARGS[0] == "move") {
        if (ARGS[1] == "+col" || ARGS[1] == "col") {
            nav(1, false);
            return {};
        }
        if (ARGS[1] == "-col") {
            nav(-1, false);
            return {};
        }
        // ±px pans the view. Unlike stock scrolling this never changes focus.
        try {
            const double PX = std::stod(std::string{ARGS[1]});
            pan(-PX / std::max(1.0, usableArea().w));
        } catch (...) { return Config::configError("failed to parse offset", Config::eConfigErrorLevel::ERROR, Config::eConfigErrorCode::INVALID_ARGUMENT); }
        return {};
    }

    if (ARGS[0] == "focus" && (ARGS[1] == "l" || ARGS[1] == "r")) {
        nav(ARGS[1] == "r" ? 1 : -1, false);
        return {};
    }

    if (ARGS[0] == "consume_or_expel") {
        if (ARGS[1] != "prev" && ARGS[1] != "next")
            return Config::configError("invalid direction, expected prev or next", Config::eConfigErrorLevel::ERROR, Config::eConfigErrorCode::INVALID_ARGUMENT);
        stepMove(WIN, ARGS[1] == "next" ? 1 : -1, ARGS[2] == "fine");
        emit();
        return {};
    }

    if (ARGS[0] == "swapcol") {
        swapColumn(WIN, ARGS[1] == "r" ? 1 : -1);
        emit();
        return {};
    }

    if (ARGS[0] == "center" || ARGS[0] == "fit_into_view") {
        if (const auto COL = columnOf(WIN); COL) {
            setCursorTo(this, COL);
            if (ARGS[0] == "center")
                v.camera = xOf(COL) + effW(COL) / 2.0 - 0.5;
            else
                fitSlot(v, xOf(COL), effW(COL));
            recalcMonitor(monitorID());
            emit();
        }
        return {};
    }

    if (ARGS[0] == "inhibit_scroll") {
        if (ARGS.size() == 1)
            v.inhibited = !v.inhibited;
        else
            v.inhibited = !(ARGS[1] == "0" || ARGS[1] == "false");
        return CScrollingAlgorithm::layoutMsg(sv);
    }

    // Everything else edits the scrolling data the stock way (colresize, fit,
    // consume, expel, promote, focus u/d, ...); positions then follow, and
    // the view only scrolls as far as needed to keep the focused column in view.
    const auto RES = CScrollingAlgorithm::layoutMsg(sv);
    normalize();
    if (const auto COL = columnOf(Desktop::focusState()->window()); COL && visibleNow()) {
        setCursorTo(this, COL);
        if (!v.inhibited)
            fitSlot(v, xOf(COL), effW(COL));
    }
    recalcMonitor(monitorID());
    emit();
    return RES;
}
