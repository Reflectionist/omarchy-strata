// Picture in picture, drawn here.
//
// While a window on the stratum you're on plays video, the shell names it
// (pip_watch) and its surface commits are watched. A browser damages exactly
// its <video> element's rectangle with every frame it shows, so the most
// frequent damage rectangle over the last few seconds is the picture: no
// guessing from pixels, and nothing inside the video (a facecam box) can
// fool it. A player that redraws all of its window gives the whole window.
//
// Leaving that stratum (every switch passes CMonitor::changeWorkspace, see
// anim.cpp) or opening the overview shrinks the picture from where it is on
// screen into the card, over the time the stratum slide takes. The window
// keeps its tile; while it's out of sight it's still sent frame callbacks,
// and every commit of it repaints the card. Coming back to its stratum grows
// the card back onto it. The shell draws the controls over the card and asks
// for moves and resizes; while you drag, this side follows the pointer.

#include "strata.hpp"

#include <format>

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/config/shared/animation/AnimationTree.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/pass/Pass.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include "cross.hpp"
#include "overview.hpp"
#include "pip.hpp"

namespace Strata {

    // ── The card's state ──

    enum ePhase : uint8_t {
        PIP_IDLE,
        PIP_SHRINK, // from the window into the card
        PIP_OUT,
        PIP_GROW, // from the card back onto the window
        PIP_FADE, // sent home without going there
    };

    struct SPip {
        WP<Desktop::View::CWindow> window;
        MONITORID                  mon   = MONITOR_INVALID;
        ePhase                     phase = PIP_IDLE;
        bool                       fromOverview = false;
        CBox                       from, to;         // monitor-local logical, the animation's ends
        Time::steady_tp            t0;
        double                     secs = 0.3;
        CBox                       card;             // where it rests, monitor-local logical
        CBox                       shown;            // where it was drawn last frame
        int                        edges = -1;       // dragging: -1 no, 0 move, else edge bits (1 L, 2 R, 4 T, 8 B)
        Vector2D                   grab;             // pointer at drag start, monitor-local
        CBox                       startCard;
        CHyprSignalListener        onCommit;
    };
    static SPip g_pip;

    static void damageCard();

    // ── Where the picture is, per watched window ─────────────────────────

    struct STrack {
        WP<Desktop::View::CWindow>                     window;
        bool                                           playing = false;
        CHyprSignalListener                            onCommit;
        std::deque<std::pair<Time::steady_tp, CBox>> hits; // damage extents, surface-local logical
        std::optional<CBox>                            rect; // the picture, once it's clear
        std::optional<CBox>                            bars; // the shell's crop (fractions) for a window that redraws all of itself
    };
    static std::vector<UP<STrack>> g_tracks;

    static SP<CWLSurfaceResource> surfaceOf(const PHLWINDOW& w) {
        return w && w->wlSurface() ? w->wlSurface()->resource() : nullptr;
    }

    static STrack* trackOf(const PHLWINDOW& w) {
        for (auto& t : g_tracks) {
            if (t->window.lock() == w)
                return t.get();
        }
        return nullptr;
    }

