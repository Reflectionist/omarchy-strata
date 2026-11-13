// A wallpaper of its own for each stratum, drawn by Hyprland under the
// stratum's windows (over Omarchy's background layer) so it moves exactly
// with Hyprland's own stratum slide: crossfading, sliding with a soft seam,
// or sliding slower than the windows (depth). Optionally it drifts as you pan
// along a stratum. The cross and the overview reuse the same textures.
//
// Images decode on a worker thread; textures are made on the main thread.

#include "strata.hpp"

#define private public
#define protected public
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/Pass.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#undef protected
#undef private

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprgraphics/image/Image.hpp>

#include "cross.hpp"
#include "wallpaper.hpp"

namespace Strata {

    struct STex {
        SP<Render::ITexture> tex;
        Vector2D             size;
        bool                 failed = false;
    };

    static std::unordered_map<std::string, STex>  g_tex;
    static std::unordered_set<std::string>        g_loading;
    static std::unordered_map<WORKSPACEID, std::string> g_paths;
    static std::unordered_map<std::string, std::string> g_named;
    static std::vector<std::string>                     g_rows;
    static std::string                            g_base;
    static std::string                            g_mode = "crossfade";
    static bool                                   g_parallax = false;
    static float                                  g_strength = 0.08F;
    static std::unordered_map<MONITORID, double>  g_shownCamera; // eased camera for parallax

    // Decoded images waiting for the main thread.
    static std::mutex                                                          g_doneLock;
    static std::vector<std::pair<std::string, std::shared_ptr<Hyprgraphics::CImage>>> g_done;
    static wl_event_source*                                                    g_pollTimer = nullptr;
    static std::atomic<int>                                                    g_inFlight  = 0;

    // One decoder thread, one picture at a time. hyprgraphics' JPEG decoder
    // keeps its error state (a jmp_buf) in one process-wide place: two
    // decodes at once, and a bad file in one could jump into the other's
    // stack and take the compositor down.
    static std::mutex              g_queueLock;
    static std::condition_variable g_queueCv;
    static std::deque<std::string> g_queue;
    static std::thread             g_worker;
    static bool                    g_stop = false;

    static void decodeLoop() {
        for (;;) {
            std::string path;
            {
                std::unique_lock lk(g_queueLock);
                g_queueCv.wait(lk, [] { return g_stop || !g_queue.empty(); });
                if (g_stop)
                    return;
                path = std::move(g_queue.front());
                g_queue.pop_front();
            }
            auto img = std::make_shared<Hyprgraphics::CImage>(path);
            {
                std::lock_guard lk(g_doneLock);
                g_done.emplace_back(path, img);
            }
            g_inFlight--;
        }
    }

    static int onPoll(void*);

    static void armPoll() {
        if (!g_pollTimer && g_pCompositor && g_pCompositor->m_wlEventLoop)
            g_pollTimer = wl_event_loop_add_timer(g_pCompositor->m_wlEventLoop, onPoll, nullptr);
        if (g_pollTimer)
            wl_event_source_timer_update(g_pollTimer, 40);
    }

    static int onPoll(void*) {
        std::vector<std::pair<std::string, std::shared_ptr<Hyprgraphics::CImage>>> done;
        {
            std::lock_guard lk(g_doneLock);
            done.swap(g_done);
        }
        for (auto& [path, img] : done) {
            g_loading.erase(path);
            auto& t = g_tex[path];
            if (!img || !img->success() || !img->cairoSurface()) {
                t.failed = true;
                Log::logger->log(Log::ERR, "[strata] couldn't load wallpaper {}", path);
                continue;
            }
            t.tex  = g_pHyprRenderer->createTexture(img->cairoSurface()->cairo());
            t.size = t.tex ? t.tex->m_size : Vector2D{};
        }
        if (!done.empty()) {
            for (auto& m : State::monitorState()->monitors())
                g_pHyprRenderer->damageMonitor(m);
        }
        if (g_inFlight > 0)
            wl_event_source_timer_update(g_pollTimer, 40);
        return 0;
    }

    static const STex* texture(const std::string& path) {
        if (path.empty())
            return nullptr;
        if (const auto IT = g_tex.find(path); IT != g_tex.end())
            return IT->second.tex ? &IT->second : nullptr;
        if (g_loading.contains(path))
            return nullptr;
        g_loading.insert(path);
        g_inFlight++;
        {
            std::lock_guard lk(g_queueLock);
            g_queue.push_back(path);
        }
        if (!g_worker.joinable())
            g_worker = std::thread(decodeLoop);
        g_queueCv.notify_one();
        armPoll();
        return nullptr;
    }

