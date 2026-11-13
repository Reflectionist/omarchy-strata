#pragma once

// Strata: a 2D workspace grid for Hyprland 0.56.
//
// Every workspace on the `strata` layout is one row ("stratum") of a grid that
// shares a single horizontal axis per monitor. Columns keep Hyprland's
// scrolling-layout data (order, widths, stacking) but each also has an
// absolute x, so rows can have blank space between windows, and one camera per
// monitor shows the same x on every stratum.
//
// CStrataAlgorithm derives from the stock scrolling algorithm so everything
// that inspects scrolling layouts (Lua's w.layout, scrolling's layout
// messages, scripts written for it) keeps working. Positions are applied by a
// hook on SScrollingData::recalculate, which every placement path funnels
// through.
//
// Units: "u" = fractions of the usable width (what scrolling calls column
// width). The viewport is 1 u wide.

// Standard headers first, before the access override below: these are the
// ones Hyprland's headers include, and parsed under `#define private public`
// they would break. Any header added to that region needs its standard
// dependencies listed here.
#include <algorithm>
#include <any>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <expected>
#include <format>
#include <fstream>
#include <functional>
#include <iostream>
#include <list>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <ranges>
#include <regex>
#include <set>
#include <span>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <variant>
#include <vector>

// The scrolling algorithm keeps its data private; we extend it in place.
#define private public
#include <hyprland/src/layout/algorithm/tiled/scrolling/ScrollingAlgorithm.hpp>
#include <hyprland/src/layout/algorithm/tiled/scrolling/ScrollingFullscreenHandler.hpp>
#undef private

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/config/values/ConfigValues.hpp>
#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>

inline HANDLE PHANDLE = nullptr;

namespace Strata {
    using Layout::ITarget;
    using Layout::Tiled::SColumnData;
    using Layout::Tiled::SScrollingTargetData;

    constexpr double EPS = 1e-4;
    // Column widths, in screen widths.
    constexpr float MIN_COLUMN_WIDTH = 0.05F;
    constexpr float MAX_COLUMN_WIDTH = 1.F;

    struct SConfig {
        SP<Config::Values::CFloatValue>  step;        // window step-move (u)
        SP<Config::Values::CFloatValue>  viewStep;    // visual focus step through blank space (u)
        SP<Config::Values::CFloatValue>  fineStep;    // fine nudge (u)
        SP<Config::Values::CFloatValue>  slotWidth;   // blank slot width, 0 = scrolling:column_width
        SP<Config::Values::CIntValue>    jumpNear;    // jump to the next window within this many view steps
        SP<Config::Values::CIntValue>    margin;      // view steps of travel past the outermost window
        SP<Config::Values::CBoolValue>   wrap;        // horizontal wrap at the travel limits
        SP<Config::Values::CBoolValue>   closeGap;    // closing a window pulls the columns to its right in
        SP<Config::Values::CStringValue> landFocus;   // switching strata: "grid" (window under the view) or "last"
        SP<Config::Values::CStringValue> landPast;    // landing past a stratum's windows: "blank" (stay) or "nearest"
        SP<Config::Values::CStringValue> crossTrigger;   // move | held | change | hold | off
        SP<Config::Values::CStringValue> crossPlacement; // bottom | center | topleft
        SP<Config::Values::CFloatValue>  crossSize;      // centre tile width, fraction of the screen
        SP<Config::Values::CIntValue>    crossFadeMs;    // how long it stays after the last move
        SP<Config::Values::CFloatValue>  debugZoom;      // <0 off; 0..1 holds the overview zoom there (screenshots)
    };
    inline SConfig g_cfg;

    // Where you are on a monitor's grid: the camera (left edge of the viewport)
    // and the cursor, the slot visual focus is on. A blank cursor means no
    // window there and no window has keyboard focus.
    struct SView {
        double      camera  = 0.0;
        std::optional<double> fsReturn; // the camera before a fullscreen window took the view
        double      cursorX = 0.0;
        double      cursorW = 0.5;
        bool        blank   = false;
        bool        inhibited = false;
        WORKSPACEID lastWs  = WORKSPACE_INVALID;
        int         landHint = 0; // -1 arriving from below (going up), +1 from above, 0 direct

        // Back to where another view was (camera and cursor).
        void restoreFrom(const SView& o) {
            camera  = o.camera;
            cursorX = o.cursorX;
            cursorW = o.cursorW;
            blank   = o.blank;
        }
    };

    SView& viewFor(MONITORID id);

    class CStrataAlgorithm : public Layout::Tiled::CScrollingAlgorithm {
      public:
        CStrataAlgorithm();
        virtual ~CStrataAlgorithm();

        virtual void                       newTarget(SP<ITarget> target);
        virtual void                       removeTarget(SP<ITarget> target);
        virtual void                       resizeTarget(const Vector2D& delta, SP<ITarget> target, Layout::eRectCorner corner = Layout::CORNER_NONE);
        virtual void                       recalculate(Layout::eRecalculateReason reason = Layout::RECALCULATE_REASON_UNKNOWN);
        virtual SP<ITarget>                getNextCandidate(SP<ITarget> old);
        virtual Config::ErrorResult        layoutMsg(const std::string_view& sv);
        virtual std::optional<std::string> layoutName() const {
            return "strata";
        }

