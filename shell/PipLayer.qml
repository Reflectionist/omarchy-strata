import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// Picture in picture, the shell's half. The Hyprland plugin draws the card
// (native/src/pip.cpp): it shrinks a playing picture into it as you leave
// its stratum, keeps it live on every stratum, and grows it back when you
// return. This side says which windows play video on the stratum you're on
// (their MPRIS players, matched by process), and draws the card's controls
// on top of it: the stratum button, X, skip, play/pause, mute and volume,
// the seek bar and time, and a thin progress line otherwise. Dragging the
// card or an edge, and scrolling over it, are handed to the plugin.
Item {
  id: pip
  required property var service
  readonly property var state: service.stateObject
  readonly property var theme: Commons.ShellColor || Commons.Color
  readonly property var pc: state.config && state.config.pip ? state.config.pip : ({})

  function lua(code) { Quickshell.execDetached(["hyprctl", "eval", 'local s = require("hypr.strata") ' + code]) }

  // ── Which windows play video here ─────────────────────────────────────
  readonly property int players: Mpris.players.values.length // ask early: the list fills in on first use

  function classOf(t) {
    if (t.wayland && t.wayland.appId) return String(t.wayland.appId)
    return t.lastIpcObject && t.lastIpcObject.class ? String(t.lastIpcObject.class) : ""
  }
  function pidOf(t) { return t && t.lastIpcObject && t.lastIpcObject.pid ? Number(t.lastIpcObject.pid) : 0 }
  function addrOf(t) {
    var a = String(t.address)
    return a.indexOf("0x") === 0 ? a : "0x" + a
  }
  function toplevelAt(addr) {
    var a = String(addr).replace(/^0x/, "")
    var tops = Hyprland.toplevels.values
    for (var i = 0; i < tops.length; i++) if (String(tops[i].address).replace(/^0x/, "") === a) return tops[i]
    return null
  }
  function entryFor(wsName) {
    var list = state.stack || []
    for (var i = 0; i < list.length; i++) if (list[i].wsName === wsName) return list[i]
    return null
  }

  // The window's own MPRIS service, by its process (Chromium:
  // ...chromium.instance<pid>); failing that, a player named like the app.
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

  // Tell the plugin which windows on this stratum play video (only what
  // changed), and the card's corner, size and edge colour.
  property var watched: ({})
  property string lastConfig: ""
  property int ticks: 0
  function refreshWatch() {
    var cur = state.current
    var conf = cur && cur.kind === "themed" && cur.stratum ? cur.stratum.pip : null
    var want = {}
    if (conf && conf.enabled && (conf.apps || []).length) {
      var tops = Hyprland.toplevels.values
      for (var i = 0; i < tops.length; i++) {
        var t = tops[i]
        if (!t.workspace || t.workspace.id !== state.focusedId) continue
        var cls = classOf(t)
        var hit = false
        for (var j = 0; j < conf.apps.length; j++) {
          try { if (new RegExp(conf.apps[j]).test(cls)) hit = true } catch (e) {}
        }
        if (hit && pidOf(t) > 0 && playerFor(t, cls, true)) want[addrOf(t)] = true
      }
    }
    var code = ""
    var now = Date.now()
    for (var m in want) {
      var tm = toplevelAt(m)
      var size = tm && tm.lastIpcObject && tm.lastIpcObject.size ? String(tm.lastIpcObject.size) : ""
      if (!barsDone[m] || now - barsDone[m] > 15000 || (size !== "" && barsSize[m] !== size)) barsNext(m)
    }
    // Now and then all of it again: a plugin that was rebuilt (and reloaded)
    // starts with no watches.
    var resync = ++ticks % 8 === 0
    if (resync) { lastConfig = ""; code += "s.pip_announce() " }
    for (var a in want) {
      if (resync || !watched[a]) code += "s.pip_watch(" + JSON.stringify(a) + ", true) "
      if (resync && barsCrop[a]) code += "s.pip_crop(" + JSON.stringify(a) + ", " + barsCrop[a] + ") "
    }
    for (var b in watched) if (!want[b]) code += "s.pip_watch(" + JSON.stringify(b) + ", false) "
    watched = want
    if (Object.keys(want).length > 0) {
      var hex = String(state.colorForEntry(cur, theme.popups.text, theme.popups.background)).slice(0, 7)
      var cfg = "s.pip_config(" + JSON.stringify(pc.corner || "bottom-right") + ", " + Number(pc.width || 0.25) + ", " + JSON.stringify(hex) + ") "
      if (cfg !== lastConfig) { code += cfg; lastConfig = cfg }
    }
    if (code !== "") lua(code)
  }
  Connections {
    target: pip.state
    function onCurrentIndexChanged() { pip.refreshWatch() }
  }
  Timer {
    interval: 700
    repeat: true
    running: true
    onTriggered: { Hyprland.refreshToplevels(); pip.refreshWatch() }
  }
  // A shell that (re)starts asks what's out.
  Timer { interval: 1500; running: true; onTriggered: pip.lua("s.pip_announce()") }

  // ── Black bars, for players that redraw all of their window ───────────
  // A browser's picture is what it redraws (the plugin sees that); mpv and
  // the like redraw everything, bars included. So each watched window is
  // measured now and then while it's on screen: a few small copies, rows and
  // columns that never get bright are bars. The plugin uses the result only
  // for a window that redraws all of itself.
  property var barsDone: ({})      // address -> when it was measured
  property var barsLast: []        // the last measurement (for tests)
  property var barsCrop: ({})      // address -> the crop sent (sent again on a resync)
  property var barsSize: ({})      // address -> its size when measured (a new size measures again)
  property string barsAddr: ""
  property int barsSamples: 0
  property var barsBright: null
  // The sample's size, fixed for a measurement once the window's is known
  // (128 wide, the window's shape).
  property int barsW: 128
  property int barsH: 0
  function barsNext(addr) {
    if (barsAddr !== "") return
    barsAddr = addr
    barsSamples = 0
    barsBright = null
    barsH = 0
    barsTimer.restart()
  }
  // Each pixel counts how many samples it was bright in; picture is what's
  // bright in most of them (one odd frame, mid-repaint, doesn't decide).
  function barsSample(d) {
    var n = barsW * barsH
    if (!barsBright || barsBright.length !== n) barsBright = new Array(n).fill(0)
    for (var i = 0; i < n; i++) {
      if ((d[i * 4] + d[i * 4 + 1] + d[i * 4 + 2]) / 3 > 20) barsBright[i]++
    }
    if (++barsSamples < 5) return
    var x0 = barsW, y0 = barsH, x1 = -1, y1 = -1
    for (var y = 0; y < barsH; y++) for (var x = 0; x < barsW; x++) {
      if (barsBright[y * barsW + x] < 3) continue
      if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y
    }
    var a = barsAddr
    barsLast = [barsW, barsH, x0, y0, x1, y1]
    barsDone[a] = Date.now()
    var tl = toplevelAt(a)
    barsSize[a] = tl && tl.lastIpcObject && tl.lastIpcObject.size ? String(tl.lastIpcObject.size) : ""
    barsAddr = ""
    barsTimer.stop()
    if (x1 < 0) return
    barsCrop[a] = (x0 / barsW).toFixed(4) + ", " + (y0 / barsH).toFixed(4) + ", " + ((x1 + 1) / barsW).toFixed(4) + ", " + ((y1 + 1) / barsH).toFixed(4)
    lua("s.pip_crop(" + JSON.stringify(a) + ", " + barsCrop[a] + ")")
  }
  Timer {
    id: barsTimer
    interval: 250
    repeat: true
    onTriggered: {
      var t = pip.toplevelAt(pip.barsAddr)
      if (!t || !t.workspace || t.workspace.id !== pip.state.focusedId) { pip.barsAddr = ""; stop(); return }
      var s = probeView.sourceSize
      if (!probeView.hasContent || !s || s.width <= 0 || s.height <= 0) return
      if (pip.barsH === 0) { pip.barsH = Math.max(16, Math.min(512, Math.round(pip.barsW * s.height / s.width))); return }
      probeView.grabToImage(function(r) { barsSnap.source = r.url }, Qt.size(pip.barsW, pip.barsH))
    }
  }
  PanelWindow {
    visible: pip.barsAddr !== ""
    anchors { top: true; left: true }
    implicitWidth: 1
    implicitHeight: 1
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "strata-pip-probe"
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}
    ScreencopyView {
      id: probeView
      readonly property var source: pip.barsAddr !== "" ? pip.toplevelAt(pip.barsAddr) : null
      captureSource: source ? source.wayland : null
      live: true
      width: pip.barsW
      height: pip.barsH > 0 ? pip.barsH : pip.barsW
    }
    Image {
      id: barsSnap
      visible: false
      cache: false
      onStatusChanged: if (status === Image.Ready) barsCanvas.requestPaint()
    }
    Canvas {
      id: barsCanvas
      width: pip.barsW
      height: Math.max(1, pip.barsH)
      opacity: 0.01
      renderStrategy: Canvas.Immediate
      onPaint: {
        if (barsSnap.status !== Image.Ready || pip.barsAddr === "" || pip.barsH === 0) return
        var ctx = getContext("2d")
        ctx.drawImage(barsSnap, 0, 0, pip.barsW, pip.barsH)
        pip.barsSample(ctx.getImageData(0, 0, pip.barsW, pip.barsH).data)
      }
    }
  }

  // ── What's out (the plugin's strata-pip events) ───────────────────────
  property string active: ""      // the window's address while out
  property string activeClass: ""
  property var toplevel: null
  property var entry: null        // its stratum
  property var player: null
  property int pid: 0
  property var screen: null
  property bool settled: false    // resting (not flying in or out, not dragged)
  property real cx: 0
  property real cy: 0
  property real cw: 0
  property real ch: 0

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "strata-pip") return
      var v = pip.state.eventJson(event.data)
      if (!v) return
      if (!v.open) { pip.gone(); return }
      if (pip.active !== v.a) {
        pip.active = v.a
        pip.activeClass = v["class"] || ""
        pip.entry = pip.entryFor(v.ws || "")
        pip.toplevel = pip.toplevelAt(v.a)
        pip.player = pip.toplevel ? pip.playerFor(pip.toplevel, pip.activeClass, false) : null
        pip.pid = pip.pidOf(pip.toplevel)
        commFile.path = pip.pid > 0 ? "/proc/" + pip.pid + "/comm" : ""
      }
      var found = null
      for (var i = 0; i < Quickshell.screens.length; i++) if (Quickshell.screens[i].name === v.mon) found = Quickshell.screens[i]
      pip.screen = found || Quickshell.screens[0]
      pip.cx = v.x; pip.cy = v.y; pip.cw = v.w; pip.ch = v.h
      pip.settled = v.settled === true
    }
  }

  function gone() {
    active = ""
    activeClass = ""
    toplevel = null
    entry = null
    player = null
    pid = 0
    settled = false
    dragging = false
  }

  // X: home without going there (it keeps playing); the stratum button: go
  // there (arriving brings it home).
  function sendHome() { lua("s.pip_home()") }
  function goHome() { lua("s.pip_go()") }

  // Its process, once Hyprland's client list has it.
  Timer {
    interval: 1000
    repeat: true
    running: pip.active !== ""
    onTriggered: {
      if (!pip.toplevel) pip.toplevel = pip.toplevelAt(pip.active)
      var p = pip.pidOf(pip.toplevel)
      if (p > 0 && p !== pip.pid) {
        pip.pid = p
        commFile.path = "/proc/" + p + "/comm"
        var own = pip.playerFor(pip.toplevel, pip.activeClass, false)
        if (own) pip.player = own
      }
      if (!pip.player && pip.toplevel) pip.player = pip.playerFor(pip.toplevel, pip.activeClass, false)
      pip.keepAway()
    }
  }

  // Keep out of the way: when a window under the card gets focus, the card
  // goes to the other side. Where you put it by hand stays, until another
  // window under it gets focus.
  property string avoided: ""
  function placedByHand() {
    var t = Hyprland.activeToplevel
    avoided = t ? String(t.address).replace(/^0x/, "") : ""
  }
  function keepAway() {
    if (!pc.avoid_focus || !settled || dragging || !screen) return
    var t = Hyprland.activeToplevel
    var o = t && t.lastIpcObject ? t.lastIpcObject : null
    var addr = t ? String(t.address).replace(/^0x/, "") : ""
    if (!o || !o.at || addr === active.replace(/^0x/, "")) return
    var gx = screen.x + cx, gy = screen.y + cy
    var overlap = !(o.at[0] + o.size[0] <= gx || gx + cw <= o.at[0] || o.at[1] + o.size[1] <= gy || gy + ch <= o.at[1])
    if (!overlap) { if (avoided === addr) avoided = ""; return }
    if (avoided === addr) return
    avoided = addr
    lua("s.pip_card(" + (screen.width - cx - cw).toFixed(1) + ", " + cy.toFixed(1) + ", " + cw.toFixed(1) + ", " + ch.toFixed(1) + ")")
  }

  // ── Player and audio ──────────────────────────────────────────────────
  // Position isn't pushed by MPRIS players: ask now and then.
  Timer {
    interval: overlay.hovered || pip.seeking ? 250 : 1000
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
  // separate audio process) those of the same program. Every playback stream
  // is tracked while a card is out: a node's properties only arrive once
  // it's bound. (Quickshell counts playback streams as sinks.)
  FileView { id: commFile; blockLoading: true; printErrors: false }
  readonly property string comm: commFile.path !== "" ? String(commFile.text() || "").trim() : ""
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
    // Measure a window's bars now (tests).
    function measure(addr: string): void { pip.barsDone = ({}); pip.barsNext(addr) }
    function state(): string {
      return JSON.stringify({ active: pip.active, cls: pip.activeClass, pid: pip.pid, comm: pip.comm,
                              player: pip.player ? String(pip.player.dbusName) : "", length: pip.length, frac: pip.frac,
                              streams: pip.streams.length, muted: pip.muted, volume: pip.volume,
                              card: [pip.cx, pip.cy, pip.cw, pip.ch], settled: pip.settled, watched: Object.keys(pip.watched),
                              bars: { addr: pip.barsAddr, samples: pip.barsSamples, content: probeView.hasContent, size: [probeView.sourceSize.width, probeView.sourceSize.height], done: pip.barsDone, last: pip.barsLast } })
    }
  }

  // ── The controls, over the card the plugin draws ──────────────────────
  property bool dragging: false

  PanelWindow {
    id: layer
    screen: pip.screen
    visible: pip.active !== "" && pip.screen !== null
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    // The top layer: a fullscreen window covers it, as it covers the card.
    WlrLayershell.namespace: "strata-pip"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // Input only on the card; the whole screen while dragging (the plugin
    // moves the card; the release must still arrive here). Nothing while it
    // flies in or out.
    mask: Region { item: pip.dragging ? fullArea : (pip.settled ? overlay : nothing) }
    Item { id: fullArea; anchors.fill: parent }
    Item { id: nothing; width: 0; height: 0 }

    Item {
      id: overlay
      x: pip.cx
      y: pip.cy
      width: pip.cw
      height: pip.ch
      visible: pip.settled || pip.dragging
      readonly property bool hovered: hover.hovered || pip.seeking
      HoverHandler { id: hover }

      // Drag to move, wheel to resize.
      MouseArea {
        anchors.fill: parent
        cursorShape: pip.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        onPressed: { pip.dragging = true; pip.lua("s.pip_drag(0)") }
        onReleased: { pip.lua("s.pip_drag_end()"); pip.dragging = false; pip.placedByHand() }
        onCanceled: { pip.lua("s.pip_drag_end()"); pip.dragging = false }
        onWheel: function(w) {
          var f = w.angleDelta.y > 0 ? 1.08 : w.angleDelta.y < 0 ? 1 / 1.08 : 1
          if (f !== 1) pip.lua("s.pip_scale(" + f + ")")
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
          x: (e & 2) ? overlay.width - t : (e & 1) ? 0 : t
          y: (e & 8) ? overlay.height - t : (e & 4) ? 0 : t
          width: (e & 3) ? t : overlay.width - 2 * t
          height: (e & 12) ? t : overlay.height - 2 * t
          cursorShape: modelData.c
          onPressed: { pip.dragging = true; pip.lua("s.pip_drag(" + e + ")") }
          onReleased: { pip.lua("s.pip_drag_end()"); pip.dragging = false; pip.placedByHand() }
          onCanceled: { pip.lua("s.pip_drag_end()"); pip.dragging = false }
        }
      }

      // Idle: a thin progress line along the bottom.
      Rectangle {
        visible: pip.pc.seek_bar !== false && pip.length > 0 && !pip.dragging
        opacity: overlay.hovered ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 140 } }
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        width: parent.width * pip.frac
        height: 3
        color: pip.entry ? pip.state.colorForEntry(pip.entry, pip.theme.popups.text, pip.theme.popups.background) : "white"
      }

      // Controls, over a shade, on hover.
      Item {
        anchors.fill: parent
        opacity: overlay.hovered && !pip.dragging ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 140 } }

        Rectangle {
          anchors.fill: parent
          gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.55) }
            GradientStop { position: 0.3; color: Qt.rgba(0, 0, 0, 0.1) }
            GradientStop { position: 0.6; color: Qt.rgba(0, 0, 0, 0.15) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.7) }
          }
        }

        Item {
          anchors.fill: parent
          anchors.margins: 10

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
            spacing: Math.max(6, Math.min(24, overlay.width / 20))
            visible: pip.player !== null
            Glyph { anchors.verticalCenter: parent.verticalCenter; icon: "󰴪"; size: 20; visible: pip.player && pip.player.canSeek; onClicked: pip.skip(-10) }
            Glyph { anchors.verticalCenter: parent.verticalCenter; icon: pip.player && pip.player.isPlaying ? "󰏤" : "󰐊"; size: 28; onClicked: if (pip.player) pip.player.togglePlaying() }
            Glyph { anchors.verticalCenter: parent.verticalCenter; icon: "󰵱"; size: 20; visible: pip.player && pip.player.canSeek; onClicked: pip.skip(10) }
          }

          // Volume, seek bar and time.
          Item {
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
              text: pip.clock(pip.frac * pip.length) + (overlay.width > 360 ? " / " + pip.clock(pip.length) : "")
              color: "white"
              font.family: Style.font.family
              font.pixelSize: 12
            }

            Item {
              visible: pip.length > 0
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
                Rectangle {
                  width: parent.width * pip.frac
                  height: parent.height
                  radius: parent.radius
                  color: pip.entry ? pip.state.colorForEntry(pip.entry, pip.theme.popups.text, pip.theme.popups.background) : "white"
                }
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
}
