import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import "Stack.js" as Stack

// What Strata draws over the desktop, click-through:
//   - the preview cross's frames and labels (Hyprland draws the live tiles
//     under them and sends their boxes as a "strata-cross" event);
//   - when visual focus is parked on blank space: a reticle on the empty slot
//     and/or a ruler along the bottom edge (the blank.look setting).
// The surface only exists while one of them is showing, so it costs nothing
// the rest of the time (and never stands in the way of direct scanout).
PanelWindow {
  id: win
  required property var service
  readonly property var theme: Commons.ShellColor || Commons.Color
  readonly property var state: service.stateObject

  // ── Cross ──────────────────────────────────────────────────────────────
  property var cross: ({ show: false, tiles: [] })
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "strata-cross") return
      var v = win.state.eventJson(event.data)
      if (v) win.cross = v
    }
  }
  readonly property bool crossShown: cross.show === true

  // ── Blank space ────────────────────────────────────────────────────────
  readonly property var view: state.view
  readonly property string look: state.config && state.config.blank && state.config.blank.look ? state.config.blank.look : "both"
  // Not under the overview: it shows the whole grid, and the slot there.
  readonly property bool blank: view && view.blank === true && view.ws === state.focusedId && !service.overviewShown
  readonly property bool reticleOn: blank && (look === "reticle" || look === "both")
  readonly property bool rulerOn: blank && (look === "ruler" || look === "both")

  readonly property bool wanted: crossShown || reticleOn || rulerOn
  // Stay mapped through the fade-out.
  property bool lingering: false
  onWantedChanged: if (!wanted) { lingering = true; linger.restart() }
  Timer { id: linger; interval: 260; onTriggered: win.lingering = false }

  visible: wanted || lingering
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "strata-overlay"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  mask: Region {}

  readonly property color accent: state.colorForEntry(state.current, theme.popups.text, theme.popups.background)

  // The stratum a cross tile shows: the one you're on, or for the tiles
  // above and below, the stack row the plugin drew there (-1: none).
  function entryForTile(t) {
    if (t.k !== "up" && t.k !== "down") return state.current
    return t.row >= 0 ? state.stack[t.row] || null : null
  }

  // The frames go when the previews do, even if a hide never arrives.
  Timer {
    id: crossTimeout
    interval: ((state.config && state.config.cross && state.config.cross.fade_ms) || 800) + 400
    onTriggered: {
      var trig = state.config && state.config.cross ? state.config.cross.trigger : "move"
      if (trig !== "held" && trig !== "hold") win.cross = { show: false, tiles: win.cross.tiles || [] }
    }
  }
  onCrossChanged: if (cross.show === true) crossTimeout.restart()

  Item {
    id: crossLayer
    anchors.fill: parent
    opacity: win.crossShown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: win.crossShown ? 120 : 180; easing.type: Easing.OutCubic } }

    Repeater {
      model: win.cross.tiles || []
      delegate: Item {
        required property var modelData
        readonly property var entry: win.entryForTile(modelData)
        readonly property bool vertical: modelData.k === "up" || modelData.k === "down"
        readonly property bool middle: modelData.k === "center"
        x: modelData.x
        y: modelData.y
        width: modelData.w
        height: modelData.h

        Rectangle {
          anchors.fill: parent
          color: "transparent"
          radius: Math.max(4, Style.cornerRadius)
          border.width: middle ? 2 : 1
          border.color: middle ? win.accent : Qt.rgba(win.theme.popups.text.r, win.theme.popups.text.g, win.theme.popups.text.b, 0.28)
        }

        // Up/down: which stratum that is.
        Rectangle {
          visible: (vertical || middle) && entry !== null
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.margins: 5
          height: 18
          width: labelRow.implicitWidth + 12
          radius: 9
          color: Qt.rgba(win.theme.popups.background.r, win.theme.popups.background.g, win.theme.popups.background.b, 0.85)
          Row {
            id: labelRow
            anchors.centerIn: parent
            spacing: 5
            Text {
              text: entry ? (middle ? entry.iconActive : entry.icon) : ""
              color: entry ? win.state.colorForEntry(entry, win.theme.popups.text, win.theme.popups.background) : win.theme.popups.text
              font.family: Style.font.family
              font.pixelSize: 11
            }
            Text {
              text: entry ? entry.name : ""
              color: win.theme.popups.text
              font.family: Style.font.family
              font.pixelSize: 10
            }
          }
        }
      }
    }
  }

  // ── Reticle: corner brackets on the empty slot you're on ───────────────
  Item {
    id: reticle
    readonly property var slot: win.view && win.view.slot ? win.view.slot : [0, 0, 0, 0]
    x: slot[0] + 10
    y: slot[1] + 10
    width: Math.max(0, slot[2] - 20)
    height: Math.max(0, slot[3] - 20)
    opacity: win.reticleOn ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 160 } }
    Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    readonly property real arm: Math.min(width, height) * 0.08 + 14
    readonly property color ink: Qt.rgba(win.accent.r, win.accent.g, win.accent.b, 0.85)

    Repeater {
      model: 4
      delegate: Item {
        required property int index
        readonly property bool atRight: index === 1 || index === 2
        readonly property bool atBottom: index >= 2
        x: atRight ? reticle.width - reticle.arm : 0
        y: atBottom ? reticle.height - reticle.arm : 0
        width: reticle.arm
        height: reticle.arm
        Rectangle { x: 0; y: atBottom ? parent.height - 2 : 0; width: parent.width; height: 2; color: reticle.ink }
        Rectangle { x: atRight ? parent.width - 2 : 0; y: 0; width: 2; height: parent.height; color: reticle.ink }
      }
    }

    // A faint wash so the slot reads as a place, not just wallpaper.
    Rectangle {
      anchors.fill: parent
      radius: Math.max(4, Style.cornerRadius)
      color: Qt.rgba(win.accent.r, win.accent.g, win.accent.b, 0.05)
    }
  }

  // ── Ruler: your x on this stratum and where its windows are ────────────
  Item {
    id: ruler
    readonly property real lo: (win.view.lo || 0) - (win.view.margin || 0)
    readonly property real hi: (win.view.hi || 1) + (win.view.margin || 0)
    readonly property real span: Math.max(0.01, hi - lo)
    function px(u) { return (u - lo) / span * width }

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.leftMargin: parent.width * 0.2
    anchors.rightMargin: parent.width * 0.2
    anchors.bottomMargin: 10
    height: 6
    opacity: win.rulerOn ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 160 } }

    Rectangle {
      anchors.fill: parent
      radius: 3
      color: Qt.rgba(win.theme.popups.background.r, win.theme.popups.background.g, win.theme.popups.background.b, 0.7)
    }
    Repeater {
      model: win.view.cols || []
      delegate: Rectangle {
        required property var modelData
        x: ruler.px(modelData[0]) + 1
        width: Math.max(2, ruler.px(modelData[0] + modelData[1]) - ruler.px(modelData[0]) - 2)
        y: 1
        height: 4
        radius: 2
        color: Qt.rgba(win.theme.popups.text.r, win.theme.popups.text.g, win.theme.popups.text.b, 0.45)
      }
    }
    // The viewport
    Rectangle {
      x: ruler.px(win.view.camera || 0)
      width: ruler.px((win.view.camera || 0) + 1) - x
      y: -2
      height: 10
      radius: 3
      color: "transparent"
      border.width: 1
      border.color: Qt.rgba(win.theme.popups.text.r, win.theme.popups.text.g, win.theme.popups.text.b, 0.6)
      Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }
    // You
    Rectangle {
      x: ruler.px(win.view.x || 0)
      width: Math.max(3, ruler.px((win.view.x || 0) + (win.view.w || 0.5)) - x)
      y: 0
      height: 6
      radius: 3
      color: win.accent
      Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }
  }
}
