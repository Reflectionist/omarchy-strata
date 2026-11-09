import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Pick a wallpaper from the themes' backgrounds (the stratum's theme first),
// your own backgrounds folder, or a path.
Rectangle {
  id: picker
  property string theme: ""
  property string current: ""
  signal picked(string path)
  signal cancelled()

  readonly property var colors: Commons.ShellColor || Commons.Color
  property var images: []
  property string query: ""

  color: colors.popups.background
  border.color: colors.popups.border
  border.width: 1
  radius: Math.max(4, Style.cornerRadius)

  onVisibleChanged: if (visible) finder.running = true

  Process {
    id: finder
    readonly property string home: Quickshell.env("HOME")
    readonly property string omarchy: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
    command: ["bash", "-c",
      "find -L \"$1/.config/omarchy/backgrounds\" \"$1/.config/omarchy/themes\" \"$2/themes\" \"$1/.local/share/strata/wallpapers\" " +
      "-path '*backgrounds*' -o -path '*strata/wallpapers*' 2>/dev/null | grep -iE '\\.(jpe?g|png|webp)$' | sort -u",
      "find", home, omarchy]
    stdout: StdioCollector {
      onStreamFinished: {
        var list = text.split("\n").filter(function(s) { return s !== "" })
        // The stratum's theme first.
        var t = picker.theme
        list.sort(function(a, b) {
          var ia = t !== "" && a.indexOf("/" + t + "/") >= 0 ? 0 : 1
          var ib = t !== "" && b.indexOf("/" + t + "/") >= 0 ? 0 : 1
          return ia !== ib ? ia - ib : a.localeCompare(b)
        })
        picker.images = list
      }
    }
  }

  readonly property var shown: {
    var q = query.toLowerCase()
    return q === "" ? images : images.filter(function(p) { return p.toLowerCase().indexOf(q) >= 0 })
  }
  function themeOf(path) { var m = path.match(/\/(?:backgrounds|themes)\/([^\/]+)\//); return m ? m[1] : "" }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 14
    spacing: 10

    RowLayout {
      Layout.fillWidth: true
      Text { text: "Wallpaper"; color: picker.colors.popups.text; font.family: Style.font.family; font.pixelSize: 15; font.bold: true; Layout.fillWidth: true }
      TextField {
        Layout.preferredWidth: 320
        placeholderText: "Filter, or a path to an image"
        onTextChanged: picker.query = text.startsWith("/") || text.startsWith("~") ? "" : text
        onAccepted: if (text.startsWith("/") || text.startsWith("~")) picker.picked(text.replace(/^~/, Quickshell.env("HOME")))
      }
    }

    GridView {
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      cellWidth: 190
      cellHeight: 132
      model: picker.shown
      delegate: Item {
        required property var modelData
        width: 182
        height: 124
        Rectangle {
          anchors.fill: parent
          radius: 6
          color: "transparent"
          border.width: modelData === picker.current ? 2 : (hover.containsMouse ? 1 : 0)
          border.color: picker.colors.accent
        }
        Image {
          anchors.fill: parent
          anchors.margins: 4
          source: "file://" + modelData
          sourceSize: Qt.size(240, 150)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
        }
        Rectangle {
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          anchors.margins: 6
          width: label.implicitWidth + 10
          height: 16
          radius: 4
          color: Qt.rgba(0, 0, 0, 0.6)
          Text { id: label; anchors.centerIn: parent; text: picker.themeOf(modelData); color: "white"; font.family: Style.font.family; font.pixelSize: 9 }
        }
        MouseArea { id: hover; anchors.fill: parent; hoverEnabled: true; onClicked: picker.picked(modelData) }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      Text { Layout.fillWidth: true; text: picker.shown.length + " images"; color: picker.colors.muted; font.family: Style.font.family; font.pixelSize: 11 }
      Button { text: "Cancel"; onClicked: picker.cancelled() }
    }
  }
}