    // By workspace id; else by name, for a stratum's workspace made since Lua
    // last sent them (the first frames of switching to an empty stratum); else
    // by its place in the stack, for one with no workspace at all (overview
    // rows, cross tiles). Only then the base.
    std::string wallpaperPathFor(WORKSPACEID id, int row) {
        if (const auto IT = g_paths.find(id); IT != g_paths.end() && !IT->second.empty())
            return IT->second;
        if (const auto WS = workspaceByID(id)) {
            if (const auto IT = g_named.find(WS->m_name); IT != g_named.end() && !IT->second.empty())
                return IT->second;
            if (const auto IT = g_named.find("@free"); id > 0 && !WS->m_isSpecialWorkspace && IT != g_named.end() && !IT->second.empty())
                return IT->second;
        }
        if (row >= 0 && row < (int)g_rows.size() && !g_rows[row].empty())
            return g_rows[row];
        return g_base;
    }

    void wallpaperSet(std::unordered_map<WORKSPACEID, std::string> paths, std::unordered_map<std::string, std::string> named, std::vector<std::string> rows,
                      const std::string& base, const std::string& mode, bool parallax, float strength) {
        g_paths    = std::move(paths);
        g_named    = std::move(named);
        g_rows     = std::move(rows);
        g_base     = base;
        g_mode     = mode.empty() ? "crossfade" : mode;
        g_parallax = parallax;
        g_strength = std::clamp(strength, 0.F, 0.5F);
        // Start loading what's needed, and drop textures nothing uses.
        std::unordered_set<std::string> wanted{g_base};
        for (const auto& [_, p] : g_paths)
            wanted.insert(p);
        for (const auto& [_, p] : g_named)
            wanted.insert(p);
        for (const auto& p : g_rows)
            wanted.insert(p);
        wanted.erase("");
        std::erase_if(g_tex, [&wanted](const auto& e) { return !wanted.contains(e.first); });
        for (const auto& p : wanted)
            texture(p);
        for (auto& m : State::monitorState()->monitors())
            g_pHyprRenderer->damageMonitor(m);
    }

    // ── Drawing ──────────────────────────────────────────────────────────

    // Draw a texture to cover `box` (monitor-local logical), clipped to `clip`.
    void drawCover(PHLMONITOR mon, SP<Render::ITexture> tex, const Vector2D& texSize, const CBox& box, const CBox& clip, float alpha) {
        if (!tex || alpha <= 0.F || box.w <= 0 || box.h <= 0 || texSize.x <= 0 || texSize.y <= 0)
            return;
        const double S = std::max(box.w / texSize.x, box.h / texSize.y);
        const CBox   COVER{box.x + (box.w - texSize.x * S) / 2.0, box.y + (box.h - texSize.y * S) / 2.0, texSize.x * S, texSize.y * S};

        CTexPassElement::SRenderData d;
        d.tex     = tex;
        d.box     = COVER.copy().scale(mon->m_scale).round();
        d.clipBox = clip.copy().scale(mon->m_scale).round();
        d.a       = alpha;
        Render::CRenderPass p;
        p.add(makeUnique<CTexPassElement>(d));
        renderNested(p, CRegion{d.clipBox});
    }

    // `box` with its top/bottom edges fading out over `fade` px (soft seams):
    // the inner part at full alpha, then strips with falling alpha.
    void drawCoverFaded(PHLMONITOR mon, SP<Render::ITexture> tex, const Vector2D& texSize, const CBox& box, const CBox& clip, float alpha, double fadeTop, double fadeBottom) {
        const CBox INNER{box.x, box.y + fadeTop, box.w, std::max(0.0, box.h - fadeTop - fadeBottom)};
        drawCover(mon, tex, texSize, box, INNER.intersection(clip), alpha);
        constexpr int N = 14;
        for (int i = 0; i < N; ++i) {
            const double T  = (i + 0.5) / N;
            const float  A  = alpha * (float)(T * T * (3.0 - 2.0 * T)); // smoothstep up toward the inside
            if (fadeTop > 0) {
                const CBox STRIP{box.x, box.y + fadeTop * i / N, box.w, fadeTop / N + 0.5};
                drawCover(mon, tex, texSize, box, STRIP.intersection(clip), A);
            }
            if (fadeBottom > 0) {
                const CBox STRIP{box.x, box.y + box.h - fadeBottom * (i + 1) / N, box.w, fadeBottom / N + 0.5};
                drawCover(mon, tex, texSize, box, STRIP.intersection(clip), A);
            }
        }
    }

    const STex* wallpaperFor(WORKSPACEID id, int row = -1) {
        return texture(wallpaperPathFor(id, row));
    }

    bool wallpaperTexture(WORKSPACEID id, SP<Render::ITexture>& tex, Vector2D& size, int row) {
        const auto* T = wallpaperFor(id, row);
        if (!T)
            return false;
        tex  = T->tex;
        size = T->size;
        return true;
    }

