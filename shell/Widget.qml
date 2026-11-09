import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The stratum you're on, as one glyph in its accent colour.
//   left click   Strata settings
//   right click  the overview of the whole grid
//   wheel        the stratum above / below
// When you change stratum the glyph rides the cage: the old one slides out
// and the new one in, the way the strata themselves slide (or crossfades /
// flips / just swaps, per the glyph setting).
BarWidget {
  id: root
  moduleName: "io.github.reflectionist.strata"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null

  // A replacement bar hands widgets a facade without services; the IPC route
  // answers under any bar.
  function ipc(args) { Quickshell.execDetached(["omarchy-shell", "strata"].concat(args)) }
  function lua(fn) {
    Quickshell.execDetached(["hyprctl", "eval", 'local ok, s = pcall(require, "hypr.strata") if ok and s and s.' + fn + ' then s.' + fn + '() end'])
  }

  // Shape contract for shell.summon/hide/toggle routing: the bar looks for
  // open/close/opened on the widget root.
  readonly property bool opened: service ? service.settingsOpen : false
  // Settings, on the page of the stratum you're on.
  readonly property string currentPage: state && state.current && state.current.key ? "strata:" + state.current.key : ""
  function open() { if (service) service.showSettings(currentPage); else ipc(["showSettings", currentPage]) }
  function close() { if (service) service.hideSettings(); else ipc(["hideSettings"]) }
  function toggle() {
    if (!service) ipc(["toggleAt", currentPage])
    else if (service.settingsOpen) close()
    else open()
  }

  // Its own view of where you are: under a replacement bar, widgets may not
  // reach the service, so actions go over IPC when it isn't there.
  StrataState { id: state }

  readonly property var cur: state.current
  readonly property var glyphCfg: state.config && state.config.glyph ? state.config.glyph : ({})
  readonly property string animationStyle: glyphCfg.animation || "cage"
  // "auto": the filled glyph, left to whatever decorates bar icons (an
  // outliner can add its outline twin); "outline" / "filled" force one.
  readonly property string outlineMode: glyphCfg.outline || "auto"

  readonly property string glyph: !cur ? "󱓻" : (outlineMode === "outline" ? cur.icon : cur.iconActive)
  readonly property color barText: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color tint: cur
    ? state.colorForEntry(cur, root.barText, Commons.Color.bar.background) : root.barText

  // What the button shows; it changes once the new glyph has slid in.
  property string shown: glyph
  property color shownTint: tint
  property string leaving: ""
  property color leavingTint: tint
  property int direction: 0

  onTintChanged: if (!swap.running) shownTint = tint
  onGlyphChanged: {
    if (glyph === shown) return
    leaving = shown
    leavingTint = shownTint
    direction = state.travel
    shown = glyph
    shownTint = tint
    if (animationStyle === "none") return
    swap.restart()
  }

  readonly property string tooltip: {
    if (!cur) return "Strata"
    var parts = [cur.name]
    if (state.currentIndex >= 0) parts.push((state.currentIndex + 1) + " of " + state.stack.length)
    var n = state.currentWindows
    parts.push(n === 0 ? "empty" : n === 1 ? "1 window" : n + " windows")
    return parts.join("  ·  ")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    bar: root.bar
    text: root.shown
    foreground: root.shownTint
    useActiveColor: false
    horizontalMargin: 6
    fixedWidth: root.vertical ? root.barSize : Style.space(20)
    fixedHeight: root.vertical ? -1 : root.barSize
    tooltipText: root.tooltip
    // The stock label (what bar icon decorators see) steps aside while the two
    // glyphs below are moving.
    labelVisible: !swap.running
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.lua("overview")
      } else if (b === Qt.LeftButton) {
        root.toggle()
      }
    }
    onWheelMoved: function(delta) {
      if (delta > 0) root.lua("focus_up")
      else if (delta < 0) root.lua("focus_down")
    }
  }

  Item {
    id: stage
    anchors.fill: button
    clip: true
    visible: swap.running

    readonly property real travelY: height * 0.8

    Text {
      id: outgoing
      anchors.horizontalCenter: parent.horizontalCenter
      y: (parent.height - height) / 2
      text: root.leaving
      color: root.leavingTint
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      renderType: Text.NativeRendering
      transform: Scale { id: outScale; origin.y: outgoing.height / 2; yScale: 1 }
    }

    Text {
      id: incoming
      anchors.horizontalCenter: parent.horizontalCenter
      y: (parent.height - height) / 2
      text: root.shown
      color: root.shownTint
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      renderType: Text.NativeRendering
      transform: Scale { id: inScale; origin.y: incoming.height / 2; yScale: 1 }
    }
  }

  readonly property real restY: (stage.height - incoming.height) / 2
  // Going down the stack the view moves down: the old glyph leaves upward and
  // the new one rises from below. Going up, the other way.
  readonly property real enterFrom: root.restY + (root.direction >= 0 ? stage.travelY : -stage.travelY)
  readonly property real exitTo: root.restY + (root.direction >= 0 ? -stage.travelY : stage.travelY)
  readonly property string effective: root.animationStyle === "cage" && root.direction === 0 ? "crossfade" : root.animationStyle

  SequentialAnimation {
    id: swap
    ScriptAction {
      script: {
        outgoing.y = root.restY; outgoing.opacity = 1; outScale.yScale = 1
        incoming.opacity = 1; inScale.yScale = 1
        incoming.y = root.effective === "cage" ? root.enterFrom : root.restY
        if (root.effective === "crossfade") incoming.opacity = 0
        if (root.effective === "flip") inScale.yScale = 0
      }
    }
    ParallelAnimation {
      // cage
      NumberAnimation { target: outgoing; property: "y"; to: root.exitTo; duration: root.effective === "cage" ? 260 : 0; easing.type: Easing.OutCubic }
      NumberAnimation { target: incoming; property: "y"; to: root.restY; duration: root.effective === "cage" ? 260 : 0; easing.type: Easing.OutCubic }
      // crossfade
      NumberAnimation { target: outgoing; property: "opacity"; to: 0; duration: root.effective === "crossfade" ? 220 : (root.effective === "cage" ? 200 : 0) }
      NumberAnimation { target: incoming; property: "opacity"; to: 1; duration: root.effective === "crossfade" ? 220 : 0 }
      // flip: the old one folds shut, then the new one opens
      SequentialAnimation {
        NumberAnimation { target: outScale; property: "yScale"; to: 0; duration: root.effective === "flip" ? 120 : 0; easing.type: Easing.InQuad }
        NumberAnimation { target: inScale; property: "yScale"; to: 1; duration: root.effective === "flip" ? 140 : 0; easing.type: Easing.OutQuad }
      }
    }
  }
}
