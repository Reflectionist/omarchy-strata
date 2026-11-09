import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: page
  property var win: null
  readonly property var theme: Commons.ShellColor || Commons.Color
  function g(k, d) { return win ? win.get(["pip", k], d) : d }
  function setg(k, v) { win.set(["pip", k], v) }

  ColumnLayout {
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: 2

    Text { text: "Picture in picture"; color: page.theme.popups.text; font.family: Style.font.family; font.pixelSize: 20; font.bold: true }
    Text {
      Layout.fillWidth: true
      text: "Which players pop out is set per stratum, on its page."
      color: page.theme.muted; font.family: Style.font.family; font.pixelSize: 11; wrapMode: Text.WordWrap
    }

    PanelSectionHeader { text: "Placement"; Layout.topMargin: 12 }
    SettingRow {
      label: "Corner"
      controlWidth: 420
      ButtonGroup {
        options: [{ value: "top-left", label: "Top left" }, { value: "top-right", label: "Top right" }, { value: "bottom-left", label: "Bottom left" }, { value: "bottom-right", label: "Bottom right" }]
        value: page.g("corner", "bottom-right")
        onChanged: function(v) { page.setg("corner", v) }
      }
    }
    SettingRow {
      label: "Size"
      description: Math.round(page.g("width", 0.25) * 100) + "% of the screen width. Moving or resizing it is remembered per app."
      PanelSlider { width: parent.width; minimum: 0.12; maximum: 0.5; step: 0.01; value: page.g("width", 0.25); onReleased: function(v) { page.setg("width", Math.round(v * 100) / 100) } }
    }
    SettingRow {
      label: "Avoid the focused window"
      description: "Moves to the opposite side when it overlaps the focused window."
      ToggleSwitch { checked: page.g("avoid_focus", false); onToggled: page.setg("avoid_focus", !checked) }
    }
    SettingRow {
      label: "Show seek bar"
      ToggleSwitch { checked: page.g("seek_bar", true); onToggled: page.setg("seek_bar", !checked) }
    }
  }
}