    // One commit: its damage, as a box in the surface's own logical space.
    static void onCommit(STrack* t) {
        const auto W = t->window.lock();
        const auto S = surfaceOf(W);
        if (!S)
            return;
        const auto SZ = S->m_current.size;
        if (SZ.x < 1 || SZ.y < 1)
            return;
        CBox e;
        if (!S->m_current.damage.empty())
            e = S->m_current.damage.getExtents();
        else if (!S->m_current.bufferDamage.empty() && S->m_current.bufferSize.x > 0 && S->m_current.bufferSize.y > 0) {
            e = S->m_current.bufferDamage.getExtents();
            e = CBox{e.x * SZ.x / S->m_current.bufferSize.x, e.y * SZ.y / S->m_current.bufferSize.y, e.w * SZ.x / S->m_current.bufferSize.x,
                     e.h * SZ.y / S->m_current.bufferSize.y};
        } else
            return;
        e = e.intersection(CBox{{0, 0}, SZ});
        // A cursor blink or a progress tick says nothing about the picture.
        if (e.w * e.h < SZ.x * SZ.y * 0.02)
            return;

        const auto NOW = Time::steadyNow();
        t->hits.emplace_back(NOW, e);
        while (!t->hits.empty() && NOW - t->hits.front().first > std::chrono::seconds(3))
            t->hits.pop_front();

        // The picture is the box inside the most commits. A video redraws
        // with every frame it shows, so its box is in nearly every commit:
        // alone, or inside a bigger one when something else changed in the
        // same frame (a glow around the player, a chat, a full repaint). The
        // most frequent box alone can be one of those bigger ones, and when
        // two are close it flips with every commit.
        std::map<std::tuple<int, int, int, int>, std::pair<int, CBox>> counts;
        for (const auto& [_, b] : t->hits) {
            auto& c = counts[{(int)std::round(b.x / 4), (int)std::round(b.y / 4), (int)std::round(b.w / 4), (int)std::round(b.h / 4)}];
            c.first++;
            c.second = b;
        }
        const auto inside = [](const CBox& in, const CBox& out) {
            constexpr double T = 4.0;
            return in.x >= out.x - T && in.y >= out.y - T && in.x + in.w <= out.x + out.w + T && in.y + in.h <= out.y + out.h + T;
        };
        const auto score = [&](const CBox& c) {
            int n = 0;
            for (const auto& [_, b] : t->hits)
                n += inside(c, b) ? 1 : 0;
            return n;
        };
        // Only a box shaped like a video can be the picture: a player's
        // controls along its bottom (YouTube's, redrawn at the screen's rate
        // while the video changes at its own) sit inside every commit too,
        // and would win on that alone.
        const auto videoShaped = [](const CBox& b) {
            const double A = b.w / std::max(1.0, b.h);
            return A >= 0.4 && A <= 2.8;
        };
        const int N = (int)t->hits.size();
        std::vector<std::pair<int, CBox>> cands;
        int                               top = 0;
        for (const auto& [_, c] : counts) {
            if (c.first < 3 || !videoShaped(c.second))
                continue;
            cands.emplace_back(score(c.second), c.second);
            top = std::max(top, cands.back().first);
        }
        // Of the boxes in nearly as many commits as the best, the biggest
        // (the whole picture, not a part of it that changes with it).
        int  best = 0;
        CBox bestBox;
        for (const auto& [sc, b] : cands) {
            if (sc * 100 < top * 85)
                continue;
            if (best == 0 || b.w * b.h > bestBox.w * bestBox.h) {
                best    = sc;
                bestBox = b;
            }
        }
        // In a good share of the commits: a video at half the screen's rate
        // is in about half of them (the rest redraw only the controls).
        if (N < 8 || best * 100 < N * 35)
            return;
        // Steady: a different box takes over only when it's clearly ahead,
        // or the one in use has dropped out of most commits (or isn't shaped
        // like a video at all).
        if (t->rect && videoShaped(*t->rect) &&
            !(std::abs(t->rect->x - bestBox.x) < 4 && std::abs(t->rect->y - bestBox.y) < 4 && std::abs(t->rect->w - bestBox.w) < 4 && std::abs(t->rect->h - bestBox.h) < 4)) {
            const int CUR = score(*t->rect);
            if (CUR * 100 >= N * 35 && best * 10 < CUR * 12)
                return;
        }
        t->rect = bestBox;
    }

    void pipWatch(PHLWINDOW w, bool playing) {
        if (!w)
            return;
        auto* t = trackOf(w);
        if (!playing) {
            // The window that's out keeps its watch.
            if (t && g_pip.window.lock() != w)
                std::erase_if(g_tracks, [t](const auto& o) { return o.get() == t; });
            else if (t)
                t->playing = false;
            return;
        }
        if (!t) {
            const auto S = surfaceOf(w);
            if (!S)
                return;
            auto n    = makeUnique<STrack>();
            n->window = w;
            t         = n.get();
            n->onCommit = S->m_events.commit.listen([t] { onCommit(t); });
            g_tracks.emplace_back(std::move(n));
        }
        t->playing = true;
    }

