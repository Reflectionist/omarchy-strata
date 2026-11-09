#pragma once

#include "strata.hpp"

#include <hyprland/src/render/Renderer.hpp>

namespace Strata {
    struct STile {
        std::string kind;   // left, center, right, up, down
        CBox        box;    // monitor-local logical
        WORKSPACEID ws;     // the stratum it shows
        double      offset; // region start relative to the view, in screens
        double      width;  // region width, in screens
        int         row = -1; // its place in the stack (for one with no workspace yet)
    };

    std::vector<STile> crossTiles(PHLMONITOR mon);
    void               crossPoke(const std::string& kind);
    void               crossHide(PHLMONITOR mon);
    void               crossKey(uint32_t keycode, bool pressed);
    void               crossRenderPre(PHLMONITOR mon);
    void               crossRenderStage(eRenderStage stage);
    void               crossCleanup();
    void               drawWindowInto(PHLMONITOR mon, PHLWINDOW w, const CBox& region, const CBox& tile, float alpha, const Time::steady_tp& now);
    void               drawWindowAt(PHLMONITOR mon, PHLWINDOW w, const CBox& target, const CBox& clip, float alpha, const Time::steady_tp& now);
    // Render a private pass into the frame, keeping the frame's damage and
    // blur state (a nested render rewrites them).
    void               renderNested(Render::CRenderPass& pass, const CRegion& region);
}
