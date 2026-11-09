import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
// A bare `Color` is QtQuick's own value type on Qt 6.12, not the theme.
import qs.Commons as Commons
import "Palette.js" as Palette
import "Stack.js" as Stack

// Where you are in Strata, as the service and the bar glyph both need it:
// the config, the theme palette, the stack and the stratum you're on. Each
// keeps its own copy (a replacement bar may give widgets no way to reach the
// service), so this reads only files and Hyprland's own state.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/strata"
  // The plugin folder (this file is in its shell/), as a plain path.
  readonly property string pluginDir: String(Qt.resolvedUrl("..")).replace(/^[a-z]+:\/\//, "").replace(/\/$/, "")
  readonly property var theme: Commons.ShellColor || Commons.Color

  // ── Config ────────────────────────────────────────────────────────────
  property var defaults: ({})
  property var user: ({})
  readonly property var config: Stack.merge(defaults, user)

  // A Strata event's data: inline JSON, or "@<path>" to a file in the
  // runtime dir when it's too big for one socket event (1024 bytes).
  function eventJson(data) {
    var d = String(data || "")
    if (d.charAt(0) !== "@") return parseJson(d)
    // A fresh reader each time: a reused FileView keeps serving what it read first.
    var reader = Qt.createQmlObject('import Quickshell.Io; FileView { blockLoading: true; printErrors: false }', root)
    reader.path = d.slice(1)
    var text = reader.text()
    reader.destroy()
    return parseJson(text)
  }

  function parseJson(text) {
    try { return JSON.parse(String(text || "{}")) } catch (e) { console.warn("strata: bad JSON:", e); return null }
  }

  FileView {
    id: defaultsFile
    path: root.pluginDir + "/config/defaults.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { var v = root.parseJson(text()); if (v) root.defaults = v }
  }

  // Save the user config (strata.json); the watch reloads it everywhere.
  function writeUser(obj) {
    userFile.setText(JSON.stringify(obj, null, 2) + "\n")
    root.user = obj
  }

  FileView {
    id: userFile
    path: root.configDir + "/strata.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { var v = root.parseJson(text()); if (v) root.user = v }
  }

  // ── Palette ───────────────────────────────────────────────────────────
  property var palette: ({})

  FileView {
    id: colorsFile
    path: root.home + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.palette = Palette.parse(text())
    onFileChanged: reload()
  }

  // A theme switch replaces the whole theme directory, which can strand the
  // watch; the theme singleton changing is the reliable signal.
  Connections {
    target: root.theme
    function onForegroundChanged() { colorsFile.reload() }
    function onBackgroundChanged() { colorsFile.reload() }
    function onAccentChanged() { colorsFile.reload() }
  }

  // Each stratum is coloured from its own theme (or the base theme), so its
  // colour doesn't change as you move between strata with other themes.
  // Palettes are read once per theme (a plain cache, no bindings fire).
  property var paletteCache: ({})
  function paletteOf(theme) {
    if (!theme) return root.palette
    if (root.paletteCache[theme]) return root.paletteCache[theme]
    var omarchy = Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
    var paths = [root.home + "/.cache/strata/themes/" + theme + "/colors.toml",
                 root.home + "/.config/omarchy/themes/" + theme + "/colors.toml",
                 omarchy + "/themes/" + theme + "/colors.toml"]
    for (var i = 0; i < paths.length; i++) {
      var reader = Qt.createQmlObject('import Quickshell.Io; FileView { blockLoading: true; printErrors: false }', root)
      reader.path = paths[i]
      var text = reader.text()
      reader.destroy()
      if (text && text.length > 0) {
        root.paletteCache[theme] = Palette.parse(text)
        return root.paletteCache[theme]
      }
    }
    return root.palette
  }
  function themeOf(entry) {
    var cfg = root.config || {}
    // Theme switching off: every stratum wears the current theme.
    if ((cfg.themes || {}).switching === false) return ""
    var own = entry && entry.kind === "free" ? (cfg.free || {}).theme : (entry && entry.stratum ? entry.stratum.theme : null)
    return own || (cfg.themes || {}).base || ""
  }
  // A stratum's colour (its accent role, from its own theme's palette).
  function colorForEntry(entry, text, back) {
    if (!entry) return text !== undefined ? text : root.theme.bar.text
    return Palette.role(root.paletteOf(root.themeOf(entry)), entry.accent || "accent",
                        text !== undefined ? text : root.theme.bar.text,
                        back !== undefined ? back : root.theme.bar.background)
  }

  // A role ("blue", "bright_red", "#rrggbb"...) as a colour that reads on a
  // surface with this text colour and background.
  function colorFor(roleName, text, back) {
    return Palette.role(root.palette, roleName,
                        text !== undefined ? text : root.theme.bar.text,
                        back !== undefined ? back : root.theme.bar.background)
  }

  // ── Where you are ─────────────────────────────────────────────────────
  readonly property var focusedWs: Hyprland.focusedWorkspace
  readonly property int focusedId: focusedWs ? focusedWs.id : 0
  readonly property string focusedName: focusedWs ? String(focusedWs.name) : ""

  readonly property var workspaceList: {
    var vals = Hyprland.workspaces.values
    var out = []
    for (var i = 0; i < vals.length; i++)
      out.push({ id: vals[i].id, name: String(vals[i].name), windows: vals[i].toplevels.values.length })
    return out
  }

  readonly property var stack: Stack.entries(root.config, root.workspaceList, root.focusedId)
  readonly property int currentIndex: Stack.indexOf(root.stack, root.focusedId, root.focusedName)
  // Off the stack (special workspaces, 11+ when fixed): a plain entry.
  readonly property var current: currentIndex >= 0 ? stack[currentIndex] : {
    id: "ws:" + root.focusedName, kind: "other", name: "Workspace " + root.focusedName,
    icon: "󱓼", iconActive: "󱓻", accent: "foreground", stratum: ({})
  }
  readonly property int currentWindows: {
    var list = root.workspaceList
    for (var i = 0; i < list.length; i++) if (list[i].id === root.focusedId) return list[i].windows
    return 0
  }

  // Which way the last move went (+1 down the stack, -1 up), for animations.
  property int travel: 0
  property int lastIndex: -1
  onCurrentIndexChanged: {
    if (lastIndex >= 0 && currentIndex >= 0 && currentIndex !== lastIndex) {
      var n = stack.length
      var d = currentIndex - lastIndex
      // A wrap (bottom -> top) still reads as travelling down.
      if (Math.abs(d) > n / 2) d = -d
      travel = d > 0 ? 1 : -1
    } else
      travel = 0
    lastIndex = currentIndex
  }

  // ── The grid's own state (hypr-strata posts it on every move) ─────────
  // { ws, camera, x, w, blank, lo, hi } in screen widths.
  property var view: ({})
  signal moved()

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "strata") return
      var v = root.eventJson(event.data)
      if (v) { root.view = v; root.moved() }
    }
  }

}