    // ── The card ─────────────────────────────────────────────────────────


    static struct {
        std::string corner = "bottom-right";
        double      width  = 0.25;
        CHyprColor  accent = CHyprColor{0.55F, 0.7F, 1.F, 1.F};
    } g_style;

    void pipConfig(const std::string& corner, double width, const CHyprColor& accent) {
        g_style.corner = corner;
        g_style.width  = std::clamp(width, 0.08, 0.8);
        g_style.accent = accent;
    }

    static constexpr double GAP = 16.0, MINW = 200.0;

    static PHLMONITOR pipMonitor() {
        if (g_pip.mon == MONITOR_INVALID)
            return nullptr;
        for (const auto& m : State::monitorState()->monitors()) {
            if (m && m->m_id == g_pip.mon)
                return m;
        }
        return nullptr;
    }

    // The usable area (without what bars reserve), monitor-local logical.
    static CBox usable(const PHLMONITOR& mon) {
        auto b = mon->logicalBoxMinusReserved();
        b.x -= mon->m_position.x;
        b.y -= mon->m_position.y;
        return b;
    }

    // The picture's box in the window's surface, logical. A player that
    // redraws all of its window (black bars included) gives no box of its
    // own: the shell measures its bars (pip_crop).
    static CBox sourceBox(const PHLWINDOW& w) {
        const auto S    = surfaceOf(w);
        const auto SZ   = S ? S->m_current.size : Vector2D{1, 1};
        auto*      t    = trackOf(w);
        const CBox ALL{{0, 0}, SZ};
        const CBox R    = t && t->rect ? *t->rect : ALL;
        const bool FULL = R.w * R.h >= SZ.x * SZ.y * 0.95;
        if (FULL && t && t->bars && t->bars->w * t->bars->h >= 0.1)
            return CBox{t->bars->x * SZ.x, t->bars->y * SZ.y, t->bars->w * SZ.x, t->bars->h * SZ.y};
        return R;
    }

    void pipCrop(PHLWINDOW w, double x0, double y0, double x1, double y1) {
        auto* t = trackOf(w);
        if (!t || x1 <= x0 || y1 <= y0)
            return;
        t->bars = CBox{std::clamp(x0, 0.0, 1.0), std::clamp(y0, 0.0, 1.0), std::clamp(x1 - x0, 0.0, 1.0), std::clamp(y1 - y0, 0.0, 1.0)};
        if (g_pip.window.lock() == w)
            damageCard();
    }

    static double aspectOf(const PHLWINDOW& w) {
        const auto B = sourceBox(w);
        return B.h > 1 ? std::clamp(B.w / B.h, 0.3, 4.0) : 16.0 / 9.0;
    }

    // Where the picture is on screen now (monitor-local logical), on a
    // window at `pos` (global logical, its workspace's offset included).
    static CBox pictureAt(const PHLMONITOR& mon, const PHLWINDOW& w, const Vector2D& pos) {
        const auto S    = surfaceOf(w);
        const auto SZ   = S ? S->m_current.size : Vector2D{1, 1};
        const auto SIZE = w->sizeAnimation()->value();
        const double KX = SIZE.x / std::max(1.0, SZ.x), KY = SIZE.y / std::max(1.0, SZ.y);
        const auto B    = sourceBox(w);
        return CBox{pos.x + B.x * KX - mon->m_position.x, pos.y + B.y * KY - mon->m_position.y, B.w * KX, B.h * KY};
    }