        // Placement (the recalculate hook lands here).
        void            strataRecalc(bool instant);

        PHLWORKSPACE    workspace() const;
        MONITORID       monitorID() const;
        bool            visibleNow() const;
        CBox            workRect() const;
        SView&          view() const;

        double          effW(const SP<SColumnData>& c) const;
        double          xOf(const SP<SColumnData>& c);
        void            setX(const SP<SColumnData>& c, double x);
        void            normalize();
        SP<SColumnData> columnAt(double x) const; // column covering x
        SP<SColumnData> columnOf(PHLWINDOW w) const;
        SP<SScrollingTargetData> bestIn(const SP<SColumnData>& c, int hint) const;

        // Operations on this row.
        bool            stepMove(PHLWINDOW w, int dir, bool fine);
        bool            swapColumn(PHLWINDOW w, int dir);
        bool            dropAt(PHLWINDOW w, double x, double width);
        bool            stackInto(PHLWINDOW w, const SP<SColumnData>& into, int at);

        // Pending placement for a window about to arrive (vertical moves,
        // overview drops).
        struct SExpect {
            double                x     = 0.0;
            bool                  stack = false;
            int                   dir   = 0; // stacking from above (+1, land on top) or below (-1, bottom)
            std::optional<int>    at;        // stacking: this place in the column instead, top to bottom
            std::optional<double> width;     // its own column: this width
        };

        std::unordered_map<const SColumnData*, double> m_x;
        std::optional<double>                          m_seedX;
        WP<Desktop::View::CWindow>                     m_lastFocus;
    };

    // Grid-wide operations (view.cpp).
    CStrataAlgorithm*              strataFor(const PHLWORKSPACE& ws);
    PHLWORKSPACE                   workspaceByID(WORKSPACEID id);
    PHLWINDOW                      windowByAddress(const std::string& address);
    std::string                    addressOf(const PHLWINDOW& w); // "0x…", as hyprctl prints it
    CStrataAlgorithm*              activeStrata(PHLMONITOR* monOut = nullptr);
    void                           recalcMonitor(MONITORID id, bool animate = true);
    void                           fitSlot(SView& v, double x, double w);
    std::pair<double, double>      bounds(MONITORID id);
    std::pair<double, double>      travel(MONITORID id); // bounds plus the margin: where focus and the camera can go
    void                           keepInSpan(MONITORID id, bool closingOverview = false);
    bool                           draggingTiled();
    double                         slotWidth();
    void                           setCursorTo(CStrataAlgorithm* a, const SP<SColumnData>& c);
    void                           focusWindow(PHLWINDOW w);
    void                           unfocus();
    void                           emit();

    std::string                    nav(int dir, bool forceWrap);
    std::string                    home();
    std::string                    pan(double du, double extra = 0.0);
    std::string                    settle();
    std::string                    land(int hint);
    std::string                    aim(double x, double w = 0.0);
    std::string                    moveWindow(PHLWINDOW w, char dir);
    bool                           widenWindow(PHLWINDOW w, int dir);
    void                           expect(const std::string& address, CStrataAlgorithm::SExpect e);
    std::optional<CStrataAlgorithm::SExpect> takeExpect(PHLWINDOW w);

    // Window widths per stratum (workspace name -> column width), for windows
    // that open there. A window still opening when Lua routes it elsewhere
    // (opening()) counts as opening where it arrives.
    inline std::unordered_map<std::string, double> g_widths;
    void                           opening(const std::string& address);
    bool                           firstPlacement(PHLWINDOW w);
    void                           markExisting();

    // Work for after the current event (Hyprland's own focus choice, a switch
    // settling). Not the event loop's doLater: a callback still queued there
    // when the plugin unloads (a hot swap: every window leaves the layout)
    // runs code that's gone. These run from a timer removed on unload.
    void                           afterEvent(std::function<void()> fn);
    void                           afterEventCleanup();

    void                           onFocus(PHLWINDOW w, Desktop::eFocusReason reason);
    void                           onFullscreen(PHLWINDOW w);

    // Private strata: the cross and the overview show their windows as
    // blank cards, not live content. By workspace name ("7" for a numbered
    // one): a stratum's workspace gets a new id each time it's made again, and
    // an old id can come back as another stratum's.
    inline std::unordered_set<std::string> g_private;
    bool                           isPrivate(const PHLWORKSPACE& ws);
    void                           onWorkspace(PHLWORKSPACE ws);

    // Hyprland splits socket events at 1024 bytes: bigger payloads go to a
    // file in $XDG_RUNTIME_DIR and the event carries "@<path>".
    void                           postEvent(const std::string& name, const std::string& json);
    void                           eventFilesCleanup();
    void                           eventFilesSweep();
}
