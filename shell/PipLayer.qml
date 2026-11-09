import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// Picture in picture, the shell's half. When you leave a stratum with PiP on
// while one of its players is playing, the player's window goes along
// (lua/strata.lua pip_out does the moving). While it's out, a slim seek bar
// rides under it, it keeps out of the way if asked to, and where you leave
// it is remembered per app.
Item {
  id: pip
  required property var service
  readonly property var state: service.stateObject
  readonly property var theme: Commons.ShellColor || Commons.Color
  readonly property var pc: state.config && state.config.pip ? state.config.pip : ({})
  readonly property string stateFile: state.home + "/.local/state/strata/pip.json"

  // ── Leaving a stratum ─────────────────────────────────────────────────
  property var lastEntry: null
  property int lastWsId: 0

  Connections {
    target: pip.state
    function onCurrentIndexChanged() { pip.leaving() }
  }
  // Where you are when the shell starts, so the first move away counts.
  Component.onCompleted: { lastEntry = state.current; lastWsId = state.focusedId }
  // Quickshell finds the players only once something asks: ask now, not as
  // you leave (the list would still be empty then).
  readonly property int players: Mpris.players.values.length

  function classOf(t) {
    if (t.wayland && t.wayland.appId) return String(t.wayland.appId)
    return t.lastIpcObject && t.lastIpcObject.class ? String(t.lastIpcObject.class) : ""
  }

  // A playing player that belongs to this window's app.
  function playerFor(cls) {
    var c = cls.toLowerCase()
    var chrome = c === "helium" || c.indexOf("chrom") >= 0 || c.indexOf("chrome-") === 0 || c === "brave-browser"
    var list = Mpris.players.values
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (!p.isPlaying) continue
      var id = String(p.identity || "").toLowerCase(), de = String(p.desktopEntry || "").toLowerCase(), bus = String(p.dbusName || "").toLowerCase()
      if (de === c || id === c || (de !== "" && c.indexOf(de) >= 0) || (id !== "" && c.indexOf(id) >= 0)) return p
      if (chrome && (bus.indexOf("chrom") >= 0 || id.indexOf("chrom") >= 0 || id.indexOf("helium") >= 0 || de.indexOf("helium") >= 0)) return p
    }
    return null
  }

  function leaving() {
    // The free strata can renumber the stack without you moving.
    if (state.focusedId === lastWsId) { lastEntry = state.current; return }
    var prev = lastEntry, prevWs = lastWsId
    lastEntry = state.current
    lastWsId = state.focusedId
    if (!prev || prev.kind !== "themed" || (active !== "" && exists(active))) return
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
      var player = playerFor(cls)
      if (!player) continue
      var addr = String(t.address)
      if (addr.indexOf("0x") !== 0) addr = "0x" + addr
      pip.player = player
      Quickshell.execDetached(["hyprctl", "eval", 'require("hypr.strata").pip_out(' + JSON.stringify(addr) + ', ' + JSON.stringify(prev.selector) + ')'])
      return
    }
  }

  // ── While it's out ────────────────────────────────────────────────────
  property string active: ""      // its address while out
  property string activeClass: ""
  property var player: null
  property rect box: Qt.rect(0, 0, 0, 0)

  function exists(addr) {
    var a = addr.replace(/^0x/, "")
    var tops = Hyprland.toplevels.values
    for (var i = 0; i < tops.length; i++) if (String(tops[i].address).replace(/^0x/, "") === a) return true
    return false
  }

  // It was closed while out.
  function gone() {
    active = ""
    activeClass = ""
    player = null
    box = Qt.rect(0, 0, 0, 0)
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "closewindow") {
        if (pip.active !== "" && String(event.data).replace(/^0x/, "") === pip.active.replace(/^0x/, "")) pip.gone()
        return
      }
      if (event.name !== "custom" || String(event.data).indexOf("strata-pip>>") !== 0) return
      var v = pip.state.parseJson(String(event.data).slice(12))
      if (!v) return
      if (v.open) { pip.active = v.a; pip.activeClass = v["class"] || "" }
      else if (v.a === pip.active) { pip.remember(); pip.active = ""; pip.player = null }
    }
  }

  function remember() {
    if (activeClass === "" || box.width <= 0) return
    var all = {}
    try { all = JSON.parse(rememberFile.text() || "{}") } catch (e) {}
    all[activeClass] = { x: box.x, y: box.y, w: box.width, h: box.height }
    rememberFile.setText(JSON.stringify(all) + "\n")
  }
  FileView { id: rememberFile; path: pip.stateFile; blockLoading: true; printErrors: false }

  Timer {
    interval: 400
    repeat: true
    running: pip.active !== ""
    property int misses: 0
    onTriggered: {
      Hyprland.refreshToplevels()
      var tops = Hyprland.toplevels.values
      var a = pip.active.replace(/^0x/, "")
      var found = false
      for (var i = 0; i < tops.length; i++) {
        if (String(tops[i].address).replace(/^0x/, "") !== a) continue
        found = true
        var o = tops[i].lastIpcObject || {}
        if (o.at && o.size) pip.box = Qt.rect(o.at[0], o.at[1], o.size[0], o.size[1])
      }
      // Missed the close event (the shell restarted, say).
      misses = found ? 0 : misses + 1
      if (misses >= 3) { misses = 0; pip.gone(); return }
      if (pip.player) pip.player.positionChanged()
      pip.keepAway()
    }
  }

  // Keep out of the way: when the window you're using overlaps it, go to
  // the other side. Once per window: one wide enough to cover both sides
  // would otherwise send it back and forth for as long as it has focus.
  property string corner: pc.corner || "bottom-right"
  property string avoided: ""
  function keepAway() {
    if (!pc.avoid_focus || box.width <= 0) return
    var t = Hyprland.activeToplevel
    var o = t && t.lastIpcObject ? t.lastIpcObject : null
    var addr = t ? String(t.address).replace(/^0x/, "") : ""
    if (!o || !o.at || addr === active.replace(/^0x/, "")) return
    var overlap = !(o.at[0] + o.size[0] <= box.x || box.x + box.width <= o.at[0] || o.at[1] + o.size[1] <= box.y || box.y + box.height <= o.at[1])
    if (!overlap) { if (avoided === addr) avoided = ""; return }
    if (avoided === addr) return
    avoided = addr
    corner = corner.indexOf("right") >= 0 ? corner.replace("right", "left") : corner.replace("left", "right")
    Quickshell.execDetached(["hyprctl", "eval", 'require("hypr.strata").pip_corner(' + JSON.stringify(active) + ', ' + JSON.stringify(corner) + ')'])
  }

  // The seek bar, along the bottom edge of the PiP window.
  PanelWindow {
    visible: pip.active !== "" && pip.pc.seek_bar !== false && pip.player !== null && pip.box.width > 0
    anchors { top: true; left: true }
    margins { left: pip.box.x + 6; top: pip.box.y + pip.box.height - 14 }
    implicitWidth: Math.max(10, pip.box.width - 12)
    implicitHeight: 10
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "strata-pip"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    readonly property real frac: pip.player && pip.player.length > 0 ? Math.max(0, Math.min(1, pip.player.position / pip.player.length)) : 0

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      height: bar.containsMouse ? 6 : 3
      radius: height / 2
      color: Qt.rgba(0, 0, 0, 0.45)
      Behavior on height { NumberAnimation { duration: 120 } }
      Rectangle {
        width: parent.width * parent.parent.frac
        height: parent.height
        radius: parent.radius
        color: pip.state.colorForEntry(pip.state.current, pip.theme.popups.text, pip.theme.popups.background)
      }
    }
    MouseArea {
      id: bar
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function(m) {
        if (pip.player && pip.player.canSeek && pip.player.length > 0) pip.player.position = (m.x / width) * pip.player.length
      }
    }
  }
}