    // Keep a card inside the usable area; snap flush (at the gap) to edges it
    // comes near.
    static CBox fit(const PHLMONITOR& mon, CBox c, bool snap) {
        const auto U = usable(mon);
        const double L = U.x + GAP, T = U.y + GAP, R = U.x + U.w - GAP, B = U.y + U.h - GAP;
        if (snap) {
            constexpr double S = 28.0;
            if (c.x < L + S)
                c.x = L;
            else if (c.x + c.w > R - S)
                c.x = R - c.w;
            if (c.y < T + S)
                c.y = T;
            else if (c.y + c.h > B - S)
                c.y = B - c.h;
        }
        c.x = std::clamp(c.x, U.x, std::max(U.x, U.x + U.w - c.w));
        c.y = std::clamp(c.y, U.y, std::max(U.y, U.y + U.h - c.h));
        return c;
    }

    // A card of width w with the picture's shape; (ax, ay) is the point of
    // the old card that stays put (0 left/top, 1 right/bottom, 0.5 middle).
    static CBox sized(const PHLMONITOR& mon, const CBox& old, double w, double aspect, double ax, double ay) {
        const auto U = usable(mon);
        w            = std::clamp(w, MINW, U.w * 0.8);
        double h     = w / aspect;
        if (h > U.h * 0.8) {
            h = U.h * 0.8;
            w = h * aspect;
        }
        return fit(mon, CBox{old.x + (old.w - w) * ax, old.y + (old.h - h) * ay, w, h}, false);
    }

    // A new card: the corner and width from the settings.
    static CBox restingCard(const PHLMONITOR& mon, double aspect) {
        const auto U = usable(mon);
        const double W = std::clamp(mon->m_size.x * g_style.width, MINW, U.w * 0.8), H = W / aspect;
        const bool LEFT = g_style.corner.find("left") != std::string::npos, TOP = g_style.corner.find("top") != std::string::npos;
        return CBox{LEFT ? U.x + GAP : U.x + U.w - GAP - W, TOP ? U.y + GAP : U.y + U.h - GAP - H, W, H};
    }

    // The slide's own length, so the card moves with it.
    static double slideSecs() {
        const auto C = Config::animationTree()->getAnimationPropertyConfig("workspaces");
        const auto V = C ? C->pValues.lock() : nullptr;
        if (!V || !V->internalEnabled)
            return 0.0;
        return std::clamp(V->internalSpeed / 10.0, 0.12, 1.0);
    }

    static float ease(float x) {
        x = std::clamp(x, 0.F, 1.F);
        return x < 0.5F ? 4.F * x * x * x : 1.F - std::pow(-2.F * x + 2.F, 3.F) / 2.F;
    }

    static CBox lerp(const CBox& a, const CBox& b, float k) {
        return CBox{a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k, a.w + (b.w - a.w) * k, a.h + (b.h - a.h) * k};
    }

    static void damageAll() {
        if (const auto MON = pipMonitor()) {
            g_pHyprRenderer->damageMonitor(MON);
            MON->scheduleFrame(Aquamarine::IOutput::AQ_SCHEDULE_ANIMATION);
        }
    }

    static void damageCard() {
        const auto MON = pipMonitor();
        if (!MON)
            return;
        // Last frame's box and the resting one, border included.
        for (const auto& b : {g_pip.shown, g_pip.card}) {
            if (b.w > 0)
                g_pHyprRenderer->damageBox(CBox{b.x + MON->m_position.x - 4, b.y + MON->m_position.y - 4, b.w + 8, b.h + 8});
        }
    }

    static void post(bool open) {
        const auto W = g_pip.window.lock();
        if (!open || !W) {
            postEvent("strata-pip", "{\"open\":false}");
            return;
        }
        const auto& c   = g_pip.card;
        const auto  MON = pipMonitor();
        postEvent("strata-pip",
                  std::format("{{\"open\":true,\"a\":\"{}\",\"class\":\"{}\",\"ws\":\"{}\",\"mon\":\"{}\",\"x\":{:.1f},\"y\":{:.1f},\"w\":{:.1f},\"h\":{:.1f},\"aspect\":{:.4f},\"settled\":{}}}",
                              addressOf(W), W->m_class, W->m_workspace ? W->m_workspace->m_name : "", MON ? MON->m_name : "", c.x, c.y, c.w, c.h, aspectOf(W),
                              g_pip.phase == PIP_OUT && g_pip.edges < 0 ? "true" : "false"));
    }

