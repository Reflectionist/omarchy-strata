#pragma once

#include "strata.hpp"

#include <hyprland/src/render/Renderer.hpp>

namespace Strata {
    // Picture in picture (pip.cpp). The shell says which windows on the
    // stratum you're on play video; leaving that stratum (or opening the
    // overview) shrinks the picture into a card that stays on screen.
    void        pipWatch(PHLWINDOW w, bool playing);
    void        pipConfig(const std::string& corner, double width, const CHyprColor& accent);
    void        pipSwitch(PHLMONITOR mon, PHLWORKSPACE from, PHLWORKSPACE to);
    void        pipOverview(PHLMONITOR mon, bool opening);
    bool        pipCard(double x, double y, double w, double h);
    bool        pipScale(double factor);
    bool        pipDrag(int edges);
    void        pipDragEnd();
    bool        pipHome();
    std::string pipWorkspace();
    std::string pipState();
    void        pipCrop(PHLWINDOW w, double x0, double y0, double x1, double y1);
    void        pipAnnounce();
    void        pipWindowClosed(PHLWINDOW w);
    void        pipRenderPre(PHLMONITOR mon);
    void        pipRenderStage(eRenderStage stage);
    void        pipCleanup();
}
