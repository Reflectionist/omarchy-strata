import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Commons as Commons

// Picture in picture, the shell's half. When you leave a stratum with PiP on
// while one of its players is playing, a live copy of the player's window
// follows you in a small card. The window itself stays in its tile on its
// stratum: lua/strata.lua's pip_out only makes its video fill it there (a
// browser page goes fullscreen inside the tile), and pip_in undoes that.
//
// The copy is cropped to the picture: black bars are trimmed, and when page
// around the video still shows, it's cut to the part of the picture that
// moves. The card starts in the corner from the settings; drag it anywhere,
// resize it from any edge or with the wheel (it keeps the video's shape), and
// hover it for the controls. Its own player is found by the window's process.
Item {
  id: pip
  required property var service
  readonly property var state: service.stateObject
  readonly property var theme: Commons.ShellColor || Commons.Color
  readonly property var pc: state.config && state.config.pip ? state.config.pip : ({})
  readonly property string outPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/strata-pip-out-" + (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "") + ".json"

  function lua(call) { Quickshell.execDetached(["hyprctl", "eval", 'require("hypr.strata").' + call]) }

  // ── Leaving a stratum ─────────────────────────────────────────────────
  property var lastEntry: null
  property int lastWsId: 0

  Connections {
    target: pip.state
    function onCurrentIndexChanged() { pip.leaving() }
  }
  // Where you are when the shell starts, so the first move away counts; and
  // a PiP that was out when the shell restarted comes back.
  Component.onCompleted: { lastEntry = state.current; lastWsId = state.focusedId; resumeTimer.start() }
  // Quickshell finds the players only once something asks: ask now, not as
  // you leave (the list would still be empty then).
  readonly property int players: Mpris.players.values.length

  function classOf(t) {
    if (t.wayland && t.wayland.appId) return String(t.wayland.appId)
    return t.lastIpcObject && t.lastIpcObject.class ? String(t.lastIpcObject.class) : ""
  }
  function pidOf(t) { return t && t.lastIpcObject && t.lastIpcObject.pid ? Number(t.lastIpcObject.pid) : 0 }
  function addrOf(t) {
    var a = String(t.address)
    return a.indexOf("0x") === 0 ? a : "0x" + a
  }

  // The window's own player: the MPRIS service its process registered
  // (Chromium: ...chromium.instance<pid>, mpv-mpris: ...mpv.instance<pid>).
  // Failing that, a player whose name matches the app.
  function playerFor(t, cls, playingOnly) {
    var pid = pidOf(t)
    var list = Mpris.players.values
    if (pid > 0) {
      for (var i = 0; i < list.length; i++) {
        var bus = String(list[i].dbusName || "")
        if ((bus.endsWith(".instance" + pid) || bus.endsWith("." + pid)) && (!playingOnly || list[i].isPlaying)) return list[i]
      }
    }
    var c = cls.toLowerCase()
    var chrome = c === "helium" || c.indexOf("chrom") >= 0 || c.indexOf("chrome-") === 0 || c === "brave-browser"
    for (var j = 0; j < list.length; j++) {
      var p = list[j]
      if (playingOnly && !p.isPlaying) continue
      var id = String(p.identity || "").toLowerCase(), de = String(p.desktopEntry || "").toLowerCase(), b = String(p.dbusName || "").toLowerCase()
      if (de === c || id === c || (de !== "" && c.indexOf(de) >= 0) || (id !== "" && c.indexOf(id) >= 0)) return p
      if (chrome && (b.indexOf("chrom") >= 0 || id.indexOf("chrom") >= 0 || id.indexOf("helium") >= 0 || de.indexOf("helium") >= 0)) return p
    }
    return null
  }

  function toplevelAt(addr) {
    var a = String(addr).replace(/^0x/, "")
    var tops = Hyprland.toplevels.values
    for (var i = 0; i < tops.length; i++) if (String(tops[i].address).replace(/^0x/, "") === a) return tops[i]
    return null
  }

  function entryFor(selector) {
    var list = state.stack || []
    for (var i = 0; i < list.length; i++) if (list[i].selector === selector) return list[i]
    return null
  }

  function leaving() {
    // The free strata can renumber the stack without you moving.
    if (state.focusedId === lastWsId) { lastEntry = state.current; return }
    var prev = lastEntry, prevWs = lastWsId
    lastEntry = state.current
    lastWsId = state.focusedId
    if (!prev || prev.kind !== "themed" || (active !== "" && toplevelAt(active))) return
    var conf = prev.stratum && prev.stratum.pip ? prev.stratum.pip : null
    if (!conf || !conf.enabled || !(conf.apps || []).length) return
    var tops = Hyprland.toplevels.values
    for (var i = 0; i < tops.length; i++) {
      var t = tops[i]
      if (!t.workspace || t.workspace.id !== prevWs) continue
      var cls = classOf(t)
      var hit = false
      for (var j = 0; j < conf.apps.length; j++) {
        try { if (new RegExp(conf.apps[j]).test(cls)) hit = true } catch (e) {}
      }
      if (!hit) continue
      var player = playerFor(t, cls, true)
      if (!player) continue
      open(t, prev, player)
      lua("pip_out(" + JSON.stringify(addrOf(t)) + ", " + JSON.stringify(prev.selector) + ")")
      return
    }
  }

  // After a shell restart: the window Lua still has out (its file), unless
  // you're on its stratum.
  Timer {
    id: resumeTimer
    interval: 1500
    property int tries: 0
    onTriggered: {
      if (pip.active !== "") return
      var all = pip.state.parseJson(outFile.text()) || {}
      for (var addr in all) {
        var e = all[addr]
        if (!e || e.mode !== "mirror" || (pip.state.current && pip.state.current.selector === e.ws)) continue
        var t = pip.toplevelAt(addr)
        if (!t) { if (++tries < 4) restart(); return }
        pip.open(t, pip.entryFor(e.ws), pip.playerFor(t, pip.classOf(t), false))
        return
      }
    }
  }
  FileView { id: outFile; path: pip.outPath; blockLoading: true; printErrors: false }

  // ── While it's out ────────────────────────────────────────────────────
  property string active: ""      // the window's address while out
  property string activeClass: ""
  property var toplevel: null     // its HyprlandToplevel
  property var entry: null        // its stratum
  property var player: null
  property int pid: 0
  property var screen: null
  readonly property color accent: entry ? state.colorForEntry(entry, theme.popups.text, theme.popups.background) : theme.popups.text

  // A window's details (its process) come with Hyprland's client list, which
  // Quickshell fetches on request: once it's in, find the player and audio by
  // the process.
  function learnPid() {
    var p = pidOf(toplevel)
    if (p <= 0 || p === pid) return
    pid = p
    commFile.path = "/proc/" + p + "/comm"
    var own = playerFor(toplevel, activeClass, false)
    if (own) player = own
  }

  function open(t, entry, player) {
    active = addrOf(t)
    activeClass = classOf(t)
    toplevel = t
    pip.entry = entry
    pip.player = player
    pid = 0
    commFile.path = ""
    learnPid()
    Hyprland.refreshToplevels()
    pidLater.restart()
    var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var found = null
    for (var i = 0; i < Quickshell.screens.length; i++) if (Quickshell.screens[i].name === name) found = Quickshell.screens[i]
    screen = found || Quickshell.screens[0]
    crop.reset()
    place()
    shown = false
    showTimer.restart()
  }

  // Closed while out, or back home (Lua's strata-pip event).
  function gone() {
    active = ""
    activeClass = ""
    toplevel = null
    player = null
    pid = 0
    shown = false
    dragging = false
    resizing = 0
  }

  // X: back to its tile at home (it keeps playing); the stratum button: go
  // there (arriving brings it home).
  function sendHome() { if (active !== "") lua("pip_in(" + JSON.stringify(active) + ")") }
  function goHome() { if (active !== "") lua("pip_go(" + JSON.stringify(active) + ")") }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "closewindow") {
        if (pip.active !== "" && String(event.data).replace(/^0x/, "") === pip.active.replace(/^0x/, "")) pip.gone()
        return
      }
      if (event.name !== "custom" || String(event.data).indexOf("strata-pip>>") !== 0) return
      var v = pip.state.parseJson(String(event.data).slice(12))
      if (v && !v.open && v.a === pip.active) pip.gone()
    }
  }

  // Missed the close event (the shell restarted, say): the window is gone.
  Timer {
    interval: 1000
    repeat: true
    running: pip.active !== ""
    property int misses: 0
    onTriggered: {
      Hyprland.refreshToplevels()
      misses = pip.toplevelAt(pip.active) ? 0 : misses + 1
      if (misses >= 3) { misses = 0; pip.gone(); return }
      pip.learnPid()
      if (!pip.player) pip.player = pip.playerFor(pip.toplevel, pip.activeClass, false)
      pip.keepAway()
    }
  }

  // ── Where the card is ─────────────────────────────────────────────────
  // In the layer's coordinates (the whole monitor). The usable area leaves
  // out what the bar reserves.
  property real cx: 0
  property real cy: 0
  property real cw: 400
  property real ch: 225
  readonly property real gap: 16
  readonly property var reserved: {
    var m = Hyprland.focusedMonitor
    var r = m && m.lastIpcObject && m.lastIpcObject.reserved ? m.lastIpcObject.reserved : [0, 0, 0, 0]
    return { l: r[0] || 0, t: r[1] || 0, r: r[2] || 0, b: r[3] || 0 }
  }
  readonly property real areaW: screen ? screen.width : 1920
  readonly property real areaH: screen ? screen.height : 1080
  readonly property real minW: 200
  readonly property real maxW: areaW * 0.8
  readonly property real aspect: crop.aspect > 0.2 ? crop.aspect : 16 / 9

  // The corner from the settings, at the size from the settings.
  function place() {
    var corner = pc.corner || "bottom-right"
    cw = Math.max(minW, Math.min(maxW, Math.round(areaW * (pc.width || 0.25))))
    ch = Math.round(cw / aspect)
    cx = corner.indexOf("left") >= 0 ? reserved.l + gap : areaW - reserved.r - gap - cw
    cy = corner.indexOf("top") >= 0 ? reserved.t + gap : areaH - reserved.b - gap - ch
  }

  // Keep inside the usable area, and snap flush to its edges (at the gap)
  // when within a few pixels of them.
  function fit(x, y, w, h, snap) {
    var L = reserved.l + gap, T = reserved.t + gap, R = areaW - reserved.r - gap, B = areaH - reserved.b - gap
    if (snap) {
      // Near an edge or past it: flush at the gap.
      var S = 28
      if (x < L + S) x = L
      else if (x + w > R - S) x = R - w
      if (y < T + S) y = T
      else if (y + h > B - S) y = B - h
    }
    x = Math.max(reserved.l, Math.min(x, areaW - reserved.r - w))
    y = Math.max(reserved.t, Math.min(y, areaH - reserved.b - h))
    return { x: x, y: y }
  }

  // A new size, keeping the video's shape, with the edge or corner opposite
  // the one you hold staying put (ax, ay: 0 left/top, 1 right/bottom, 0.5
  // centre).
  function resizeTo(w, ax, ay) {
    w = Math.max(minW, Math.min(maxW, w))
    var h = w / aspect
    if (h > areaH * 0.8) { h = areaH * 0.8; w = h * aspect }
    var nx = cx + (cw - w) * ax, ny = cy + (ch - h) * ay
    var p = fit(nx, ny, w, h, false)
    cx = p.x; cy = p.y; cw = w; ch = h
  }

  // The crop changed the video's shape: same width, new height, the edge
  // nearest the screen's edge kept.
  onAspectChanged: if (active !== "") resizeTo(cw, cx + cw / 2 < areaW / 2 ? 0 : 1, cy + ch / 2 < areaH / 2 ? 0 : 1)

  // Keep out of the way: when the window you're using overlaps it, go to
  // the other side. Once per window: one wide enough to cover both sides
  // would otherwise send it back and forth for as long as it has focus.
  property string avoided: ""
  // Placed by hand over the focused window: leave it there (until another
  // window that overlaps it gets focus).
  function placedByHand() {
    var t = Hyprland.activeToplevel
    avoided = t ? String(t.address).replace(/^0x/, "") : ""
  }
  function keepAway() {
    if (!pc.avoid_focus || dragging || resizing !== 0 || !screen) return
    var t = Hyprland.activeToplevel
    var o = t && t.lastIpcObject ? t.lastIpcObject : null
    var addr = t ? String(t.address).replace(/^0x/, "") : ""
    if (!o || !o.at || addr === active.replace(/^0x/, "")) return
    var gx = screen.x + cx, gy = screen.y + cy
    var overlap = !(o.at[0] + o.size[0] <= gx || gx + cw <= o.at[0] || o.at[1] + o.size[1] <= gy || gy + ch <= o.at[1])
    if (!overlap) { if (avoided === addr) avoided = ""; return }
    if (avoided === addr) return
    avoided = addr
    cx = areaW - cx - cw
  }

  // ── Cropping ──────────────────────────────────────────────────────────
  // A small copy of the window, a few times a second, read back through a
  // canvas: rows and columns that never get bright are bars, pixels that
  // change are the video. Decided after a second or so, then again now and
  // then (the page may go fullscreen late, or change).
  QtObject {
    id: crop
    property real x0: 0
    property real y0: 0
    property real x1: 1
    property real y1: 1
    readonly property real aspect: {
      var s = view.sourceSize
      if (!s || s.width <= 0 || s.height <= 0) return 0
      return ((x1 - x0) * s.width) / Math.max(1, (y1 - y0) * s.height)
    }
    property int samples: 0
    property int decisions: 0
    property var prev: null
    property var moved: null
    property var bright: null
    property int sw: 128
    property int sh: 72

    function reset() {
      x0 = 0; y0 = 0; x1 = 1; y1 = 1
      decisions = 0
      restart()
    }
    function restart() { samples = 0; prev = null; moved = null; bright = null }

    function analyse(d) {
      var n = sw * sh
      if (!moved) { moved = new Array(n).fill(0); bright = new Array(n).fill(0) }
      var cur = new Array(n)
      for (var i = 0; i < n; i++) {
        var l = (d[i * 4] + d[i * 4 + 1] + d[i * 4 + 2]) / 3
        cur[i] = l
        if (l > bright[i]) bright[i] = l
        if (prev && Math.abs(l - prev[i]) > 10) moved[i]++
      }
      prev = cur
      samples++
      var due = decisions === 0 ? 4 : decisions === 1 ? 8 : 25
      if (samples >= due) decide()
    }

    function decide() {
      // The picture: not black.
      var bx0 = sw, by0 = sh, bx1 = -1, by1 = -1
      // The video: what moved in at least two samples.
      var mx0 = sw, my0 = sh, mx1 = -1, my1 = -1, count = 0
      for (var y = 0; y < sh; y++) for (var x = 0; x < sw; x++) {
        var k = y * sw + x
        if (bright[k] > 20) { if (x < bx0) bx0 = x; if (y < by0) by0 = y; if (x > bx1) bx1 = x; if (y > by1) by1 = y }
        if (moved[k] >= 2) { count++; if (x < mx0) mx0 = x; if (y < my0) my0 = y; if (x > mx1) mx1 = x; if (y > my1) my1 = y }
      }
      decisions++
      if (bx1 < 0) { restart(); return } // nothing drawn yet
      var X0 = bx0, Y0 = by0, X1 = bx1 + 1, Y1 = by1 + 1
      if (count > 24 && mx1 >= 0) {
        // Page around the video: the moving part, if it's clearly smaller
        // than the picture and shaped like a video.
        var mw = (mx1 + 1 - mx0) * view.sourceSize.width / sw, mh = (my1 + 1 - my0) * view.sourceSize.height / sh
        var area = (mx1 + 1 - mx0) * (my1 + 1 - my0), all = (X1 - X0) * (Y1 - Y0)
        var shape = mw / Math.max(1, mh)
        if (area < all * 0.85 && shape > 1.1 && shape < 2.7) {
          X0 = Math.max(X0, mx0); Y0 = Math.max(Y0, my0); X1 = Math.min(X1, mx1 + 1); Y1 = Math.min(Y1, my1 + 1)
        }
      }
      var nx0 = X0 / sw, ny0 = Y0 / sh, nx1 = X1 / sw, ny1 = Y1 / sh
      // Only real changes: the sample grid is coarse.
      if (Math.abs(nx0 - x0) > 1.5 / sw || Math.abs(ny0 - y0) > 1.5 / sh || Math.abs(nx1 - x1) > 1.5 / sw || Math.abs(ny1 - y1) > 1.5 / sh) {
        x0 = nx0; y0 = ny0; x1 = nx1; y1 = ny1
      }
      pip.shown = true
      restart()
    }
  }

  Timer {
    interval: 400
    repeat: true
    running: pip.active !== "" && view.hasContent
    onTriggered: {
      var s = view.sourceSize
      if (s && s.width > 0) crop.sh = Math.max(32, Math.min(128, Math.round(crop.sw * s.height / s.width)))
      view.grabToImage(function(r) { snap.source = r.url }, Qt.size(crop.sw, crop.sh))
    }
  }

  Timer { id: pidLater; interval: 250; onTriggered: pip.learnPid() }

  // Shown once the first crop is decided (or after a moment regardless).
  property bool shown: false
  Timer { id: showTimer; interval: 2500; onTriggered: pip.shown = true }

  // ── Player and audio ──────────────────────────────────────────────────
  // Position isn't pushed by MPRIS players: ask now and then.
  Timer {
    interval: card.hovered || pip.seeking ? 250 : 1000
    repeat: true
    running: pip.active !== "" && pip.player !== null
    onTriggered: pip.player.positionChanged()
  }
  property bool seeking: false
  property real seekFrac: 0
  readonly property real length: player && player.lengthSupported ? player.length : 0
  readonly property real frac: seeking ? seekFrac : (player && length > 0 ? Math.max(0, Math.min(1, player.position / length)) : 0)
  function seekTo(f) { if (player && player.canSeek && length > 0) player.position = f * length }
  function skip(sec) {
    if (!player || !player.canSeek) return
    if (length > 0) player.position = Math.max(0, Math.min(length - 1, player.position + sec))
    else player.seek(sec)
  }
  function clock(s) {
    s = Math.max(0, Math.floor(s))
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60
    return (h > 0 ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (r < 10 ? "0" : "") + r
  }

  // The app's audio streams: its own process's, else (Chromium plays from a
  // separate audio process) those of the same program.
  FileView { id: commFile; blockLoading: true; printErrors: false }
  readonly property string comm: commFile.path !== "" ? String(commFile.text() || "").trim() : ""
  // Every playback stream is tracked while a card is out: a node's
  // properties (its process) only arrive once it's bound.
  readonly property var playback: {
    if (active === "") return []
    var nodes = Pipewire.nodes.values, out = []
    for (var i = 0; i < nodes.length; i++) if (nodes[i].isStream && nodes[i].audio) out.push(nodes[i])
    return out
  }
  PwObjectTracker { objects: pip.playback }
  readonly property var streams: {
    var own = [], same = []
    for (var i = 0; i < playback.length; i++) {
      var p = playback[i].properties || {}
      if (p["media.class"] !== "Stream/Output/Audio") continue
      if (String(p["application.process.id"]) === String(pid)) own.push(playback[i])
      else if (comm !== "" && String(p["application.process.binary"]) === comm) same.push(playback[i])
    }
    return own.length ? own : same
  }
  readonly property bool hasAudio: streams.length > 0 || (player !== null && player.volumeSupported)
  readonly property bool muted: streams.length > 0 ? (streams[0].audio ? streams[0].audio.muted : false) : (player && player.volumeSupported ? player.volume <= 0.001 : false)
  readonly property real volume: streams.length > 0 ? (streams[0].audio ? streams[0].audio.volume : 1) : (player && player.volumeSupported ? player.volume : 1)
  property real unmuteTo: 1
  function setMuted(m) {
    if (streams.length > 0) { for (var i = 0; i < streams.length; i++) if (streams[i].audio) streams[i].audio.muted = m; return }
    if (player && player.volumeSupported) {
      if (m) { unmuteTo = Math.max(0.05, player.volume); player.volume = 0 } else player.volume = unmuteTo
    }
  }
  function setVolume(v) {
    v = Math.max(0, Math.min(1, v))
    if (streams.length > 0) { for (var i = 0; i < streams.length; i++) if (streams[i].audio) { streams[i].audio.volume = v; if (v > 0) streams[i].audio.muted = false } return }
    if (player && player.volumeSupported) player.volume = v
  }

  // For tests: what's out, and what it found.
  IpcHandler {
    target: "strataPip"
    function state(): string {
      return JSON.stringify({ active: pip.active, cls: pip.activeClass, pid: pip.pid, comm: pip.comm,
                              player: pip.player ? String(pip.player.dbusName) : "", length: pip.length, frac: pip.frac,
                              streams: pip.streams.length, muted: pip.muted, volume: pip.volume,
                              crop: [crop.x0, crop.y0, crop.x1, crop.y1], aspect: pip.aspect,
                              card: [pip.cx, pip.cy, pip.cw, pip.ch], shown: pip.shown })
    }
  }

  // ── The card ──────────────────────────────────────────────────────────
  property bool dragging: false
  property int resizing: 0 // which edges, as bits: 1 left, 2 right, 4 top, 8 bottom

  PanelWindow {
    id: layer
    screen: pip.screen
    visible: pip.active !== "" && pip.screen !== null
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    // The top layer: a fullscreen window covers it, as it covers the bar.
    WlrLayershell.namespace: "strata-pip"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // Input only on the card; the whole screen while dragging or resizing,
    // so a pointer that gets ahead of the card (or is held by a snap) isn't
    // lost.
    mask: Region { item: pip.dragging || pip.resizing !== 0 ? fullArea : card }
    Item { id: fullArea; anchors.fill: parent }

    Item {
      id: card
      x: pip.cx
      y: pip.cy
      width: pip.cw
      height: pip.ch
      opacity: pip.shown ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 180 } }
      readonly property bool hovered: hover.hovered || pip.dragging || pip.resizing !== 0 || pip.seeking
      HoverHandler { id: hover }

      ClippingRectangle {
        id: frame
        anchors.fill: parent
        radius: 12
        color: "black"

        // The window, scaled so the crop fills the card (it keeps its own
        // shape, which the card's matches).
        ScreencopyView {
          id: view
          captureSource: pip.toplevel ? pip.toplevel.wayland : null
          live: true
          width: frame.width / Math.max(0.05, crop.x1 - crop.x0)
          height: frame.height / Math.max(0.05, crop.y1 - crop.y0)
          x: -crop.x0 * width
          y: -crop.y0 * height
        }

        // For the crop: the grab, read back through a canvas.
        Image {
          id: snap
          visible: false
          cache: false
          onStatusChanged: if (status === Image.Ready) probe.requestPaint()
        }
        Canvas {
          id: probe
          width: crop.sw
          height: crop.sh
          opacity: 0.01
          renderStrategy: Canvas.Immediate
          onPaint: {
            if (snap.status !== Image.Ready) return
            var ctx = getContext("2d")
            ctx.drawImage(snap, 0, 0, crop.sw, crop.sh)
            crop.analyse(ctx.getImageData(0, 0, crop.sw, crop.sh).data)
          }
        }

        // Controls, over a shade, on hover.
        Rectangle {
          anchors.fill: parent
          opacity: card.hovered ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 140 } }
          gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.55) }
            GradientStop { position: 0.3; color: Qt.rgba(0, 0, 0, 0.1) }
            GradientStop { position: 0.6; color: Qt.rgba(0, 0, 0, 0.15) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.7) }
          }
        }

        // Idle: a thin progress line along the bottom.
        Rectangle {
          visible: pip.pc.seek_bar !== false && pip.length > 0
          opacity: card.hovered ? 0 : 1
          Behavior on opacity { NumberAnimation { duration: 140 } }
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          width: parent.width * pip.frac
          height: 3
          color: pip.accent
        }
      }

      // The accent edge.
      Rectangle {
        anchors.fill: parent
        radius: frame.radius
        color: "transparent"
        border.width: 2
        border.color: Qt.alpha(pip.accent, 0.85)
      }

      // Drag to move, wheel to resize (under the controls and the edges).
      MouseArea {
        anchors.fill: parent
        cursorShape: pip.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        property point grab
        onPressed: function(m) { grab = Qt.point(m.x, m.y); pip.dragging = true }
        onPositionChanged: function(m) {
          if (!pressed) return
          var p = pip.fit(pip.cx + m.x - grab.x, pip.cy + m.y - grab.y, pip.cw, pip.ch, true)
          pip.cx = p.x; pip.cy = p.y
        }
        onReleased: { pip.dragging = false; pip.placedByHand() }
        onCanceled: pip.dragging = false
        onWheel: function(w) {
          var f = w.angleDelta.y > 0 ? 1.08 : w.angleDelta.y < 0 ? 1 / 1.08 : 1
          if (f !== 1) pip.resizeTo(pip.cw * f, pip.cx + pip.cw / 2 < pip.areaW / 2 ? 0 : 1, pip.cy + pip.ch / 2 < pip.areaH / 2 ? 0 : 1)
        }
      }

      // Resize from any edge or corner (the opposite one stays put). Edges
      // as bits: 1 left, 2 right, 4 top, 8 bottom.
      Repeater {
        model: [
          { e: 1, c: Qt.SizeHorCursor }, { e: 2, c: Qt.SizeHorCursor },
          { e: 4, c: Qt.SizeVerCursor }, { e: 8, c: Qt.SizeVerCursor },
          { e: 5, c: Qt.SizeFDiagCursor }, { e: 10, c: Qt.SizeFDiagCursor },
          { e: 6, c: Qt.SizeBDiagCursor }, { e: 9, c: Qt.SizeBDiagCursor }
        ]
        delegate: MouseArea {
          required property var modelData
          readonly property int e: modelData.e
          readonly property real t: 8
          x: (e & 2) ? card.width - t : (e & 1) ? 0 : t
          y: (e & 8) ? card.height - t : (e & 4) ? 0 : t
          width: (e & 3) ? t : card.width - 2 * t
          height: (e & 12) ? t : card.height - 2 * t
          cursorShape: modelData.c
          property real startW
          property point start
          onPressed: function(m) { pip.resizing = e; startW = pip.cw; start = mapToItem(null, m.x, m.y) }
          onPositionChanged: function(m) {
            if (!pressed) return
            var p = mapToItem(null, m.x, m.y)
            var dx = p.x - start.x, dy = p.y - start.y
            var byW = (e & 1) ? -dx : (e & 2) ? dx : 0
            var byH = ((e & 4) ? -dy : (e & 8) ? dy : 0) * pip.aspect
            pip.resizeTo(startW + (Math.abs(byW) >= Math.abs(byH) ? byW : byH), (e & 1) ? 1 : (e & 2) ? 0 : 0.5, (e & 4) ? 1 : (e & 8) ? 0 : 0.5)
          }
          onReleased: { pip.resizing = 0; pip.placedByHand() }
          onCanceled: pip.resizing = 0
        }
      }

      // ── Controls ──
      Item {
        anchors.fill: parent
        anchors.margins: 10
        opacity: card.hovered ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 140 } }

        component Glyph: Rectangle {
          id: g
          property string icon: ""
          property real size: 18
          signal clicked()
          width: size + 14
          height: size + 14
          radius: height / 2
          color: area.containsMouse ? Qt.rgba(1, 1, 1, 0.18) : "transparent"
          Text {
            anchors.centerIn: parent
            text: g.icon
            color: "white"
            font.family: Style.font.family
            font.pixelSize: g.size
          }
          MouseArea { id: area; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: g.clicked() }
        }

        // Its stratum (go there) and X (send it home).
        Glyph {
          anchors.left: parent.left
          anchors.top: parent.top
          icon: pip.entry ? (pip.entry.iconActive || pip.entry.icon) : "󰋜"
          size: 16
          onClicked: pip.goHome()
        }
        Glyph {
          anchors.right: parent.right
          anchors.top: parent.top
          icon: "󰅖"
          size: 16
          onClicked: pip.sendHome()
        }

        Row {
          anchors.centerIn: parent
          spacing: Math.max(6, Math.min(24, card.width / 20))
          visible: pip.player !== null
          Glyph { anchors.verticalCenter: parent.verticalCenter; icon: "󰴪"; size: 20; visible: pip.player && pip.player.canSeek; onClicked: pip.skip(-10) }
          Glyph { anchors.verticalCenter: parent.verticalCenter; icon: pip.player && pip.player.isPlaying ? "󰏤" : "󰐊"; size: 28; onClicked: if (pip.player) pip.player.togglePlaying() }
          Glyph { anchors.verticalCenter: parent.verticalCenter; icon: "󰵱"; size: 20; visible: pip.player && pip.player.canSeek; onClicked: pip.skip(10) }
        }

        // Volume, seek bar and time.
        Item {
          id: bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: 30

          // Mute, and a volume slider that opens while the pointer is on
          // it (the speaker included, with a moment's grace in between).
          MouseArea {
            id: vol
            visible: pip.hasAudio
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: visible ? speaker.width + (open ? 72 : 0) : 0
            height: parent.height
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            readonly property bool open: containsMouse || slider.pressed || grace.running
            onContainsMouseChanged: if (!containsMouse) grace.restart()
            Timer { id: grace; interval: 500 }
            Behavior on width { NumberAnimation { duration: 120 } }
            Glyph {
              id: speaker
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              icon: pip.muted ? "󰖁" : "󰕾"
              size: 16
              onClicked: pip.setMuted(!pip.muted)
            }
            Item {
              anchors.left: speaker.right
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              height: 16
              clip: true
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                x: 4
                width: 60
                height: 4
                radius: 2
                color: Qt.rgba(1, 1, 1, 0.3)
                Rectangle { width: parent.width * (pip.muted ? 0 : pip.volume); height: parent.height; radius: 2; color: "white" }
              }
              MouseArea {
                id: slider
                width: 68
                height: parent.height
                cursorShape: Qt.PointingHandCursor
                onPressed: function(m) { pip.setVolume((m.x - 4) / 60) }
                onPositionChanged: function(m) { if (pressed) pip.setVolume((m.x - 4) / 60) }
              }
            }
          }

          Text {
            id: time
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: pip.length > 0
            text: pip.clock(pip.frac * pip.length) + (card.width > 360 ? " / " + pip.clock(pip.length) : "")
            color: "white"
            font.family: Style.font.family
            font.pixelSize: 12
          }

          Item {
            id: bar
            visible: pip.pc.seek_bar !== false && pip.length > 0
            anchors.left: vol.right
            anchors.leftMargin: 8
            anchors.right: time.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            height: 16
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              height: seekArea.containsMouse || pip.seeking ? 6 : 4
              radius: height / 2
              color: Qt.rgba(1, 1, 1, 0.3)
              Behavior on height { NumberAnimation { duration: 100 } }
              Rectangle { width: parent.width * pip.frac; height: parent.height; radius: parent.radius; color: pip.accent }
            }
            Rectangle {
              visible: seekArea.containsMouse || pip.seeking
              x: parent.width * pip.frac - width / 2
              anchors.verticalCenter: parent.verticalCenter
              width: 12
              height: 12
              radius: 6
              color: "white"
            }
            MouseArea {
              id: seekArea
              anchors.fill: parent
              hoverEnabled: true
              enabled: pip.player !== null && pip.player.canSeek
              cursorShape: Qt.PointingHandCursor
              function at(m) { return Math.max(0, Math.min(1, m.x / width)) }
              onPressed: function(m) { pip.seekFrac = at(m); pip.seeking = true }
              onPositionChanged: function(m) { if (pressed) pip.seekFrac = at(m) }
              onReleased: function(m) { pip.seekTo(at(m)); pip.seeking = false }
              onCanceled: pip.seeking = false
            }
          }
        }
      }
    }
  }
}
