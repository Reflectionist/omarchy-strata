import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons

// One setting: name and a line of explanation on the left, its control on
// the right (or underneath, when there isn't room for both).
Item {
  id: row
  property string label: ""
  property string description: ""
  property real controlWidth: 300
  default property alias control: slot.data
  readonly property var theme: Commons.ShellColor || Commons.Color

  readonly property bool narrow: width < 460

  Layout.fillWidth: true
  implicitHeight: (narrow ? texts.implicitHeight + 8 + slot.height : Math.max(texts.implicitHeight, slot.height)) + 14

  ColumnLayout {
    id: texts
    x: 0
    y: row.narrow ? 7 : (row.height - implicitHeight) / 2
    width: row.narrow ? row.width : row.width - slot.width - 18
    spacing: 2
    Text {
      Layout.fillWidth: true
      text: row.label
      color: row.theme.popups.text
      font.family: Style.font.family
      font.pixelSize: 14
      wrapMode: Text.WordWrap
    }
    Text {
      Layout.fillWidth: true
      visible: row.description !== ""
      text: row.description
      color: row.theme.muted
      font.family: Style.font.family
      font.pixelSize: 11
      wrapMode: Text.WordWrap
    }
  }

  Item {
    id: slot
    x: row.narrow ? 0 : row.width - width
    y: row.narrow ? texts.y + texts.implicitHeight + 8 : (row.height - height) / 2
    width: row.narrow ? Math.min(row.controlWidth, row.width) : Math.min(row.controlWidth, row.width * 0.55)
    height: childrenRect.height
  }
}