    class CWallpaperPass : public IPassElement {
      public:
        CWallpaperPass(PHLMONITOR mon) : m_mon(mon) {}
        virtual ~CWallpaperPass() = default;
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
            return "CStrataWallpaperPass";
        }
        virtual ePassElementType type() {
            return EK_CUSTOM;
        }

      private:
        PHLMONITORREF m_mon;
    };

    std::vector<UP<IPassElement>> CWallpaperPass::draw() {
        const auto MON = m_mon.lock();
        if (!MON)
            return {};
        const CBox SCREEN{{}, MON->m_size};
        const auto ACTIVE = MON->m_activeWorkspace;

        // Horizontal drift: the wallpaper is shown a little larger and slides
        // a fraction of the camera's movement.
        // The wallpaper drifts `strength` of a screen for each screen you
        // pan, up to 2 x strength either way (shown that much larger).
        double drift = 0.0, grow = 0.0;
        if (g_parallax && g_strength > 0.F) {
            const double W = MON->m_size.x, E = 2.0 * g_strength * W;
            grow  = 2.0 * g_strength;
            drift = -E * (1.0 + std::tanh(g_shownCamera[MON->m_id] * g_strength * W / E));
        }
        const auto boxAt = [&](double dy) { return CBox{drift, dy, MON->m_size.x * (1.0 + grow * 2.0), MON->m_size.y}; };

        // The outgoing stratum first, the one arriving on top.
        std::vector<PHLWORKSPACE> list;
        for (const auto& ref : State::workspaceState()->workspaces()) {
            const auto WS = ref.lock();
            if (!WS || WS->m_isSpecialWorkspace || WS->m_monitor != MON || !strataFor(WS))
                continue;
            if (WS != ACTIVE && !WS->m_renderOffset->isBeingAnimated() && !WS->m_alpha->isBeingAnimated())
                continue;
            list.push_back(WS);
        }
        std::ranges::stable_sort(list, [&ACTIVE](const PHLWORKSPACE& a, const PHLWORKSPACE& b) { return a != ACTIVE && b == ACTIVE; });

        for (const auto& WS : list) {
            const auto* T = wallpaperFor(WS->m_id);
            if (!T)
                continue;
            const Vector2D OFF  = WS->m_renderOffset->value();
            const double   H    = std::max(1.0, MON->m_size.y);
            const float    NEAR = (float)std::clamp(1.0 - std::abs(OFF.y) / H, 0.0, 1.0);

            if (g_mode == "slide" || g_mode == "parallax") {
                const double DY   = g_mode == "parallax" ? OFF.y * 0.5 : OFF.y;
                const bool   MOVE = std::abs(OFF.y) > 0.5;
                // A soft seam where it meets its neighbour.
                const double FADE = MOVE ? H * 0.12 : 0.0;
                drawCoverFaded(MON, T->tex, T->size, boxAt(DY), SCREEN, 1.F, DY > 0 ? FADE : 0.0, DY < 0 ? FADE : 0.0);
            } else
                drawCover(MON, T->tex, T->size, boxAt(0.0), SCREEN, WS == ACTIVE && list.size() > 1 ? NEAR : 1.F);
        }
        return {};
    }

    void wallpaperRenderStage(eRenderStage stage) {
        if (stage != RENDER_POST_WALLPAPER)
            return;
        const auto MON = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!MON || (g_paths.empty() && g_named.empty() && g_base.empty()))
            return;
        g_pHyprRenderer->currentPass().add(makeUnique<CWallpaperPass>(MON));
    }

    // Ease the camera the parallax follows; keep frames coming until it settles.
    bool wallpaperRenderPre(PHLMONITOR mon) {
        if (!g_parallax || !mon)
            return false;
        auto* a = strataFor(mon->m_activeWorkspace);
        if (!a)
            return false;
        const double TARGET = a->view().camera;
        // First frame: start where the camera is, not slide over from 0.
        auto& shown = g_shownCamera.try_emplace(mon->m_id, TARGET).first->second;
        if (std::abs(shown - TARGET) < 1e-3) {
            shown = TARGET;
            return false;
        }
        shown += (TARGET - shown) * 0.18;
        g_pHyprRenderer->damageMonitor(mon);
        return true;
    }

    void wallpaperCleanup() {
        // The decoder runs code that's being unloaded: stop it, letting a
        // picture it's on finish (well under a second), and wait for it.
        {
            std::lock_guard lk(g_queueLock);
            g_stop = true;
            g_queue.clear();
        }
        g_queueCv.notify_all();
        if (g_worker.joinable())
            g_worker.join();
        {
            std::lock_guard lk(g_doneLock);
            g_done.clear();
        }
        g_inFlight = 0;
        if (g_pollTimer) {
            wl_event_source_remove(g_pollTimer);
            g_pollTimer = nullptr;
        }
        g_tex.clear();
        g_paths.clear();
        g_named.clear();
        g_rows.clear();
        g_base.clear();
    }
}
