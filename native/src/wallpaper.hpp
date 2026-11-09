#pragma once

#include "strata.hpp"

#include <hyprland/src/render/Renderer.hpp>

namespace Strata {
    // paths: by workspace id; named: by workspace name ("@free" for any
    // numbered one); rows: in stack order, for strata with no workspace yet.
    void        wallpaperSet(std::unordered_map<WORKSPACEID, std::string> paths, std::unordered_map<std::string, std::string> named, std::vector<std::string> rows,
                             const std::string& base, const std::string& mode, bool parallax, float strength);
    // row: the stratum's place in the stack, when it may have no workspace (-1: unknown)
    std::string wallpaperPathFor(WORKSPACEID id, int row = -1);
    bool        wallpaperTexture(WORKSPACEID id, SP<Render::ITexture>& tex, Vector2D& size, int row = -1);
    void        drawCover(PHLMONITOR mon, SP<Render::ITexture> tex, const Vector2D& texSize, const CBox& box, const CBox& clip, float alpha);
    void        drawCoverFaded(PHLMONITOR mon, SP<Render::ITexture> tex, const Vector2D& texSize, const CBox& box, const CBox& clip, float alpha, double fadeTop, double fadeBottom);
    void        wallpaperRenderStage(eRenderStage stage);
    bool        wallpaperRenderPre(PHLMONITOR mon);
    void        wallpaperCleanup();
}
