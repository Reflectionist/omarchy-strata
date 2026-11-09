import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
// A bare `Color` is QtQuick's own value type on Qt 6.12, not the theme.
import qs.Commons as Commons
import "Palette.js" as Palette
import "Stack.js" as Stack

// Strata's shell side: what stratum you're on, its colours, the stack, and
// the windows Strata draws (settings, and later the cross and overview).
// The grid itself lives in Hyprland (the hypr-strata plugin and lua/strata.lua);
// this service reads ~/.config/strata/strata.json like they do and talks to
// them through hyprctl.
Item {
  id: root
  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/strata"
  readonly property var theme: Commons.ShellColor || Commons.Color

  StrataState { id: state }
  readonly property alias stateObject: state
  readonly property alias config: state.config
  readonly property alias palette: state.palette
  readonly property alias stack: state.stack
  readonly property alias currentIndex: state.currentIndex
  readonly property alias current: state.current
  readonly property alias currentWindows: state.currentWindows
  readonly property alias travel: state.travel
  readonly property alias view: state.view
  readonly property alias workspaceList: state.workspaceList
  function colorFor(roleName, text, back) { return state.colorFor(roleName, text, back) }

  // ── Overlays (cross frames and labels, reticle, ruler) ────────────────
  Overlays {
    service: root
  }

  // ── Overview (labels and input; Hyprland draws the grid) ──────────────
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "strata-overview-drag") {
        var d = state.eventJson(event.data)
        if (d) overviewLayer.receiveDrag(d)
        return
      }
      if (event.name !== "strata-overview") return
      var v = state.eventJson(event.data)
      if (v) overviewLayer.receive(v)
    }
  }

  OverviewLayer {
    id: overviewLayer
    service: root
  }
  readonly property bool overviewShown: overviewLayer.visible

  PipLayer {
    service: root
  }

  // Move the stratum at stack position `from` to position `to` (positions as
  // in the stack list, free strata moving as one block), then let Hyprland
  // re-read the stack.
  function moveStratum(from, to) {
    var list = state.stack
    if (!list[from] || !list[to]) return
    var key = list[from].key, target = list[to].key
    if (key === target) return
    var order = (state.config.stack || []).slice()
    var i = order.indexOf(key)
    if (i < 0) return
    order.splice(i, 1)
    var j = order.indexOf(target)
    if (j < 0) return
    order.splice(to > from ? j + 1 : j, 0, key)
    var user = JSON.parse(JSON.stringify(state.user || {}))
    user.stack = order
    state.writeUser(user)
    reloadHyprland.restart()
  }

  Timer {
    id: reloadHyprland
    interval: 300
    onTriggered: Quickshell.execDetached(["hyprctl", "reload"])
  }

  // ── App index for routing by type (lua/strata.lua reads it) ─────────
  // class -> desktop-entry categories, plus what the settings' app picker shows.
  readonly property var appIndex: {
    var vals = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < vals.length; i++) {
      var e = vals[i]
      if (e.noDisplay) continue
      var id = String(e.id || "").replace(/\.desktop$/, "")
      out.push({ id: id, name: String(e.name || id), class: String(e.startupClass || id), categories: e.categories || [], icon: String(e.icon || ""), exec: String(e.execString || "") })
    }
    out.sort(function(a, b) { return a.name.localeCompare(b.name) })
    return out
  }
  onAppIndexChanged: appIndexWrite.restart()
  Timer {
    id: appIndexWrite
    interval: 1500
    onTriggered: appIndexFile.setText(JSON.stringify(root.appIndex) + "\n")
  }
  FileView {
    id: appIndexFile
    path: state.home + "/.cache/strata/apps.json"
    printErrors: false
  }

  // ── Wallpaper picks (Omarchy's picker) go to the stratum you're on ────
  // The current-background link changes when you pick one; strata-capture
  // saves it (and leaves Strata's own theme switches alone).
  property string bgTarget: ""
  Process {
    id: readBg
    command: ["readlink", "-f", state.home + "/.local/state/omarchy/current/background"]
    stdout: StdioCollector {
      onStreamFinished: {
        var t = String(text).trim()
        if (t === "") return
        if (root.bgTarget !== "" && t !== root.bgTarget)
          Quickshell.execDetached([state.pluginDir + "/bin/strata-capture", "wallpaper", t, root.bgTarget])
        root.bgTarget = t
      }
    }
  }
  Timer {
    interval: 2000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: readBg.running = true
  }

  // ── Settings window ───────────────────────────────────────────────────
  property bool settingsOpen: false
  property string settingsPage: ""
  function showSettings(page) { settingsPage = page || settingsPage; settingsOpen = true }
  function hideSettings() { settingsOpen = false }
  function toggleSettings() { settingsOpen = !settingsOpen }

  Loader {
    id: settingsLoader
    active: root.settingsOpen
    source: Qt.resolvedUrl("SettingsWindow.qml")
    onLoaded: item.service = root
  }

  IpcHandler {
    target: "strata"
    function settings(): void { root.toggleSettings() }
    function showSettings(page: string): void { root.showSettings(page) }
    function hideSettings(): void { root.hideSettings() }
    // Open on `page`, or close if open (the bar glyph's left click).
    function toggleAt(page: string): void { if (root.settingsOpen) root.hideSettings(); else root.showSettings(page) }
    function current(): string { return JSON.stringify({ id: root.current.id, name: root.current.name, index: root.currentIndex, of: root.stack.length }) }
    function stackJson(): string { return JSON.stringify(root.stack.map(function(e) { return { id: e.id, name: e.name, selector: e.selector } })) }
  }
}
