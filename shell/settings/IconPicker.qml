import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Pick a stratum glyph: a Nerd Font icon (searched by name), an emoji, or
// your own image (an SVG/PNG path; monochrome SVGs take the stratum's colour).
Rectangle {
  id: picker
  property string title: "Icon"
  property string current: ""
  signal picked(string icon)
  signal cancelled()

  readonly property var theme: Commons.ShellColor || Commons.Color
  property string mode: "nerd"
  property string query: ""
  property var nerd: []
  property var emoji: []
  property string hoveredName: ""

  color: theme.popups.background
  border.color: theme.popups.border
  border.width: 1
  radius: Math.max(4, Style.cornerRadius)

  // icons.json: [name, glyph] pairs generated from Nerd Fonts' glyphnames.json
  // (https://github.com/ryanoasis/nerd-fonts, MIT), names without the "nf-"
  // prefix.
  FileView {
    path: Qt.resolvedUrl("../icons.json").toString().replace(/^[a-z]+:\/\//, "")
    blockLoading: true
    printErrors: false
    onLoaded: { try { picker.nerd = JSON.parse(text()) } catch (e) {} }
  }
  FileView {
    path: (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell/plugins/emojis/emojis.json"
    blockLoading: true
    printErrors: false
    onLoaded: { try { picker.emoji = JSON.parse(text()) } catch (e) {} }
  }

  readonly property var results: {
    var q = query.toLowerCase().trim()
    var out = []
    var words = q === "" ? [] : q.split(/\s+/)
    function hit(s) { for (var i = 0; i < words.length; i++) if (s.indexOf(words[i]) < 0) return false; return true }
    if (mode === "nerd") {
      for (var i = 0; i < nerd.length && out.length < 240; i++)
        if (words.length === 0 ? nerd[i][0].indexOf("md-") === 0 : hit(nerd[i][0])) out.push({ g: nerd[i][1], n: nerd[i][0] })
    } else if (mode === "emoji") {
      for (var j = 0; j < emoji.length && out.length < 240; j++)
        if (words.length === 0 || hit(emoji[j].k)) out.push({ g: emoji[j].e, n: emoji[j].k })
    }
    return out
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 14
    spacing: 10

    RowLayout {
      Layout.fillWidth: true
      Text {
        text: picker.title
        color: picker.theme.popups.text
        font.family: Style.font.family
        font.pixelSize: 15
        font.bold: true
        Layout.fillWidth: true
      }
      ButtonGroup {
        options: [{ value: "nerd", label: "Nerd Font" }, { value: "emoji", label: "Emoji" }, { value: "image", label: "Image" }]
        value: picker.mode
        onChanged: function(v) { picker.mode = v }
      }
    }

    TextField {
      id: search
      Layout.fillWidth: true
      placeholderText: picker.mode === "image" ? "Path to an SVG or PNG (~ works)" : "Search, e.g. gamepad, terminal, flask"
      text: picker.mode === "image" && picker.current.match(/^[~\/]/) ? picker.current : ""
      onTextChanged: picker.query = text
      onAccepted: if (picker.mode === "image" && text !== "") picker.picked(text)
      Component.onCompleted: forceActiveFocus()
    }

    GridView {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: picker.mode !== "image"
      clip: true
      cellWidth: 46
      cellHeight: 46
      model: picker.results
      delegate: Rectangle {
        required property var modelData
        width: 42; height: 42; radius: 6
        color: hover.containsMouse ? Qt.rgba(picker.theme.popups.text.r, picker.theme.popups.text.g, picker.theme.popups.text.b, 0.1) : "transparent"
        border.width: modelData.g === picker.current ? 1 : 0
        border.color: picker.theme.accent
        Text { anchors.centerIn: parent; text: modelData.g; color: picker.theme.popups.text; font.family: Style.font.family; font.pixelSize: 22 }
        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          onContainsMouseChanged: if (containsMouse) picker.hoveredName = modelData.n
          onClicked: picker.picked(modelData.g)
        }
      }
    }

    Item { Layout.fillHeight: true; visible: picker.mode === "image" }

    RowLayout {
      Layout.fillWidth: true
      Text {
        Layout.fillWidth: true
        text: picker.mode === "image" ? "Enter to use the path"
            : (picker.hoveredName !== "" ? picker.hoveredName + "  ·  " : "") + picker.results.length + (picker.results.length >= 240 ? "+" : "") + " matches"
        color: picker.theme.muted
        font.family: Style.font.family
        font.pixelSize: 11
      }
      Button { text: "Cancel"; onClicked: picker.cancelled() }
    }
  }
}
