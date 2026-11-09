import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "settings"

// Strata settings: an overlay window, closed with Escape or a click outside. Each stratum's options live on its own page under Strata;
// the other sections hold what applies to all of them.
//
// Only what you change is written to ~/.config/strata/strata.json (the rest
// keeps following the plugin's config/defaults.json), and Hyprland re-reads it
// a moment later.
PanelWindow {
  id: win
  property var service: null
  readonly property var theme: Commons.ShellColor || Commons.Color
  readonly property var state: service ? service.stateObject : null
  readonly property var cfg: state ? state.config : ({})

  visible: true
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "strata-settings"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  // ── Model ──────────────────────────────────────────────────────────────
  function get(path, fallback) {
    var v = cfg
    for (var i = 0; i < path.length; i++) {
      if (v === null || v === undefined || typeof v !== "object") return fallback
      v = v[path[i]]
    }
    return v === undefined || v === null ? fallback : v
  }

  function set(path, value) {
    var user = JSON.parse(JSON.stringify(state.user || {}))
    if (!user.version) user.version = 1
    var o = user
    for (var i = 0; i < path.length - 1; i++) {
      if (o[path[i]] === undefined || o[path[i]] === null || typeof o[path[i]] !== "object" || Array.isArray(o[path[i]])) o[path[i]] = {}
      o = o[path[i]]
    }
    o[path[path.length - 1]] = value
    state.writeUser(user)
    saved.restart()
    reload.restart()
  }

  // A stratum's own setting (the free strata's live under "free").
  function sget(key, field, fallback) { return key === "@free" ? get(["free", field], fallback) : get(["strata", key, field], fallback) }
  function sset(key, field, value) { if (key === "@free") set(["free", field], value); else set(["strata", key, field], value) }
  function pget(key, field, fallback) { var p = sget(key, "profile", {}); return p[field] !== undefined && p[field] !== null ? p[field] : fallback }
  function pset(key, field, value) {
    var p = JSON.parse(JSON.stringify(sget(key, "profile", {})))
    if (value === null) delete p[field]; else p[field] = value
    sset(key, "profile", p)
  }

  readonly property var stackKeys: cfg.stack || []
  function nameOf(key) { return key === "@free" ? get(["free", "name"], "Free") + " strata" : sget(key, "name", key) }
  function iconOf(key, active) { return key === "@free" ? (active ? "󰎤" : "󰎦") : (active ? sget(key, "iconActive", sget(key, "icon", "󱓻")) : sget(key, "icon", "󱓼")) }
  // A stratum's colour, from its own theme like everywhere else.
  function tintKey(key) {
    if (!state) return theme.popups.text
    var entry = key === "@free" ? { kind: "free", accent: get(["free", "accent"], "accent"), stratum: cfg.free || {} }
                                : { kind: "themed", accent: sget(key, "accent", "accent"), stratum: (cfg.strata || {})[key] || {} }
    return state.colorForEntry(entry, theme.popups.text, theme.popups.background)
  }

  readonly property var roles: [{ value: "accent", label: "Theme accent" }, { value: "foreground", label: "Text color" },
                                "red", "orange", "yellow", "green", "cyan", "blue", "magenta",
                                "bright_red", "bright_yellow", "bright_green", "bright_cyan", "bright_blue", "bright_magenta"]

  // "strata:<key>" opens that stratum's page.
  readonly property string asked: service ? service.settingsPage : ""
  property string selected: asked.indexOf("strata:") === 0 ? asked.slice(7) : (stackKeys.length > 0 ? stackKeys[0] : "")

  Timer { id: reload; interval: 700; onTriggered: Quickshell.execDetached(["hyprctl", "reload"]) }
  Timer { id: saved; interval: 1600 }

  // ── Frame ──────────────────────────────────────────────────────────────
  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.45)
  }

  MouseArea {
    anchors.fill: parent
    onClicked: if (win.service) win.service.hideSettings()
  }

  Rectangle {
    id: card
    anchors.centerIn: parent
    width: Math.min(parent.width * 0.92, 1180)
    height: Math.min(parent.height * 0.92, 840)
    radius: Math.max(4, Style.cornerRadius)
    color: win.theme.popups.background
    border.color: win.theme.popups.border
    border.width: 1
    focus: true
    Keys.onEscapePressed: if (win.service) win.service.hideSettings()

    MouseArea { anchors.fill: parent }

    RowLayout {
      anchors.fill: parent
      spacing: 0

      Rectangle {
        Layout.fillHeight: true
        Layout.preferredWidth: 210
        color: Qt.rgba(win.theme.popups.text.r, win.theme.popups.text.g, win.theme.popups.text.b, 0.03)
        radius: card.radius

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: 16
          spacing: 4

          RowLayout {
            spacing: 10
            Layout.bottomMargin: 14
            Text {
              text: win.state ? win.state.current.iconActive : "󱓻"
              color: win.state ? win.state.colorForEntry(win.state.current, win.theme.popups.text, win.theme.popups.background) : win.theme.popups.text
              font.family: Style.font.family
              font.pixelSize: 24
            }
            Text { text: "Strata"; color: win.theme.popups.text; font.family: Style.font.family; font.pixelSize: 20; font.bold: true }
          }

          Repeater {
            model: [
              { page: "strata", icon: "󰌨", label: "Strata" },
              { page: "navigation", icon: "󰆾", label: "Navigation" },
              { page: "cross", icon: "󰕰", label: "Preview cross" },
              { page: "overview", icon: "󰕮", label: "Overview" },
              { page: "glyph", icon: "󱓻", label: "Bar widget" },
              { page: "wallpaper", icon: "󰸉", label: "Themes & wallpapers" },
              { page: "pip", icon: "󰗢", label: "Picture in picture" },
              { page: "setup", icon: "󰋼", label: "Setup" }
            ]
            delegate: Rectangle {
              required property var modelData
              readonly property bool here: pages.page === modelData.page
              Layout.fillWidth: true
              height: 36
              radius: 4
              color: here ? Qt.rgba(win.theme.popups.text.r, win.theme.popups.text.g, win.theme.popups.text.b, 0.09)
                          : (navHover.containsMouse ? Qt.rgba(win.theme.popups.text.r, win.theme.popups.text.g, win.theme.popups.text.b, 0.05) : "transparent")
              Row {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10
                Text { text: modelData.icon; color: here ? win.theme.accent : win.theme.muted; font.family: Style.font.family; font.pixelSize: 16 }
                Text { text: modelData.label; color: win.theme.popups.text; font.family: Style.font.family; font.pixelSize: 13; font.bold: here }
              }
              MouseArea { id: navHover; anchors.fill: parent; hoverEnabled: true; onClicked: pages.page = modelData.page }
            }
          }

          Item { Layout.fillHeight: true }

          Text {
            Layout.fillWidth: true
            text: saved.running ? "Saved" : "~/.config/strata/strata.json"
            color: saved.running ? win.theme.accent : win.theme.muted
            font.family: Style.font.family
            font.pixelSize: 10
            wrapMode: Text.WrapAnywhere
          }
        }
      }

      Loader {
        id: pages
        property string page: win.asked !== "" ? win.asked.split(":")[0] : "strata"
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.margins: 24
        source: {
          var map = { strata: "PageStrata", navigation: "PageNavigation", cross: "PageCross", overview: "PageOverview",
                      glyph: "PageGlyph", wallpaper: "PageWallpaper", pip: "PagePip", setup: "PageSetup" }
          return Qt.resolvedUrl("settings/" + (map[page] || "PageStrata") + ".qml")
        }
        onLoaded: item.win = win
      }
    }
  }
}
