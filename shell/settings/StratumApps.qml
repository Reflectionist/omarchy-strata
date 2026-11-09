import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A stratum's apps: which ones open here (by type, exact app, or pattern),
// whether the view follows them, and rules learned from your own moves.
ColumnLayout {
  id: apps
  property var win: null
  property string key: ""
  readonly property var theme: Commons.ShellColor || Commons.Color
  spacing: 2

  readonly property var match: win && key !== "" ? win.sget(key, "match", { types: [], apps: [] }) : ({ types: [], apps: [] })
  readonly property var categories: ["TerminalEmulator", "IDE", "TextEditor", "Development", "WebBrowser", "InstantMessaging", "Chat",
                                     "Email", "Office", "Viewer", "AudioVideo", "Audio", "Video", "Player", "Graphics", "2DGraphics",
                                     "3DGraphics", "Game", "FileManager", "Utility", "System", "Network"]

  function escapeRe(s) { return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&") }
  function setMatch(field, list) {
    var m = JSON.parse(JSON.stringify(match))
    m[field] = list
    win.sset(key, "match", m)
  }
  function toggleType(t) {
    var list = (match.types || []).slice()
    var i = list.indexOf(t)
    if (i >= 0) list.splice(i, 1); else list.push(t)
    setMatch("types", list)
  }
  function addApp(pattern) {
    if (!pattern) return
    var list = (match.apps || []).slice()
    if (list.indexOf(pattern) < 0) list.push(pattern)
    setMatch("apps", list)
  }
  function removeApp(i) {
    var list = (match.apps || []).slice()
    list.splice(i, 1)
    setMatch("apps", list)
  }

  // Learned rules for this stratum, and suggestions to send apps here.
  readonly property var learnedAll: win ? win.get(["learned"], []) : []
  property var suggestions: []
  FileView {
    id: suggestFile
    path: Quickshell.env("HOME") + "/.local/state/strata/suggestions.jsonl"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var out = [], seen = {}
      var lines = String(text() || "").split("\n")
      for (var i = 0; i < lines.length; i++) {
        try {
          var s = JSON.parse(lines[i])
          var k = s.class + "|" + s.title + "|" + s.to
          if (!seen[k]) { seen[k] = true; out.push(s) }
        } catch (e) {}
      }
      apps.suggestions = out.reverse()
    }
  }
  readonly property var mySuggestions: suggestions.filter(function(s) { return s.to === apps.key })
  function dropSuggestion(s) {
    var keep = suggestions.filter(function(x) { return !(x.class === s.class && x.title === s.title && x.to === s.to) })
    suggestFile.setText(keep.slice().reverse().map(function(x) { return JSON.stringify(x) }).join("\n") + (keep.length ? "\n" : ""))
  }
  function approve(s, titlePattern) {
    var list = learnedAll.slice()
    list.push({ class: "^" + escapeRe(s.class) + "$", title: titlePattern, stratum: s.to })
    win.set(["learned"], list)
    dropSuggestion(s)
  }
  function removeLearned(rule) {
    win.set(["learned"], learnedAll.filter(function(r) { return !(r.class === rule.class && r.title === rule.title && r.stratum === rule.stratum) }))
  }

  PanelSectionHeader { text: "Apps"; Layout.topMargin: 14 }

  SettingRow {
    label: "Follow routed windows"
    description: "Switch to this stratum when a window routed here opens."
    ToggleSwitch { checked: apps.win ? apps.win.sget(apps.key, "follow", true) : true; onToggled: apps.win.sset(apps.key, "follow", !checked) }
  }

  Text {
    Layout.fillWidth: true
    Layout.topMargin: 8
    text: "App categories"
    color: apps.theme.popups.text; font.family: Style.font.family; font.pixelSize: 14
  }
  Flow {
    Layout.fillWidth: true
    spacing: 6
    Repeater {
      model: apps.categories
      delegate: Button {
        required property var modelData
        text: modelData
        selected: (apps.match.types || []).indexOf(modelData) >= 0
        bordered: true
        onClicked: apps.toggleType(modelData)
      }
    }
  }

  Text {
    Layout.fillWidth: true
    Layout.topMargin: 12
    text: "Apps"
    color: apps.theme.popups.text; font.family: Style.font.family; font.pixelSize: 14
  }
  Repeater {
    model: apps.match.apps || []
    delegate: RowLayout {
      required property var modelData
      required property int index
      Layout.fillWidth: true
      Text { text: modelData; color: apps.theme.popups.text; font.family: Style.font.family; font.pixelSize: 12; Layout.fillWidth: true; elide: Text.ElideMiddle }
      Button { iconText: "󰅖"; tooltipText: "Remove"; onClicked: apps.removeApp(index) }
    }
  }
  SettingRow {
    label: "Add an installed app"
    SearchableDropdown {
      width: parent.width
      triggerLabel: "Choose"
      options: apps.win && apps.win.service ? apps.win.service.appIndex.map(function(a) { return { value: a.class, label: a.name + "  (" + a.class + ")" } }) : []
      onChanged: function(v) { apps.addApp("^" + apps.escapeRe(v) + "$") }
    }
  }
  SettingRow {
    label: "Add an open window"
    SearchableDropdown {
      width: parent.width
      triggerLabel: "Choose"
      options: {
        var out = [], seen = {}
        var vals = Hyprland.toplevels.values
        for (var i = 0; i < vals.length; i++) {
          var t = vals[i]
          var c = t.wayland && t.wayland.appId ? String(t.wayland.appId) : (t.lastIpcObject && t.lastIpcObject.class ? String(t.lastIpcObject.class) : "")
          if (c === "" || seen[c]) continue
          seen[c] = true
          out.push({ value: c, label: c + "  —  " + t.title })
        }
        return out
      }
      onChanged: function(v) { apps.addApp("^" + apps.escapeRe(v) + "$") }
    }
  }
  SettingRow {
    label: "Add a pattern"
    description: "Window class regex."
    TextField { width: parent.width; placeholderText: "^(app|other-app)$"; onAccepted: { apps.addApp(text); text = "" } }
  }

  Text {
    Layout.fillWidth: true
    Layout.topMargin: 12
    visible: apps.mySuggestions.length > 0 || apps.learnedAll.some(function(r) { return r.stratum === apps.key })
    text: "Suggestions"
    color: apps.theme.popups.text; font.family: Style.font.family; font.pixelSize: 14
  }
  Repeater {
    model: apps.mySuggestions
    delegate: RowLayout {
      required property var modelData
      Layout.fillWidth: true
      spacing: 8
      Text { text: modelData.class; color: apps.theme.popups.text; font.family: Style.font.family; font.pixelSize: 12; Layout.preferredWidth: 140; elide: Text.ElideRight }
      TextField { id: titleRe; Layout.fillWidth: true; text: "^" + apps.escapeRe(modelData.title) + "$" }
      Button { text: "Add rule"; bordered: true; onClicked: apps.approve(modelData, titleRe.text) }
      Button { iconText: "󰅖"; tooltipText: "Dismiss"; onClicked: apps.dropSuggestion(modelData) }
    }
  }
  Repeater {
    model: apps.learnedAll.filter(function(r) { return r.stratum === apps.key })
    delegate: RowLayout {
      required property var modelData
      Layout.fillWidth: true
      Text { text: modelData.class + (modelData.title ? "   ·   " + modelData.title : ""); color: apps.theme.popups.text; font.family: Style.font.family; font.pixelSize: 12; Layout.fillWidth: true; elide: Text.ElideMiddle }
      Button { iconText: "󰅖"; tooltipText: "Forget"; onClicked: apps.removeLearned(modelData) }
    }
  }
}