    static void begin(PHLMONITOR mon, PHLWINDOW w, bool fromOverview) {
        if (!mon || !w || g_pip.phase != PIP_IDLE || (w->m_workspace && isPrivate(w->m_workspace)))
            return;
        const auto S = surfaceOf(w);
        if (!S)
            return;
        g_pip              = SPip{};
        g_pip.window       = w;
        g_pip.mon          = mon->m_id;
        g_pip.fromOverview = fromOverview;
        g_pip.from         = pictureAt(mon, w, w->positionAnimation()->value() + w->m_floatingOffset);
        g_pip.card         = restingCard(mon, aspectOf(w));
        g_pip.to           = g_pip.card;
        g_pip.secs         = std::max(0.2, slideSecs());
        g_pip.t0           = Time::steadyNow();
        g_pip.phase        = PIP_SHRINK;
        // Each frame it shows repaints the card.
        g_pip.onCommit = S->m_events.commit.listen([] {
            if (g_pip.phase == PIP_OUT)
                damageCard();
        });
        post(true);
        damageAll();
    }

    // Back onto the window: where its picture will be once its stratum has
    // slid in.
    static void returnHome() {
        const auto MON = pipMonitor();
        const auto W   = g_pip.window.lock();
        if (!MON || !W || g_pip.phase == PIP_IDLE || g_pip.phase == PIP_GROW)
            return;
        g_pip.edges = -1;
        g_pip.from  = g_pip.shown.w > 0 ? g_pip.shown : g_pip.card;
        g_pip.to    = pictureAt(MON, W, W->positionAnimation()->goal() + W->m_floatingOffset);
        g_pip.secs  = std::max(0.2, slideSecs());
        g_pip.t0    = Time::steadyNow();
        g_pip.phase = PIP_GROW;
        post(false);
        damageAll();
    }

    static void end() {
        damageCard();
        const bool WAS = g_pip.phase != PIP_IDLE;
        g_pip          = SPip{};
        if (WAS)
            post(false);
    }

    // The playing window on ws to take along: one whose picture is known
    // (several windows of one browser share its player), most active first.
    static PHLWINDOW candidateOn(const PHLWORKSPACE& ws) {
        PHLWINDOW best;
        size_t    bestHits = 0;
        bool      bestKnown = false;
        for (const auto& t : g_tracks) {
            const auto TW = t->window.lock();
            if (!t->playing || !TW || !TW->m_isMapped || TW->isHidden() || TW->m_workspace != ws)
                continue;
            const bool KNOWN = t->rect.has_value();
            if (!best || (KNOWN && !bestKnown) || (KNOWN == bestKnown && t->hits.size() > bestHits)) {
                best      = TW;
                bestHits  = t->hits.size();
                bestKnown = KNOWN;
            }
        }
        return best;
    }

    void pipSwitch(PHLMONITOR mon, PHLWORKSPACE from, PHLWORKSPACE to) {
        if (!mon || !to || to->m_isSpecialWorkspace)
            return;
        const auto W = g_pip.window.lock();
        if (g_pip.phase != PIP_IDLE && W && W->m_workspace == to) {
            returnHome();
            return;
        }
        if (g_pip.phase != PIP_IDLE || !from || from == to || overviewOpen(mon->m_id))
            return;
        if (const auto TW = candidateOn(from))
            begin(mon, TW, false);
    }

    void pipOverview(PHLMONITOR mon, bool opening) {
        if (!mon)
            return;
        if (opening) {
            if (g_pip.phase != PIP_IDLE)
                return;
            if (const auto TW = candidateOn(mon->m_activeWorkspace))
                begin(mon, TW, true);
            return;
        }
        // Closed onto the picture's own stratum.
        const auto W = g_pip.window.lock();
        if (g_pip.phase != PIP_IDLE && W && W->m_workspace == mon->m_activeWorkspace)
            returnHome();
    }

