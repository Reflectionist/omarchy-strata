import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: page
  property var win: null
  readonly property var theme: Commons.ShellColor || Commons.Color
  function c(k, d) { return win ? win.get(["cross", k], d) : d }
  function setc(k, v) { win.set(["cross", k], v) }

  ColumnLayout {
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: 2

    Text { text: "Preview cross"; color: page.theme.popups.text; font.family: Style.font.family; font.pixelSize: 20; font.bold: true }
    Text {
      Layout.fillWidth: true
      text: "Live thumbnails of the adjacent areas (left and right on the row, and the strata above and below), shown while you navigate."
      color: page.theme.muted; font.family: Style.font.family; font.pixelSize: 11; wrapMode: Text.WordWrap
    }

    PanelSectionHeader { text: "Behavior"; Layout.topMargin: 12 }
    SettingRow {
      label: "Shown on"
      Dropdown {
        width: parent.width
        options: [{ value: "move", label: "Every navigation" }, { value: "held", label: "While SUPER is held" }, { value: "change", label: "Stratum changes only" },
                  { value: "hold", label: "SUPER held alone" }, { value: "off", label: "Never" }]
        value: page.c("trigger", "move")
        onChanged: function(v) { page.setc("trigger", v) }
      }
    }
    SettingRow {
      label: "Position"
      ButtonGroup {
        options: [{ value: "bottom", label: "Bottom" }, { value: "center", label: "Center" }, { value: "topleft", label: "Top left" }]
        value: page.c("placement", "bottom")
        onChanged: function(v) { page.setc("placement", v) }
      }
    }
    SettingRow {
      label: "Size"
      description: Math.round(page.c("size", 0.16) * 100) + "% of the screen width"
      PanelSlider { width: parent.width; minimum: 0.08; maximum: 0.35; step: 0.01; value: page.c("size", 0.16); onReleased: function(v) { page.setc("size", Math.round(v * 100) / 100) } }
    }
    SettingRow {
      label: "Hide after"
      description: page.c("fade_ms", 800) + " ms after the last move"
      PanelSlider { width: parent.width; minimum: 200; maximum: 4000; step: 100; integer: true; value: page.c("fade_ms", 800); onReleased: function(v) { page.setc("fade_ms", Math.round(v)) } }
    }
  }
}
