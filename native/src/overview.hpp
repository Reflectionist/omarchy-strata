#pragma once

#include "strata.hpp"

#include <hyprland/src/render/Renderer.hpp>

namespace Strata {
    bool overviewOpen(MONITORID id);
    void overviewOpenRows(const std::vector<WORKSPACEID>& rows, int current, bool search = false);
    void overviewClose(int row);
    void overviewRows(const std::vector<WORKSPACEID>& rows);
    void overviewRefresh();

    // Dragging a window in the overview (the shell says start / drop /
    // cancel; the rest happens here). A drop on another stratum returns that
    // row and the window's address: Lua moves it, then calls Finish.
    bool overviewDragBegin(PHLWINDOW w, int edge, double fx, double fy);
    int  overviewDragEnd(std::string* address);
    void overviewDragFinish();
    void overviewDragCancel();
    bool overviewDropping(PHLWINDOW w); // dropped on another stratum, on its way there
    void overviewRenderPre(PHLMONITOR mon);
    void overviewRenderStage(eRenderStage stage);
    void overviewCleanup();
}