    bool pipCard(double x, double y, double w, double h) {
        const auto MON = pipMonitor();
        const auto W   = g_pip.window.lock();
        if (!MON || !W || g_pip.phase != PIP_OUT)
            return false;
        damageCard();
        g_pip.card = sized(MON, CBox{x, y, w, h}, w, aspectOf(W), 0, 0);
        g_pip.card = fit(MON, CBox{x, y, g_pip.card.w, g_pip.card.h}, false);
        damageCard();
        post(true);
        return true;
    }

    bool pipScale(double factor) {
        const auto MON = pipMonitor();
        const auto W   = g_pip.window.lock();
        if (!MON || !W || g_pip.phase != PIP_OUT)
            return false;
        const auto   C  = g_pip.card;
        const auto   U  = usable(MON);
        const double AX = C.x + C.w / 2 < U.x + U.w / 2 ? 0 : 1, AY = C.y + C.h / 2 < U.y + U.h / 2 ? 0 : 1;
        damageCard();
        g_pip.card = sized(MON, C, C.w * factor, aspectOf(W), AX, AY);
        damageCard();
        post(true);
        return true;
    }

    // The shell says a drag started on the card (the edges held, 0 = move);
    // from here the card follows the pointer until pipDragEnd.
    bool pipDrag(int edges) {
        const auto MON = pipMonitor();
        if (!MON || g_pip.phase != PIP_OUT)
            return false;
        g_pip.edges     = std::clamp(edges, 0, 15);
        g_pip.grab      = g_pInputManager->getMouseCoordsInternal() - MON->m_position;
        g_pip.startCard = g_pip.card;
        post(true);
        return true;
    }

    static void dragTick() {
        const auto MON = pipMonitor();
        const auto W   = g_pip.window.lock();
        if (!MON || !W || g_pip.edges < 0)
            return;
        const auto P  = g_pInputManager->getMouseCoordsInternal() - MON->m_position;
        const auto D  = P - g_pip.grab;
        const auto S  = g_pip.startCard;
        const int  E  = g_pip.edges;
        CBox       c;
        if (E == 0)
            c = fit(MON, CBox{S.x + D.x, S.y + D.y, S.w, S.h}, true);
        else {
            const double A    = aspectOf(W);
            const double BYW  = (E & 1) ? -D.x : (E & 2) ? D.x : 0;
            const double BYH  = ((E & 4) ? -D.y : (E & 8) ? D.y : 0) * A;
            const double GROW = std::abs(BYW) >= std::abs(BYH) ? BYW : BYH;
            c = sized(MON, S, S.w + GROW, A, (E & 1) ? 1 : (E & 2) ? 0 : 0.5, (E & 4) ? 1 : (E & 8) ? 0 : 0.5);
        }
        if (c.pos() == g_pip.card.pos() && c.size() == g_pip.card.size())
            return;
        damageCard();
        g_pip.card = c;
        damageCard();
    }

    void pipDragEnd() {
        if (g_pip.edges < 0)
            return;
        dragTick();
        g_pip.edges = -1;
        post(true);
    }

    // X: home without going there (it keeps playing there).
    bool pipHome() {
        if (g_pip.phase == PIP_IDLE)
            return false;
        g_pip.edges = -1;
        g_pip.from  = g_pip.shown.w > 0 ? g_pip.shown : g_pip.card;
        g_pip.t0    = Time::steadyNow();
        g_pip.secs  = 0.18;
        g_pip.phase = PIP_FADE;
        post(false);
        damageAll();
        return true;
    }

    // The stratum button: Lua goes there (the switch brings it home).
    std::string pipWorkspace() {
        const auto W = g_pip.window.lock();
        return g_pip.phase != PIP_IDLE && W && W->m_workspace ? W->m_workspace->m_name : "";
    }

