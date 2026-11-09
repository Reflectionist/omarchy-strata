import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: page
  property var win: null
  readonly property var theme: Commons.ShellColor || Commons.Color

  ColumnLayout {
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: 2

    Text { text: "Bar widget"; color: page.theme.popups.text; font.family: Style.font.family; font.pixelSize: 20; font.bold: true }
    Text {
      Layout.fillWidth: true
      text: "Shows the current stratum's icon. Left click: settings. Right click: overview. Scroll: previous / next stratum."
      color: page.theme.muted; font.family: Style.font.family; font.pixelSize: 11; wrapMode: Text.WordWrap
    }

    PanelSectionHeader { text: "Appearance"; Layout.topMargin: 12 }
    SettingRow {
      label: "Change animation"
      ButtonGroup {
        options: [{ value: "cage", label: "Slide" }, { value: "crossfade", label: "Crossfade" }, { value: "flip", label: "Flip" }, { value: "none", label: "None" }]
        value: page.win ? page.win.get(["glyph", "animation"], "cage") : "cage"
        onChanged: function(v) { page.win.set(["glyph", "animation"], v) }
      }
    }
    SettingRow {
      label: "Icon style"
      description: "Auto uses the filled icon and leaves restyling to bar icon plugins. Outline and Filled force one variant."
      ButtonGroup {
        options: [{ value: "auto", label: "Auto" }, { value: "outline", label: "Outline" }, { value: "filled", label: "Filled" }]
        value: page.win ? page.win.get(["glyph", "outline"], "auto") : "auto"
        onChanged: function(v) { page.win.set(["glyph", "outline"], v) }
      }
    }
  }
}
