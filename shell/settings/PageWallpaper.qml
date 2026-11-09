import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// What applies to all strata: whether themes switch between strata, the base
// theme and wallpaper (for strata without their own) and how wallpapers move.
Item {
  id: page
  property var win: null
  readonly property var theme: Commons.ShellColor || Commons.Color
  function t(k, d) { return win ? win.get(["themes", k], d) : d }
  function sett(k, v) { win.set(["themes", k], v) }
  readonly property bool switching: t("switching", true) !== false

  property var themes: []
  Process {
    running: true
    command: ["omarchy-theme-list"]
    stdout: StdioCollector {
      onStreamFinished: page.themes = text.split("\n").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
    }
  }
  readonly property var themeOptions: [{ value: "", label: "None (current theme)" }].concat(themes.map(function(n) {
    return { value: String(n).toLowerCase().replace(/<[^>]+>/g, "").trim().replace(/ /g, "-"), label: n }
  }))

  function applyAll(field, value) {
    var keys = win.stackKeys
    for (var i = 0; i < keys.length; i++) win.sset(keys[i], field, value)
  }

  Flickable {
    anchors.fill: parent
    contentHeight: col.implicitHeight
    clip: true

    ColumnLayout {
      id: col
      width: parent.width
      spacing: 2

      Text { text: "Themes & wallpapers"; color: page.theme.popups.text; font.family: Style.font.family; font.pixelSize: 20; font.bold: true }
      Text {
        Layout.fillWidth: true
        text: page.switching
              ? "Per-stratum themes and wallpapers are set on each stratum's page. Omarchy's theme and wallpaper pickers save to the current stratum."
              : "Per-stratum themes are off: all strata use Omarchy's current theme and wallpaper, and the pickers change them globally."
        color: page.theme.muted; font.family: Style.font.family; font.pixelSize: 11; wrapMode: Text.WordWrap
      }

      PanelSectionHeader { text: "Themes"; Layout.topMargin: 12 }
      SettingRow {
        label: "Per-stratum themes"
        description: "Apply each stratum's theme and wallpaper when it becomes active. Off: one theme and wallpaper for all strata."
        ToggleSwitch { checked: page.switching; onToggled: page.sett("switching", !checked) }
      }
      SettingRow {
        visible: !page.switching
        label: "Per-stratum wallpapers"
        description: "Assigns the current theme's wallpapers to strata in stack order, starting from the one picked for the current stratum."
        ToggleSwitch { checked: page.t("auto_wallpapers", false) === true; onToggled: page.sett("auto_wallpapers", !checked) }
      }
      SettingRow {
        visible: page.switching
        label: "App retint delay"
        description: "The bar, borders and terminals update immediately; other applications are retinted after " + page.t("settle_ms", 1500) + " ms on a stratum."
        PanelSlider { width: parent.width; minimum: 300; maximum: 6000; step: 100; integer: true; value: page.t("settle_ms", 1500); onReleased: function(v) { page.sett("settle_ms", Math.round(v)) } }
      }

      PanelSectionHeader { visible: page.switching; text: "Defaults"; Layout.topMargin: 14 }
      SettingRow {
        visible: page.switching
        label: "Base theme"
        description: "Used by strata without a theme of their own."
        Dropdown { width: parent.width; options: page.themeOptions; value: page.t("base", "") || ""; onChanged: function(v) { page.sett("base", v === "" ? null : v) } }
      }
      SettingRow {
        visible: page.switching
        label: "Base wallpaper"
        description: page.t("base_wallpaper", "") ? String(page.t("base_wallpaper", "")).replace(/^.*\//, "") : "Theme default"
        Row {
          spacing: 8
          Button { text: "Choose"; bordered: true; onClicked: wallPicker.visible = true }
          Button { iconText: "󰑐"; tooltipText: "Theme default"; onClicked: page.sett("base_wallpaper", null) }
        }
      }
      RowLayout {
        visible: page.switching
        Layout.topMargin: 6
        spacing: 8
        Button { text: "Apply base theme to all strata"; bordered: true; onClicked: page.applyAll("theme", null) }
        Button { text: "Apply base wallpaper to all strata"; bordered: true; onClicked: page.applyAll("wallpaper", null) }
      }

      PanelSectionHeader { text: "Transitions"; Layout.topMargin: 14 }
      SettingRow {
        label: "Stratum change"
        description: "Parallax moves the wallpaper slower than the windows."
        ButtonGroup {
          options: [{ value: "crossfade", label: "Crossfade" }, { value: "slide", label: "Slide" }, { value: "parallax", label: "Parallax" }]
          value: page.t("wallpaper_vertical", "crossfade")
          onChanged: function(v) { page.sett("wallpaper_vertical", v) }
        }
      }
      SettingRow {
        label: "Horizontal parallax"
        description: "Shifts the wallpaper slightly while you pan along a stratum."
        ToggleSwitch { checked: page.t("wallpaper_parallax", false); onToggled: page.sett("wallpaper_parallax", !checked) }
      }
      SettingRow {
        visible: page.t("wallpaper_parallax", false)
        label: "Parallax strength"
        description: Math.round(page.t("parallax_strength", 0.08) * 100) + "% of a screen per screen panned"
        PanelSlider { width: parent.width; minimum: 0.02; maximum: 0.3; step: 0.01; value: page.t("parallax_strength", 0.08); onReleased: function(v) { page.sett("parallax_strength", Math.round(v * 100) / 100) } }
      }
    }
  }

  WallpaperPicker {
    id: wallPicker
    visible: false
    anchors.centerIn: parent
    width: Math.min(parent.width, 820)
    height: Math.min(parent.height, 600)
    theme: page.t("base", "") || ""
    current: page.t("base_wallpaper", "") || ""
    onPicked: function(path) { page.sett("base_wallpaper", path); visible = false }
    onCancelled: visible = false
  }
}