    // A shell that (re)starts asks what's out.
    void pipAnnounce() {
        post(g_pip.phase == PIP_OUT || g_pip.phase == PIP_SHRINK);
    }

    std::string pipState() {
        std::string tracks;
        for (const auto& t : g_tracks) {
            const auto W = t->window.lock();
            if (!W)
                continue;
            if (!tracks.empty())
                tracks += ",";
            tracks += std::format("{{\"a\":\"{}\",\"playing\":{},\"hits\":{},\"rect\":{},\"bars\":{}}}", addressOf(W), t->playing ? "true" : "false", t->hits.size(),
                                  t->rect ? std::format("[{:.0f},{:.0f},{:.0f},{:.0f}]", t->rect->x, t->rect->y, t->rect->w, t->rect->h) : "null",
                                  t->bars ? std::format("[{:.3f},{:.3f},{:.3f},{:.3f}]", t->bars->x, t->bars->y, t->bars->w, t->bars->h) : "null");
        }
        const auto  W = g_pip.window.lock();
        const auto& c = g_pip.card;
        return std::format("{{\"phase\":{},\"a\":\"{}\",\"card\":[{:.1f},{:.1f},{:.1f},{:.1f}],\"dragging\":{},\"tracks\":[{}]}}", (int)g_pip.phase, W ? addressOf(W) : "", c.x, c.y,
                           c.w, c.h, g_pip.edges, tracks);
    }

    void pipWindowClosed(PHLWINDOW w) {
        std::erase_if(g_tracks, [&w](const auto& t) { return t->window.expired() || t->window.lock() == w; });
        if (g_pip.window.lock() == w || (g_pip.phase != PIP_IDLE && g_pip.window.expired()))
            end();
    }

    // ── Drawing ──────────────────────────────────────────────────────────

    class CPipPass : public IPassElement {
      public:
        CPipPass(PHLMONITOR mon, const CBox& box, float alpha) : m_mon(mon), m_box(box), m_alpha(alpha) {}
        virtual ~CPipPass() = default;

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
            return "CStrataPipPass";
        }
        virtual ePassElementType type() {
            return EK_CUSTOM;
        }

