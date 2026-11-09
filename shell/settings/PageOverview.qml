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
    spacing: 8

    Text { text: "Overview"; color: page.theme.popups.text; font.family: Style.font.family; font.pixelSize: 20; font.bold: true }

    PanelSectionHeader { text: "Keys"; Layout.topMargin: 12 }
    Repeater {
      model: [
        ["SUPER+TAB", "Open or close"],
        ["SUPER+SHIFT+TAB", "Open with search"],
        ["Arrows / HJKL", "Move the selection, the way SUPER+arrows move on the desktop"],
        ["Enter / click", "Go to the selected window or empty slot"],
        ["Esc / right click", "Close (cancels a drag first)"],
        ["Drag a window", "Move it. Drop on a window's middle to stack, on its outer quarters to insert beside it, on empty space to place it; any stratum."],
        ["Drag a window's edge", "Resize its column"],
        ["SHIFT+arrows", "Move the selected window (SUPER+SHIFT+arrow rules)"],
        ["CTRL+LEFT/RIGHT", "Narrow or widen the selected window's column"],
        ["Drag a name", "Reorder the stack"],
        ["Middle click", "Close a window"],
        ["Type", "Search titles and apps"],
        ["Up / Down / Tab", "While searching: the next or previous match"]
      ]
      delegate: RowLayout {
        required property var modelData
        Layout.fillWidth: true
        Text { text: modelData[0]; color: page.theme.popups.text; font.family: Style.font.family; font.pixelSize: 13; Layout.preferredWidth: 200 }
        Text { text: modelData[1]; color: page.theme.muted; font.family: Style.font.family; font.pixelSize: 13; Layout.fillWidth: true }
      }
    }
  }
}
