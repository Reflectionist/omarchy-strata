import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The stack on the left; everything about the selected stratum on the right.
Item {
  id: page
  property var win: null
  readonly property var theme: Commons.ShellColor || Commons.Color
  readonly property string key: win ? win.selected : ""
  readonly property bool free: key === "@free"
  readonly property bool themed: key !== "" && !free
  readonly property bool switching: win ? win.get(["themes", "switching"], true) !== false : true

  function move(k, dir) {
    var order = win.stackKeys.slice()
    var i = order.indexOf(k), j = i + dir
    if (i < 0 || j < 0 || j >= order.length) return
    order.splice(i, 1)
    order.splice(j, 0, k)
    win.set(["stack"], order)
  }

  function addStratum() {
    var n = 1
    while (win.get(["strata", "custom-" + n], null) !== null) n++
    var id = "custom-" + n
    win.set(["strata", id], {
      name: "Stratum " + n, icon: "󱓼", iconActive: "󱓻", accent: "accent",
      workspace: "name:" + id, hotkey: "", follow: true, primary: "",
      match: { types: [], apps: [], titles: [] }, profile: {}, theme: null, wallpaper: null,
      pip: { enabled: false, apps: [] }
    })
    var order = win.stackKeys.slice()
    var f = order.indexOf("@free")
    order.splice(f < 0 ? order.length : f, 0, id)
    win.set(["stack"], order)
    win.selected = id
  }

  function removeStratum(k) {
    var order = win.stackKeys.slice()
    order.splice(order.indexOf(k), 1)
    win.set(["stack"], order)
    if (k.indexOf("custom-") === 0) win.set(["strata", k], null)
    win.selected = order[0] || ""
  }

  // Themes to choose from
  property var themes: []
  Process {
    running: true
    command: ["omarchy-theme-list"]
    stdout: StdioCollector {
      onStreamFinished: page.themes = text.split("\n").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
    }
  }
  readonly property var themeOptions: [{ value: "", label: "Base theme" }].concat(themes.map(function(n) {
    return { value: String(n).toLowerCase().replace(/<[^>]+>/g, "").trim().replace(/ /g, "-"), label: n }
  }))

  // Audio outputs
  property var sinks: []
  Process {
    running: true
    command: ["pactl", "-f", "json", "list", "sinks"]
    stdout: StdioCollector {
      onStreamFinished: { try { page.sinks = JSON.parse(text).map(function(s) { return { value: s.name, label: s.description || s.name } }) } catch (e) {} }
    }
  }

  function look(k, d) { var l = win.pget(key, "look", {}); return l[k] !== undefined ? l[k] : d }
  function setLook(k, v) { var l = JSON.parse(JSON.stringify(win.pget(key, "look", {}))); if (v === null) delete l[k]; else l[k] = v; win.pset(key, "look", l) }
  function wdef(k, d) { var w = win.pget(key, "windows", {}); return w[k] !== undefined ? w[k] : d }
  function setWdef(k, v) { var w = JSON.parse(JSON.stringify(win.pget(key, "windows", {}))); if (v === null) delete w[k]; else w[k] = v; win.pset(key, "windows", w) }
  function pipConf() { return win.sget(key, "pip", { enabled: false, apps: [] }) || { enabled: false, apps: [] } }
  function setPip(field, v) { var p = JSON.parse(JSON.stringify(pipConf())); p[field] = v; win.sset(key, "pip", p) }

  RowLayout {
    anchors.fill: parent
    spacing: 24

    // ── The stack ────────────────────────────────────────────────────────
    ColumnLayout {
      Layout.preferredWidth: 250
      Layout.maximumWidth: 250
      Layout.fillWidth: false
      Layout.fillHeight: true
      spacing: 6

      Text { text: "Stack"; color: page.theme.popups.text; font.family: Style.font.family; font.pixelSize: 16; font.bold: true }
      Text {
        Layout.fillWidth: true
        text: "Strata from top to bottom. Free strata are numbered workspaces, created on demand."
        color: page.theme.muted; font.family: Style.font.family; font.pixelSize: 11; wrapMode: Text.WordWrap
      }

      ListView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: 2
        model: page.win ? page.win.stackKeys : []
        delegate: Rectangle {
          required property var modelData
          required property int index
          readonly property bool here: page.key === modelData
          width: ListView.view.width
          height: 38
          radius: 4
          color: here ? Qt.rgba(page.theme.popups.text.r, page.theme.popups.text.g, page.theme.popups.text.b, 0.09) : "transparent"
          MouseArea { anchors.fill: parent; onClicked: page.win.selected = modelData }
          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 4
            spacing: 10
            Text { text: page.win.iconOf(modelData, here); color: page.win.tintKey(modelData); font.family: Style.font.family; font.pixelSize: 18 }
            Text { text: page.win.nameOf(modelData); color: page.theme.popups.text; font.family: Style.font.family; font.pixelSize: 13; Layout.fillWidth: true; elide: Text.ElideRight }
            Text {
              readonly property string hk: page.win.sget(modelData, "hotkey", "")
              text: hk !== "" ? "SUPER+" + (hk === "grave" ? "`" : hk) : ""
              color: page.theme.muted; font.family: Style.font.family; font.pixelSize: 10
            }
            Button { iconText: "󰁝"; enabled: index > 0; onClicked: page.move(modelData, -1) }
            Button { iconText: "󰁅"; enabled: index < page.win.stackKeys.length - 1; onClicked: page.move(modelData, 1) }
          }
        }
      }

      Button { text: "Add stratum"; iconText: "󰐕"; Layout.fillWidth: true; onClicked: page.addStratum() }
    }

    // ── The selected stratum ─────────────────────────────────────────────
    Flickable {
      id: detail
      Layout.fillWidth: true
      Layout.fillHeight: true
      contentWidth: width
      contentHeight: col.implicitHeight + 24
      clip: true
      QQC.ScrollBar.vertical: QQC.ScrollBar {}

      ColumnLayout {
        id: col
        width: detail.width - 14
        spacing: 2
        visible: page.key !== ""

        RowLayout {
          spacing: 14
          Layout.bottomMargin: 6
          Text { text: page.win ? page.win.iconOf(page.key, true) : ""; color: page.win ? page.win.tintKey(page.key) : "white"; font.family: Style.font.family; font.pixelSize: 32 }
          Text { text: page.win ? page.win.nameOf(page.key) : ""; color: page.theme.popups.text; font.family: Style.font.family; font.pixelSize: 20; font.bold: true }
        }

        // General
        PanelSectionHeader { text: "General"; Layout.topMargin: 6 }
        SettingRow {
          label: "Name"
          description: page.free ? "Followed by the stratum's number." : ""
          TextField {
            width: parent.width
            text: page.win ? (page.free ? page.win.get(["free", "name"], "Free") : page.win.sget(page.key, "name", "")) : ""
            onEditingFinished: if (text !== "") { if (page.free) page.win.set(["free", "name"], text); else page.win.sset(page.key, "name", text) }
          }
        }
        SettingRow {
          visible: page.themed
          label: "Icon"
          description: "Outline icon when inactive, filled icon when current."
          Row {
            spacing: 8
            Button { text: page.win ? page.win.sget(page.key, "icon", "") : ""; fontSize: 20; bordered: true; onClicked: { iconPicker.field = "icon"; iconPicker.visible = true } }
            Button { text: page.win ? page.win.sget(page.key, "iconActive", "") : ""; fontSize: 20; bordered: true; onClicked: { iconPicker.field = "iconActive"; iconPicker.visible = true } }
          }
        }
        SettingRow {
          label: "Color"
          description: "Accent color, taken from this stratum's theme."
          Row {
            width: parent.width
            spacing: 10
            Rectangle { width: 20; height: 20; radius: 10; anchors.verticalCenter: parent.verticalCenter; color: page.win ? page.win.tintKey(page.key) : "white" }
            Dropdown {
              width: parent.width - 30
              options: page.win ? page.win.roles : []
              value: page.win ? page.win.sget(page.key, "accent", "accent") : "accent"
              onChanged: function(v) { page.win.sset(page.key, "accent", v) }
            }
          }
        }
        SettingRow {
          label: "Hotkey"
          description: "SUPER+key switches to this stratum; SUPER+SHIFT+key moves the focused window to it."
          Dropdown {
            width: parent.width
            options: [{ value: "", label: "None" }, "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", { value: "grave", label: "` (backtick)" }]
            value: page.win ? page.win.sget(page.key, "hotkey", "") : ""
            onChanged: function(v) { page.win.sset(page.key, "hotkey", v) }
          }
        }
        SettingRow {
          visible: page.free
          label: "Dynamic free strata"
          description: "Create free strata on demand. Off: a fixed number."
          ToggleSwitch { checked: page.win ? page.win.get(["free", "dynamic"], true) : true; onToggled: page.win.set(["free", "dynamic"], !checked) }
        }
        SettingRow {
          visible: page.free && page.win && page.win.get(["free", "dynamic"], true) === false
          label: "Free strata count"
          NumberField { from: 1; to: 10; value: page.win ? page.win.get(["free", "count"], 5) : 5; onModified: function(v) { page.win.set(["free", "count"], v) } }
        }

        // Apps
        StratumApps {
          visible: page.themed
          Layout.fillWidth: true
          win: page.win
          key: page.key
        }

        // Launching
        PanelSectionHeader { text: "SUPER+RETURN"; Layout.topMargin: 14 }
        SettingRow {
          label: "Launches"
          description: "The window it opens stays on this stratum, regardless of routing rules."
          Column {
            width: parent.width
            spacing: 6
            Dropdown {
              id: primary
              width: parent.width
              readonly property string cur: page.win ? page.win.sget(page.key, "primary", "") : ""
              options: [{ value: "", label: "Terminal" }, { value: "browser", label: "Browser" }, { value: "steam", label: "Steam" }, { value: "custom", label: "Command" }]
              value: cur === "terminal" ? "" : (["", "browser", "steam"].indexOf(cur) >= 0 ? cur : "custom")
              onChanged: function(v) { if (v !== "custom") page.win.sset(page.key, "primary", v); else customCmd.forceActiveFocus() }
            }
            TextField {
              id: customCmd
              width: parent.width
              visible: primary.value === "custom"
              placeholderText: "e.g. code, obsidian"
              text: ["", "terminal", "browser", "steam"].indexOf(primary.cur) >= 0 ? "" : primary.cur
              onEditingFinished: if (text !== "") page.win.sset(page.key, "primary", text)
            }
          }
        }
        SettingRow {
          label: "Working directory"
          description: "Start directory for terminals launched with SUPER+RETURN."
          TextField { width: parent.width; placeholderText: "~/src/project"; text: page.win ? page.win.sget(page.key, "cwd", "") : ""; onEditingFinished: page.win.sset(page.key, "cwd", text) }
        }
        SettingRow {
          visible: page.themed
          label: "Autostart"
          description: "Commands run on the first visit to this stratum after login, one per line."
          QQC.TextArea {
            width: parent.width
            height: 64
            text: page.win ? (page.win.pget(page.key, "autostart", []) || []).join("\n") : ""
            color: page.theme.popups.text
            font.family: Style.font.family
            font.pixelSize: 12
            background: Rectangle { color: "transparent"; border.width: 1; border.color: Qt.rgba(page.theme.popups.text.r, page.theme.popups.text.g, page.theme.popups.text.b, 0.25); radius: 4 }
            onEditingFinished: page.win.pset(page.key, "autostart", text.split("\n").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" }))
          }
        }

        // Profile
        ColumnLayout {
          visible: page.themed
          Layout.fillWidth: true
          spacing: 2
          PanelSectionHeader { text: "Profile"; Layout.topMargin: 14 }
          SettingRow {
            label: "Private"
            description: "Its windows are drawn as placeholder cards in the preview cross and the overview."
            ToggleSwitch { checked: page.win.pget(page.key, "private", false); onToggled: page.win.pset(page.key, "private", !checked) }
          }
          SettingRow {
            label: "Audio output"
            description: "Default audio output while this stratum is active."
            Dropdown {
              width: parent.width
              options: [{ value: "", label: "Don't change" }].concat(page.sinks)
              value: page.win.pget(page.key, "audio_output", "")
              onChanged: function(v) { page.win.pset(page.key, "audio_output", v) }
            }
          }

          PanelSectionHeader { text: "New windows"; Layout.topMargin: 14 }
          SettingRow {
            label: "Open fullscreen"
            description: "Window class regex. Matching windows open fullscreen on this stratum."
            TextField { width: parent.width; placeholderText: "^(steam_app_[0-9]+|gamescope)$"; text: page.win.pget(page.key, "fullscreen", ""); onEditingFinished: page.win.pset(page.key, "fullscreen", text) }
          }
          SettingRow {
            label: "Float"
            ToggleSwitch { checked: page.wdef("float", false); onToggled: page.setWdef("float", !checked) }
          }
          SettingRow {
            label: "Maximize"
            ToggleSwitch { checked: page.wdef("maximize", false); onToggled: page.setWdef("maximize", !checked) }
          }
          SettingRow {
            label: "Default column width"
            description: page.wdef("column_width", 0) > 0 ? Math.round(page.wdef("column_width", 0) * 100) + "% of the screen" : "Default"
            Row {
              spacing: 8
              PanelSlider { width: 220; minimum: 0.1; maximum: 1; step: 0.05; value: page.wdef("column_width", 0.5); onReleased: function(v) { page.setWdef("column_width", Math.round(v * 100) / 100) } }
              Button { iconText: "󰑐"; tooltipText: "Default"; onClicked: page.setWdef("column_width", null) }
            }
          }

          PanelSectionHeader { text: "Appearance"; Layout.topMargin: 14 }
          Repeater {
            model: [
              { k: "gaps_in", label: "Inner gaps", max: 40 },
              { k: "gaps_out", label: "Outer gaps", max: 60 },
              { k: "border_size", label: "Border width", max: 10 },
              { k: "rounding", label: "Rounding", max: 30 }
            ]
            delegate: SettingRow {
              required property var modelData
              Layout.fillWidth: true
              label: modelData.label
              description: page.look(modelData.k, null) === null ? "Default" : page.look(modelData.k, 0) + " px"
              Row {
                spacing: 8
                PanelSlider { width: 220; minimum: 0; maximum: modelData.max; step: 1; integer: true; value: page.look(modelData.k, 0); onReleased: function(v) { page.setLook(modelData.k, Math.round(v)) } }
                Button { iconText: "󰑐"; tooltipText: "Default"; onClicked: page.setLook(modelData.k, null) }
              }
            }
          }
          SettingRow {
            label: "Window opacity"
            description: page.look("opacity", null) === null ? "Default" : Math.round(page.look("opacity", 1) * 100) + "%"
            Row {
              spacing: 8
              PanelSlider { width: 220; minimum: 0.3; maximum: 1; step: 0.05; value: page.look("opacity", 1); onReleased: function(v) { page.setLook("opacity", Math.round(v * 100) / 100) } }
              Button { iconText: "󰑐"; tooltipText: "Default"; onClicked: page.setLook("opacity", null) }
            }
          }
        }

        // Theme & wallpaper
        PanelSectionHeader { text: "Theme & wallpaper"; Layout.topMargin: 14 }
        SettingRow {
          label: "Theme"
          description: page.switching ? "" : "Per-stratum themes are off (Themes & wallpapers); this applies once they're on."
          Dropdown {
            width: parent.width
            options: page.themeOptions
            value: page.win ? (page.win.sget(page.key, "theme", "") || "") : ""
            onChanged: function(v) { page.win.sset(page.key, "theme", v === "" ? null : v) }
          }
        }
        SettingRow {
          label: "Wallpaper"
          description: !page.switching ? "Per-stratum themes are off (Themes & wallpapers); this applies once they're on."
                       : page.win && page.win.sget(page.key, "wallpaper", "") ? String(page.win.sget(page.key, "wallpaper", "")).replace(/^.*\//, "")
                       : "Theme default"
          Row {
            spacing: 8
            Button { text: "Choose"; bordered: true; onClicked: wallPicker.visible = true }
            Button { iconText: "󰑐"; tooltipText: "Theme default"; onClicked: page.win.sset(page.key, "wallpaper", null) }
          }
        }

        // Picture in picture
        ColumnLayout {
          visible: page.themed
          Layout.fillWidth: true
          spacing: 2
          PanelSectionHeader { text: "Picture in picture"; Layout.topMargin: 14 }
          SettingRow {
            label: "Pop out video players"
            description: "When you leave this stratum while a matching player is playing, its window follows you as a pinned corner window."
            ToggleSwitch { checked: page.pipConf().enabled === true; onToggled: page.setPip("enabled", !checked) }
          }
          SettingRow {
            visible: page.pipConf().enabled === true
            label: "Players"
            description: "Window class regexes, separated by spaces."
            TextField {
              width: parent.width
              placeholderText: "^(mpv|vlc)$"
              text: (page.pipConf().apps || []).join("  ")
              onEditingFinished: page.setPip("apps", text.split(/\s+/).filter(function(s) { return s !== "" }))
            }
          }
        }

        Button {
          visible: page.themed
          Layout.topMargin: 18
          text: page.key.indexOf("custom-") === 0 ? "Delete stratum" : "Remove from stack"
          iconText: "󰆴"
          onClicked: page.removeStratum(page.key)
        }
      }
    }
  }

  IconPicker {
    id: iconPicker
    property string field: "icon"
    visible: false
    anchors.centerIn: parent
    width: Math.min(parent.width, 620)
    height: Math.min(parent.height, 520)
    title: field === "icon" ? "Icon (elsewhere)" : "Icon (on it)"
    current: page.win ? page.win.sget(page.key, field, "") : ""
    onPicked: function(icon) { page.win.sset(page.key, field, icon); visible = false }
    onCancelled: visible = false
  }

  WallpaperPicker {
    id: wallPicker
    visible: false
    anchors.centerIn: parent
    width: Math.min(parent.width, 820)
    height: Math.min(parent.height, 600)
    theme: page.win ? (page.win.sget(page.key, "theme", "") || page.win.get(["themes", "base"], "") || "") : ""
    current: page.win ? (page.win.sget(page.key, "wallpaper", "") || "") : ""
    onPicked: function(path) { page.win.sset(page.key, "wallpaper", path); visible = false }
    onCancelled: visible = false
  }
}