      private:
        PHLMONITORREF m_mon;
        CBox          m_box; // monitor-local logical
        float         m_alpha;
    };

    std::vector<UP<IPassElement>> CPipPass::draw() {
        const auto MON = m_mon.lock();
        const auto W   = g_pip.window.lock();
        if (!MON || !W || !W->m_isMapped || m_alpha <= 0.F)
            return {};
        const auto NOW = Time::steadyNow();

        // The accent edge, under the picture.
        CRectPassElement::SRectData edge;
        edge.box   = CBox{m_box.x - 2, m_box.y - 2, m_box.w + 4, m_box.h + 4}.scale(MON->m_scale).round();
        auto color = g_style.accent;
        color.a *= 0.9F * m_alpha;
        edge.color = color;
        edge.round = sc<int>(std::round(8 * MON->m_scale));
        Render::CRenderPass edgePass;
        edgePass.add(makeUnique<CRectPassElement>(edge));
        renderNested(edgePass, CRegion{edge.box});

        // The picture: the window's buffer, cut to its box (texture
        // coordinates) and drawn into the card with rounded corners.
        const auto S  = surfaceOf(W);
        const auto SZ = S ? S->m_current.size : Vector2D{1, 1};
        const auto B  = sourceBox(W);
        if (S && S->m_current.texture && SZ.x >= 1 && SZ.y >= 1) {
            CTexPassElement::SRenderData d;
            d.tex           = S->m_current.texture;
            d.surface       = S;
            d.box           = m_box.copy().scale(MON->m_scale).round();
            d.a             = m_alpha;
            d.round         = sc<int>(std::round(8 * MON->m_scale));
            d.roundingPower = 2.F;
            d.allowCustomUV = true;
            auto&      rd   = g_pHyprRenderer->m_renderData;
            const auto TL   = rd.primarySurfaceUVTopLeft;
            const auto BR   = rd.primarySurfaceUVBottomRight;
            rd.primarySurfaceUVTopLeft     = Vector2D{B.x / SZ.x, B.y / SZ.y};
            rd.primarySurfaceUVBottomRight = Vector2D{(B.x + B.w) / SZ.x, (B.y + B.h) / SZ.y};
            Render::CRenderPass pass;
            pass.add(makeUnique<CTexPassElement>(d));
            renderNested(pass, CRegion{d.box});
            rd.primarySurfaceUVTopLeft     = TL;
            rd.primarySurfaceUVBottomRight = BR;
        } else {
            // No buffer to read: the window drawn into the card the slow way.
            const auto   SIZE = W->sizeAnimation()->value();
            const auto   POS  = W->positionAnimation()->value() + W->m_floatingOffset;
            const double KX = SIZE.x / std::max(1.0, SZ.x), KY = SIZE.y / std::max(1.0, SZ.y);
            drawWindowInto(MON, W, CBox{POS.x + B.x * KX, POS.y + B.y * KY, B.w * KX, B.h * KY}, m_box, m_alpha, NOW);
        }

        if (W->m_workspace && !W->m_workspace->isVisible())
            g_pHyprRenderer->sendFrameEventsToWorkspace(MON, W->m_workspace, NOW);
        return {};
    }

    // ── Frame plumbing ───────────────────────────────────────────────────

    static PHLMONITORREF g_frameMon;

    void pipRenderPre(PHLMONITOR mon) {
        g_frameMon = mon;
        if (!mon || mon->m_id != g_pip.mon || g_pip.phase == PIP_IDLE)
            return;
        if (g_pip.window.expired()) {
            end();
            return;
        }
        if (g_pip.edges >= 0)
            dragTick();
        if (g_pip.phase != PIP_OUT)
            g_pHyprRenderer->damageMonitor(mon);
    }

    void pipRenderStage(eRenderStage stage) {
        if (stage == RENDER_POST) {
            const auto MON = g_frameMon.lock();
            if (MON && MON->m_id == g_pip.mon && (g_pip.phase == PIP_SHRINK || g_pip.phase == PIP_GROW || g_pip.phase == PIP_FADE || g_pip.edges >= 0))
                MON->scheduleFrame(Aquamarine::IOutput::AQ_SCHEDULE_ANIMATION);
            return;
        }
        if (stage != RENDER_POST_WINDOWS)
            return;
        const auto MON = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!MON || MON->m_id != g_pip.mon || g_pip.phase == PIP_IDLE)
            return;

        // Where it is this frame.
        const float K   = g_pip.secs > 0 ? std::clamp((float)(std::chrono::duration<double>(Time::steadyNow() - g_pip.t0).count() / g_pip.secs), 0.F, 1.F) : 1.F;
        CBox        box = g_pip.card;
        float       alpha = 1.F;
        switch (g_pip.phase) {
            case PIP_SHRINK:
                box = lerp(g_pip.from, g_pip.card, ease(K));
                if (K >= 1.F) {
                    g_pip.phase = PIP_OUT;
                    post(true);
                }
                break;
            case PIP_GROW:
                box = lerp(g_pip.from, g_pip.to, ease(K));
                if (K >= 1.F) {
                    end();
                    return;
                }
                break;
            case PIP_FADE:
                box   = g_pip.from;
                alpha = 1.F - ease(K);
                if (K >= 1.F) {
                    end();
                    return;
                }
                break;
            default: break;
        }
        g_pip.shown = box;

        // A fullscreen window covers it (not while it's flying in or out).
        if (g_pip.phase == PIP_OUT && Fullscreen::controller()->hasFullscreen(MON->m_activeWorkspace, true))
            return;
        g_pHyprRenderer->currentPass().add(makeUnique<CPipPass>(MON, box, alpha));
    }

    void pipCleanup() {
        g_pip = SPip{};
        g_tracks.clear();
    }
}
