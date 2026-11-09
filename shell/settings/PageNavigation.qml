import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: page
  property var win: null
  readonly property var theme: Commons.ShellColor || Commons.Color
  function n(k, d) { return win ? win.get(["navigation", k], d) : d }
  function setn(k, v) { win.set(["navigation", k], v) }
  function pct(v) { return Math.round(v * 1000) / 10 + "% of the screen width" }

  Flickable {
    anchors.fill: parent
    contentHeight: col.implicitHeight
    clip: true

    ColumnLayout {
      id: col
      width: parent.width
      spacing: 2

      Text { text: "Navigation"; color: page.theme.popups.text; font.family: Style.font.family; font.pixelSize: 20; font.bold: true }

      PanelSectionHeader { text: "Step sizes"; Layout.topMargin: 12 }
      SettingRow {
        label: "Focus step"
        description: "Distance SUPER+LEFT/RIGHT moves through empty space: " + page.pct(page.n("view_step", 0.5)) + "."
        PanelSlider { width: parent.width; minimum: 0.1; maximum: 1; step: 0.05; value: page.n("view_step", 0.5); onReleased: function(v) { page.setn("view_step", Math.round(v * 100) / 100) } }
      }
      SettingRow {
        label: "Window step"
        description: "Distance SUPER+SHIFT+LEFT/RIGHT moves a window: " + page.pct(page.n("step", 0.5)) + ". Columns snap to multiples of it."
        PanelSlider { width: parent.width; minimum: 0.1; maximum: 1; step: 0.05; value: page.n("step", 0.5); onReleased: function(v) { page.setn("step", Math.round(v * 100) / 100) } }
      }
      SettingRow {
        label: "Fine step"
        description: "Distance SUPER+CTRL+SHIFT+LEFT/RIGHT moves a window, without snapping: " + page.pct(page.n("fine_step", 0.125)) + ". Also the overview's resize step."
        PanelSlider { width: parent.width; minimum: 0.02; maximum: 0.5; step: 0.005; value: page.n("fine_step", 0.125); onReleased: function(v) { page.setn("fine_step", Math.round(v * 1000) / 1000) } }
      }
      SettingRow {
        label: "Jump distance"
        description: "Most empty space, in focus steps, that SUPER+LEFT/RIGHT skips to reach the next window."
        NumberField { from: 0; to: 20; value: page.n("jump_near", 2); onModified: function(v) { page.setn("jump_near", v) } }
      }
      SettingRow {
        label: "Travel margin"
        description: "How far focus can move past the outermost window, in focus steps."
        NumberField { from: 0; to: 40; value: page.n("margin", 4); onModified: function(v) { page.setn("margin", v) } }
      }

      PanelSectionHeader { text: "Wrapping"; Layout.topMargin: 14 }
      SettingRow {
        label: "Wrap between first and last stratum"
        ToggleSwitch { checked: page.n("wrap_vertical", true); onToggled: page.setn("wrap_vertical", !checked) }
      }
      SettingRow {
        label: "Wrap at the ends of a row"
        ToggleSwitch { checked: page.n("wrap_horizontal", false); onToggled: page.setn("wrap_horizontal", !checked) }
      }
      SettingRow {
        label: "Wrap only when held"
        description: "At an edge, wrap only on a held key or a second press."
        ToggleSwitch { checked: page.n("wrap_hold", false); onToggled: page.setn("wrap_hold", !checked) }
      }

      PanelSectionHeader { text: "Behavior"; Layout.topMargin: 14 }
      SettingRow {
        label: "Focus after switching stratum"
        ButtonGroup {
          options: [{ value: "grid", label: "Window at the same position" }, { value: "last", label: "Last focused window" }]
          value: page.n("land_focus", "grid")
          onChanged: function(v) { page.setn("land_focus", v) }
        }
      }
      SettingRow {
        label: "When a column closes"
        ButtonGroup {
          options: [{ value: "keep", label: "Leave empty space" }, { value: "close", label: "Shift later columns left" }]
          value: page.n("close_gap", false) ? "close" : "keep"
          onChanged: function(v) { page.setn("close_gap", v === "close") }
        }
      }
      SettingRow {
        label: "Empty-space indicator"
        controlWidth: 380
        ButtonGroup {
          options: [{ value: "both", label: "Reticle and ruler" }, { value: "reticle", label: "Reticle" }, { value: "ruler", label: "Ruler" }, { value: "none", label: "None" }]
          value: page.win ? page.win.get(["blank", "look"], "both") : "both"
          onChanged: function(v) { page.win.set(["blank", "look"], v) }
        }
      }

      // Each group Strata binds; off leaves those keys to Omarchy's own bindings.
      PanelSectionHeader { text: "Key bindings"; Layout.topMargin: 14 }
      Repeater {
        model: [
          { k: "grid", label: "Grid navigation", description: "SUPER+arrows, SUPER+SHIFT+arrows, SUPER+CTRL+SHIFT+LEFT/RIGHT, SUPER+CTRL+HOME." },
          { k: "strata", label: "Stratum hotkeys", description: "SUPER+<hotkey> (default 1-9) and its SHIFT / SHIFT+ALT variants, in place of Omarchy's workspace keys." },
          { k: "overview", label: "Overview", description: "SUPER+TAB and SUPER+SHIFT+TAB." },
          { k: "launch", label: "Stratum app", description: "SUPER+RETURN opens the current stratum's primary app." },
          { k: "wheel", label: "Scroll wheel", description: "SUPER+scroll moves along the row; SUPER+SHIFT+scroll changes stratum." },
          { k: "gestures", label: "Touchpad gestures", description: "Three-finger horizontal swipe pans the row; vertical swipe changes stratum." }
        ]
        delegate: SettingRow {
          required property var modelData
          label: modelData.label
          description: modelData.description
          ToggleSwitch {
            checked: page.win ? page.win.get(["keys", modelData.k], true) : true
            onToggled: page.win.set(["keys", modelData.k], !checked)
          }
        }
      }
    }
  }
}
