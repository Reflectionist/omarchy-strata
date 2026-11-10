import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// The overview's labels and input. Hyprland draws the zoomed-out grid (live
// windows, bands) and posts its layout as a "strata-overview" event; this
// layer names the strata, shows the selection and search, and turns clicks,
// drags and keys into lua/strata.lua calls.
//
//   arrows         move the selection (windows and blank spots), by the
//                  same rules as SUPER+arrows on the desktop (HJKL too, with
//                  the "letters" setting on hjkl; "/" then starts a search)
//   Enter / click  go there            Esc / SUPER+TAB  close, back where you were
//   drag a window  onto a window: stack into its column; to its sides: in
//                  beside it; blank: right there; any stratum. Hyprland draws
//                  it under the pointer and the others making room
//   drag an edge   resize its column   Esc / right click  cancel a drag
//   SHIFT+arrows   move the selected window, as SUPER+SHIFT+arrows do
//   CTRL+Left/Right  its column narrower / wider
//   middle click   close a window      type           search titles and apps
//   drag a name    reorder the stack   Up/Down/Tab    next match while searching
PanelWindow {
  id: ov
  required property var service
  readonly property var theme: Commons.ShellColor || Commons.Color
  readonly property var state: service.stateObject

  property var grid: ({ open: false, rows: [], windows: [] })
  readonly property bool isOpen: grid.open === true

  visible: isOpen || fading.running
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "strata-overview"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: isOpen && !releasing ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  // Hyprland hands focus back to the window that had it when this layer lets
  // go of the keyboard. Let go first, then switch strata, or that hand-back
  // would pull you straight back to where you started.
  property bool releasing: false
  property string pendingCall: ""
  Timer {
    id: releaseTimer
    interval: 80
    onTriggered: { if (ov.pendingCall !== "") ov.lua(ov.pendingCall); ov.pendingCall = "" }
  }
  function after(code) {
    releasing = true
    pendingCall = code
    releaseTimer.restart()
    stuck.restart()
  }
  // The call should have closed it; if Lua failed, take the keyboard back
  // rather than leave an open overview nothing can type into.
  Timer {
    id: stuck
    interval: 1500
    onTriggered: if (ov.isOpen) ov.releasing = false
  }

  // ── Mapping ───────────────────────────────────────────────────────────
  // moveH/moveV/slotAt mirror nav() and aim() in native/src/view.cpp and
  // edge_fires() in lua/strata.lua: change them together. (The selection
  // moves here, without a round trip per key press.)
  // Hyprland sends the grid with the steps SUPER+arrows use, so the selection
  // moves here exactly the way visual focus moves on the desktop, and lands
  // where it shows.
  readonly property real eps: 1e-4
  readonly property real vstep: grid.vstep || 0.5
  readonly property real slotW: grid.sw || 0.5
  readonly property real nearW: grid.near !== undefined ? grid.near : 2 * vstep
  readonly property var nav: (state.config && state.config.navigation) || ({})
  // Letter keys: "search" (typing searches; arrows move) or "hjkl" (HJKL
  // move too; "/" starts a search).
  readonly property bool hjkl: ((state.config && state.config.overview) || {}).letters === "hjkl"
  function gridX(px) { return grid.u0 + ((px - grid.ox) / grid.s - grid.gutter) / grid.uw }
  function screenX(u) { return grid.ox + (grid.gutter + (u - grid.u0) * grid.uw) * grid.s }
  function rowAt(py) {
    var rows = grid.rows || []
    for (var i = 0; i < rows.length; i++) {
      var gap = (grid.pitch * grid.s - rows[i].h) / 2
      if (py >= rows[i].y - gap && py < rows[i].y + rows[i].h + gap) return i
    }
    return -1
  }
  function entry(i) { return state.stack[i] || null }
  function rowColor(i) { return state.colorForEntry(entry(i) || state.current, theme.popups.text, theme.popups.background) }
  function lua(code) { Quickshell.execDetached(["hyprctl", "eval", code]) }
  function strata(fn, args) { lua('local s = require("hypr.strata") s.' + fn + '(' + args + ')') }
  function strataAfterRelease(fn, args) { after('local s = require("hypr.strata") s.' + fn + '(' + args + ')') }

  // Calls that must arrive in order (a drag's start before its drop, one
  // SHIFT+arrow move before the next) go out one at a time.
  property var callQueue: []
  Process {
    id: caller
    onExited: Qt.callLater(ov.nextCall)
    // hyprctl eval says "ok", or the Lua error: keep those in the shell log.
    stdout: StdioCollector {
      onStreamFinished: { var t = text.trim(); if (t !== "" && t !== "ok") console.warn("strata overview: " + t) }
    }
  }
  function strataQueued(fn, args) {
    callQueue.push('local s = require("hypr.strata") s.' + fn + '(' + args + ')')
    if (!caller.running) nextCall()
  }
  function nextCall() {
    if (caller.running || callQueue.length === 0) return
    caller.command = ["hyprctl", "eval", callQueue.shift()]
    caller.running = true
  }

  // ── Dragging ──────────────────────────────────────────────────────────
  // Hyprland runs the drag: this only says start, drop or cancel, and draws
  // the outline of where it lands (from "strata-overview-drag" events).
  property string dragAddr: ""
  property bool dragCancelled: false
  property var drag: ({ active: false })
  // Keep a dropped window selected while it's between strata (a stratum
  // made for it has no row in the grid for a moment).
  property string keepAddr: ""
  Timer { id: keepTimer; interval: 600; onTriggered: ov.keepAddr = "" }

  function dragStart(a, edge, fx, fy) {
    dragAddr = a
    dragCancelled = false
    strataQueued("overview_drag", JSON.stringify(a) + ", " + edge + ", " + fx.toFixed(4) + ", " + fy.toFixed(4))
  }
  function dragEnd() {
    if (dragAddr === "") return
    var a = dragAddr
    dragAddr = ""
    keepAddr = a
    keepTimer.restart()
    selAddr = a
    strataQueued("overview_drag_end", "")
    if (heldGrid) Qt.callLater(receive, heldGrid)
  }
  function dragCancel() {
    if (dragAddr === "") return
    dragAddr = ""
    dragCancelled = true
    strataQueued("overview_drag_cancel", "")
    if (heldGrid) Qt.callLater(receive, heldGrid)
  }
  function receiveDrag(v) { drag = v }

  // SHIFT+arrows / CTRL+Left/Right on the selected window.
  function moveSel(dir) {
    var w = selAddr !== "" ? windowByAddr(selAddr) : null
    if (tiled(w)) strataQueued("overview_move", JSON.stringify(w.a) + ", " + JSON.stringify(dir))
  }
  function widenSel(dir) {
    var w = selAddr !== "" ? windowByAddr(selAddr) : null
    if (tiled(w)) strataQueued("overview_widen", JSON.stringify(w.a) + ", " + dir)
  }

  // ── Selection ─────────────────────────────────────────────────────────
  // A window (selAddr), or a blank slot [selX, selX + selW] on row selRow.
  property int selRow: 0
  property string selAddr: ""
  property real selX: 0
  property real selW: 0.5
  property string query: ""

  readonly property var matches: {
    var q = query.toLowerCase()
    var out = []
    if (q === "") return out
    var ws = grid.windows || []
    for (var i = 0; i < ws.length; i++)
      if (String(ws[i].t).toLowerCase().indexOf(q) >= 0 || String(ws[i].c).toLowerCase().indexOf(q) >= 0) out.push(ws[i].a)
    return out
  }
  // Typing keeps the pick while it still matches, else takes the first match.
  onMatchesChanged: if (matches.length > 0 && matches.indexOf(selAddr) < 0) selectWin(windowByAddr(matches[0]))
  // Up/down in the search field: the next or previous match.
  function cycleMatch(dir) {
    var n = matches.length
    if (n === 0) return
    var i = matches.indexOf(selAddr)
    selectWin(windowByAddr(matches[((i < 0 ? (dir > 0 ? -1 : 0) : i) + dir + n) % n]))
  }

  function windowByAddr(a) {
    var ws = grid.windows || []
    for (var i = 0; i < ws.length; i++) if (ws[i].a === a) return ws[i]
    return null
  }
  function tiled(w) { return w !== null && w.gx !== null && w.gx !== undefined }
  function selectWin(w) {
    if (!w) return
    selAddr = w.a
    selRow = w.r
    // Remembered, for when the window goes while selected.
    if (tiled(w)) { selX = w.gx; selW = w.gw }
  }
  function selectBlank(x, w) {
    selAddr = ""
    selX = x
    selW = w
  }

  // A row's columns, left to right: { x, w, wins (top to bottom) }.
  function columns(r) {
    var byX = {}
    var out = []
    var ws = grid.windows || []
    for (var i = 0; i < ws.length; i++) {
      var w = ws[i]
      if (w.r !== r || !tiled(w)) continue
      var k = w.gx.toFixed(4)
      if (!byX[k]) { byX[k] = { x: w.gx, w: w.gw, wins: [] }; out.push(byX[k]) }
      byX[k].wins.push(w)
    }
    out.sort(function(a, b) { return a.x - b.x })
    for (var j = 0; j < out.length; j++) out[j].wins.sort(function(a, b) { return a.ci - b.ci })
    return out
  }
  function columnOf(w) {
    var cols = columns(w.r)
    for (var i = 0; i < cols.length; i++) if (cols[i].wins.indexOf(w) >= 0) return cols[i]
    return null
  }

  // What's selected as a stretch of the grid: the window's column (a floating
  // window: where it shows), or the blank slot.
  function span() {
    var w = selAddr !== "" ? windowByAddr(selAddr) : null
    if (tiled(w)) return { x: w.gx, w: w.gw, win: w }
    if (w) return { x: gridX(w.x), w: w.w / (grid.uw * grid.s), win: w }
    return { x: selX, w: selW, win: null }
  }

  // The window to take in a column: arriving from above (+1) the top one,
  // from below (-1) the bottom one, sideways the one level with where you were.
  function pickIn(col, from, hint) {
    if (hint > 0) return col.wins[0]
    if (hint < 0) return col.wins[col.wins.length - 1]
    if (!from) return col.wins[0]
    var cy = from.y + from.h / 2
    var best = col.wins[0]
    for (var i = 1; i < col.wins.length; i++)
      if (Math.abs(col.wins[i].y + col.wins[i].h / 2 - cy) < Math.abs(best.y + best.h / 2 - cy)) best = col.wins[i]
    return best
  }

  // At an edge with "wrap only when held": the first press arms, a repeat or
  // a second press soon after wraps (as on the desktop).
  property string edgeArmed: ""
  Timer { id: edgeTimer; interval: 900; onTriggered: ov.edgeArmed = "" }
  function edgeFires(key) {
    if (nav.wrap_hold !== true) return true
    if (edgeArmed === key) { edgeArmed = ""; return true }
    edgeArmed = key
    edgeTimer.restart()
    return false
  }

  // Left/right: SUPER+LEFT/RIGHT's rules. The next window if it's within
  // jump_near view steps; else into blank space, starting at the window's edge
  // and then a view step at a time; never past the overview's band.
  function moveH(dir) {
    var cols = columns(selRow)
    var cur = span()
    var L = cur.x, R = cur.x + cur.w
    var cand = null
    for (var i = 0; i < cols.length; i++) {
      var c = cols[i]
      if (dir > 0 && c.x >= R - eps && (!cand || c.x < cand.x)) cand = c
      if (dir < 0 && c.x + c.w <= L + eps && (!cand || c.x + c.w > cand.x + cand.w)) cand = c
    }
    var gap = !cand ? Infinity : dir > 0 ? cand.x - R : L - (cand.x + cand.w)
    if (cand && gap <= nearW + eps) { edgeArmed = ""; selectWin(pickIn(cand, cur.win, 0)); return }

    var nl = cur.win === null ? L + dir * vstep : (dir > 0 ? R : L - slotW)
    if (cand && ((dir > 0 && nl + slotW > cand.x + eps) || (dir < 0 && nl < cand.x + cand.w - eps))) { edgeArmed = ""; selectWin(pickIn(cand, cur.win, 0)); return }
    // Past the travel range (the band) is the edge; but a step back towards
    // it always goes (the grid can shrink under a selection out there).
    var outside = function(x, w) { return Math.max(grid.lo - x, x + w - grid.hi, 0) }
    if (outside(nl, slotW) > eps && outside(nl, slotW) >= outside(L, R - L) - eps) {
      if (nav.wrap_horizontal === true && edgeFires("h" + dir)) {
        if (cols.length > 0) selectWin(pickIn(dir > 0 ? cols[0] : cols[cols.length - 1], null, 0))
        else selectBlank(dir > 0 ? grid.lo : grid.hi - slotW, slotW)
      }
      return
    }
    edgeArmed = ""
    selectBlank(nl, slotW)
  }

  // Up/down: SUPER+UP/DOWN's rules. Through a column's stacked windows first,
  // then to the stratum above/below: the window there with the most overlap,
  // or blank at the same x.
  function moveV(dir) {
    var cur = span()
    if (tiled(cur.win)) {
      var col = columnOf(cur.win)
      var at = col ? col.wins.indexOf(cur.win) : -1
      if (at >= 0 && at + dir >= 0 && at + dir < col.wins.length) { selectWin(col.wins[at + dir]); return }
    }
    var n = (grid.rows || []).length
    if (n === 0) return
    var t = selRow + dir
    if (t < 0 || t >= n) {
      // Lua's word (its setting and the wrap-off toggle), as SUPER+UP/DOWN use.
      var wrapv = grid.wrapv !== undefined ? grid.wrapv : nav.wrap_vertical !== false
      if (!wrapv || !edgeFires("v" + dir)) return
      t = (t + n) % n
    }
    edgeArmed = ""
    var cols = columns(t)
    var best = null, bestO = 0
    for (var i = 0; i < cols.length; i++) {
      var o = Math.min(cur.x + cur.w, cols[i].x + cols[i].w) - Math.max(cur.x, cols[i].x)
      if (o > bestO + eps) { bestO = o; best = cols[i] }
    }
    if (best) { selectWin(pickIn(best, null, dir)); return }
    selRow = t
    selectBlank(cur.x, cur.w)
  }

  // A point on row r: the window whose column it's in, or the blank slot
  // there on the view-step grid, kept inside its gap (the way Strata's aim()
  // picks it); a gap narrower than a slot gives the nearest window.
  function slotAt(r, x) {
    var cols = columns(r)
    var gl = -Infinity, gr = Infinity, left = null, right = null
    for (var i = 0; i < cols.length; i++) {
      var c = cols[i]
      if (x >= c.x - eps && x < c.x + c.w - eps) return { win: pickIn(c, null, 0) }
      if (c.x + c.w <= x + eps && c.x + c.w > gl) { gl = c.x + c.w; left = c }
      if (c.x >= x - eps && c.x < gr) { gr = c.x; right = c }
    }
    if (gr - gl < slotW - eps) {
      var near = !left ? right : !right ? left : (x - gl <= gr - x ? left : right)
      if (near) return { win: pickIn(near, null, 0) }
    }
    var sx = Math.floor(x / vstep + eps) * vstep
    sx = Math.max(gl, Math.min(sx, gr - slotW))
    sx = Math.max(grid.lo, Math.min(sx, grid.hi - slotW))
    return { win: null, x: sx, w: slotW }
  }

  function go() {
    if (selAddr !== "") strataAfterRelease("overview_go", (selRow + 1) + ", nil, " + JSON.stringify(selAddr))
    else strataAfterRelease("overview_go", (selRow + 1) + ", " + selX.toFixed(6) + ", nil, " + selW.toFixed(6))
  }
  function close() { strataAfterRelease("overview", "") }

  // For tests and scripts: `qs ipc call strataOverview move right` etc.
  IpcHandler {
    target: "strataOverview"
    function state(): string {
      var sp = ov.span()
      return JSON.stringify({ open: ov.isOpen, row: ov.selRow, addr: ov.selAddr, x: sp.x, w: sp.w,
                              title: sp.win ? sp.win.t : "", query: ov.query, dragging: ov.dragAddr, landing: ov.drag,
                              rows: (ov.grid.rows || []).map(function(r) { return r.ws }) })
    }
    function move(dir: string): void {
      if (!ov.isOpen) return
      if (dir === "left") ov.moveH(-1)
      else if (dir === "right") ov.moveH(1)
      else if (dir === "up") ov.moveV(-1)
      else if (dir === "down") ov.moveV(1)
    }
    function enter(): void { if (ov.isOpen) ov.go() }
    // Each window's title and box on screen, for pointer tests.
    function windows(): string {
      return JSON.stringify((ov.grid.windows || []).map(function(w) {
        return { t: w.t, r: w.r, x: Math.round(w.x), y: Math.round(w.y), w: Math.round(w.w), h: Math.round(w.h), gx: w.gx, ci: w.ci, cn: w.cn }
      }))
    }
  }

  // ── Events ────────────────────────────────────────────────────────────
  // A refresh during a drag waits for the drop: it would rebuild the window
  // items, and with them the one holding the pointer.
  property var heldGrid: null
  function receive(v) {
    if (v.open && dragAddr !== "") { heldGrid = v; return }
    heldGrid = null
    var wasOpen = isOpen
    grid = v
    if (!v.open) { releasing = false; dragAddr = ""; drag = { active: false } }
    if (v.open && !wasOpen) {
      query = ""
      edgeArmed = ""
      // Start where you are: the focused window, the column visual focus is
      // on, or the blank slot you're on (so Enter right away changes nothing).
      selRow = v.row0
      selectBlank(v.cx, v.cw)
      var f = v.focus ? windowByAddr(v.focus) : null
      if (f) selectWin(f)
      else if (!v.blank) {
        var cols = columns(selRow)
        for (var i = 0; i < cols.length; i++)
          if (Math.abs(cols[i].x - v.cx) < 1e-3) { selectWin(pickIn(cols[i], null, 0)); break }
      }
      searchField.text = ""
      if (v.search) searchField.forceActiveFocus(); else keys.forceActiveFocus()
    } else if (v.open && selAddr !== "") {
      var w = windowByAddr(selAddr)
      // The selected window went (closed, or moved off the stack); or the
      // stack was reordered and its row moved with it.
      if (!w) { if (selAddr !== keepAddr) selectBlank(selX, slotW) }
      else selectWin(w)
    }
  }

  // ── Drawing ───────────────────────────────────────────────────────────
  Item {
    id: layer
    anchors.fill: parent
    opacity: ov.isOpen ? 1 : 0
    Behavior on opacity { NumberAnimation { id: fading; duration: ov.isOpen ? 220 : 120; easing.type: Easing.OutCubic } }

    // Background clicks: blank spots. A right click during a drag cancels
    // the drag (it lands here: the window holding the pointer only has the
    // left button), not the overview.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      property bool swallowRight: false
      onPressed: function(m) {
        if (m.button === Qt.RightButton && ov.dragAddr !== "") { ov.dragCancel(); swallowRight = true }
        else if (m.button === Qt.LeftButton) ov.dragCancelled = false
      }
      onClicked: function(m) {
        if (m.button === Qt.RightButton && swallowRight) { swallowRight = false; return }
        if (m.button === Qt.RightButton) { ov.close(); return }
        var r = ov.rowAt(m.y)
        if (r < 0) { ov.close(); return }
        var slot = ov.slotAt(r, ov.gridX(m.x))
        ov.selRow = r
        if (slot.win) ov.selectWin(slot.win)
        else ov.selectBlank(slot.x, slot.w)
        ov.go()
      }
    }

    // Stratum names, in each stratum's colour. Drag one onto another row to
    // move it there in the stack.
    Repeater {
      model: ov.grid.rows || []
      delegate: Item {
        id: label
        required property var modelData
        readonly property var e: ov.entry(modelData.i)
        readonly property bool here: modelData.i === ov.grid.row0
        // Right-aligned up to the band (not the grid's first slot: a wide
        // gutter put the names over the band).
        x: 14
        y: modelData.y + modelData.h / 2 - height / 2
        width: Math.max(0, (ov.grid.ox || 0) - 12 - x)
        height: 30

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8
          Text {
            text: label.e ? (label.here ? label.e.iconActive : label.e.icon) : ""
            color: label.e ? ov.state.colorForEntry(label.e, ov.theme.popups.text, ov.theme.popups.background) : ov.theme.popups.text
            font.family: Style.font.family
            font.pixelSize: 18
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: label.e ? label.e.name : ""
            color: label.e ? ov.state.colorForEntry(label.e, ov.theme.popups.text, ov.theme.popups.background) : ov.theme.popups.text
            font.family: Style.font.family
            font.pixelSize: 13
            font.bold: label.here
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          anchors.fill: parent
          property real startY: 0
          property bool dragging: false
          cursorShape: dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
          onPressed: function(m) { startY = m.y; dragging = false }
          onPositionChanged: function(m) { if (Math.abs(m.y - startY) > 6) dragging = true }
          onReleased: function(m) {
            if (!dragging) {
              // Your own stratum: stay as you were. Another: land there the
              // way switching to it does.
              if (label.here) ov.close()
              else ov.strataAfterRelease("overview_go", String(label.modelData.i + 1))
              return
            }
            var to = ov.rowAt(label.mapToItem(layer, m.x, m.y).y)
            if (to >= 0 && to !== label.modelData.i) ov.service.moveStratum(label.modelData.i, to)
            dragging = false
          }
        }
      }
    }

    // Windows: hover, selection, search matches, drag, close.
    Repeater {
      model: ov.grid.windows || []
      delegate: Item {
        id: win
        required property var modelData
        readonly property bool selected: ov.selAddr === modelData.a
        readonly property bool matched: ov.matches.indexOf(modelData.a) >= 0
        x: modelData.x
        y: modelData.y
        width: modelData.w
        height: modelData.h

        Rectangle {
          anchors.fill: parent
          anchors.margins: -2
          color: ov.query !== "" && !win.matched ? Qt.rgba(0, 0, 0, 0.55) : "transparent"
          radius: 4
          border.width: ov.dragAddr === "" && !win.selected && (hover.containsMouse || win.matched) ? 1 : 0
          border.color: Qt.rgba(ov.theme.popups.text.r, ov.theme.popups.text.g, ov.theme.popups.text.b, 0.6)
        }

        // Close
        Rectangle {
          visible: ov.dragAddr === "" && hover.containsMouse && win.width > 40
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: 3
          width: 16; height: 16; radius: 8
          color: Qt.rgba(ov.theme.popups.background.r, ov.theme.popups.background.g, ov.theme.popups.background.b, 0.9)
          Text { anchors.centerIn: parent; text: "󰅖"; color: ov.theme.popups.text; font.family: Style.font.family; font.pixelSize: 10 }
          MouseArea { anchors.fill: parent; onClicked: ov.lua('hl.dispatch(hl.dsp.window.close({ window = "address:' + win.modelData.a + '" }))') }
        }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
          // Tiled windows can be dragged; grabbed this close to a side, it
          // resizes the column instead.
          readonly property bool movable: ov.tiled(win.modelData)
          readonly property real edgeW: Math.min(8, width / 6)
          property point start
          property int edge: 0
          property bool dragging: false
          function edgeAt(x) { return !movable ? 0 : x < edgeW ? -1 : x > width - edgeW ? 1 : 0 }
          cursorShape: dragging ? (edge !== 0 ? Qt.SizeHorCursor : Qt.ClosedHandCursor)
                                : (edgeAt(mouseX) !== 0 ? Qt.SizeHorCursor : Qt.PointingHandCursor)
          onPressed: function(m) {
            // Right click: cancels a drag; otherwise it's the background's
            // (close the overview), as on blank space.
            if (m.button === Qt.RightButton) { if (dragging) ov.dragCancel(); else m.accepted = false; return }
            if (m.button !== Qt.LeftButton) return
            start = Qt.point(m.x, m.y)
            edge = edgeAt(m.x)
            dragging = false
            ov.dragCancelled = false
          }
          onPositionChanged: function(m) {
            if (!(m.buttons & Qt.LeftButton) || dragging || !movable || ov.dragCancelled) return
            if (Math.hypot(m.x - start.x, m.y - start.y) > 6) {
              dragging = true
              ov.dragStart(win.modelData.a, edge, start.x / width, start.y / height)
            }
          }
          onReleased: function(m) {
            if (m.button === Qt.MiddleButton) {
              ov.lua('hl.dispatch(hl.dsp.window.close({ window = "address:' + win.modelData.a + '" }))')
              return
            }
            if (m.button !== Qt.LeftButton) return
            if (dragging || ov.dragCancelled) {
              dragging = false
              if (!ov.dragCancelled) ov.dragEnd()
              ov.dragCancelled = false
              return
            }
            ov.selectWin(win.modelData)
            ov.go()
          }
          onCanceled: if (dragging) { dragging = false; ov.dragCancel() }
        }
      }
    }

    // Where a dragged window will land, in that stratum's colour.
    Rectangle {
      id: landing
      readonly property var d: ov.drag
      visible: ov.dragAddr !== "" && d.active === true && d.edge === 0 && (d.w || 0) > 0
      x: (d.x || 0) - 2
      y: (d.y || 0) - 2
      width: (d.w || 0) + 4
      height: (d.h || 0) + 4
      radius: 5
      readonly property color c: ov.rowColor(d.row || 0)
      color: Qt.rgba(c.r, c.g, c.b, 0.08)
      border.width: 2
      border.color: c
      Behavior on x { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
      Behavior on width { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
      Behavior on height { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
    }

    // The selection: one frame that moves between windows and blank slots.
    Rectangle {
      id: selFrame
      readonly property var row: (ov.grid.rows || [])[ov.selRow]
      readonly property var win: ov.selAddr !== "" ? ov.windowByAddr(ov.selAddr) : null
      // Glide between selections, but appear in place when the overview opens.
      property bool glide: false
      visible: ov.isOpen && ov.dragAddr === "" && (win !== null || row !== undefined)
      onVisibleChanged: { glide = false; if (visible) glideOn.restart() }
      Timer { id: glideOn; interval: 50; onTriggered: selFrame.glide = true }
      x: win ? win.x - 2 : ov.screenX(ov.selX)
      y: win ? win.y - 2 : (row ? row.y : 0)
      width: win ? win.w + 4 : ov.selW * (ov.grid.uw || 0) * (ov.grid.s || 0)
      height: win ? win.h + 4 : (row ? row.h : 0)
      radius: 4
      color: "transparent"
      border.width: 2
      border.color: ov.rowColor(ov.selRow)
      Behavior on x { enabled: selFrame.glide; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
      Behavior on y { enabled: selFrame.glide; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
      Behavior on width { enabled: selFrame.glide; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
      Behavior on height { enabled: selFrame.glide; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
    }

    // Search
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: 14
      width: 360
      height: 32
      radius: 16
      visible: ov.query !== "" || searchField.activeFocus
      color: Qt.rgba(ov.theme.popups.background.r, ov.theme.popups.background.g, ov.theme.popups.background.b, 0.92)
      border.width: 1
      border.color: Qt.rgba(ov.theme.popups.text.r, ov.theme.popups.text.g, ov.theme.popups.text.b, 0.3)
      Text {
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        text: "󰍉"
        color: ov.theme.muted
        font.family: Style.font.family
        font.pixelSize: 14
      }
      TextInput {
        id: searchField
        anchors.fill: parent
        anchors.leftMargin: 34
        anchors.rightMargin: 12
        verticalAlignment: TextInput.AlignVCenter
        color: ov.theme.popups.text
        font.family: Style.font.family
        font.pixelSize: 13
        onTextChanged: ov.query = text
        Keys.onEscapePressed: { if (ov.dragAddr !== "") ov.dragCancel(); else if (text !== "") text = ""; else ov.close() }
        Keys.onReturnPressed: ov.go()
        Keys.onEnterPressed: ov.go()
        // With a search: the next/previous match. Without: back to the grid.
        Keys.onDownPressed: { if (ov.matches.length > 0) ov.cycleMatch(1); else keys.forceActiveFocus() }
        Keys.onUpPressed: { if (ov.matches.length > 0) ov.cycleMatch(-1) }
        Keys.onTabPressed: ov.cycleMatch(1)
        Keys.onBacktabPressed: ov.cycleMatch(-1)
      }
    }

    // Keys when not typing in the search field: typing starts a search.
    Item {
      id: keys
      focus: true
      Keys.onPressed: function(k) {
        var arrow = k.key === Qt.Key_Left ? "l" : k.key === Qt.Key_Right ? "r" : k.key === Qt.Key_Up ? "u" : k.key === Qt.Key_Down ? "d" : ""
        if (k.key === Qt.Key_Escape && ov.dragAddr !== "") { ov.dragCancel(); k.accepted = true }
        else if (arrow !== "" && (k.modifiers & Qt.ShiftModifier)) { ov.moveSel(arrow); k.accepted = true }
        else if ((arrow === "l" || arrow === "r") && (k.modifiers & Qt.ControlModifier)) { ov.widenSel(arrow === "r" ? 1 : -1); k.accepted = true }
        else if (k.key === Qt.Key_Escape) { ov.close(); k.accepted = true }
        else if (k.key === Qt.Key_Return || k.key === Qt.Key_Enter) { ov.go(); k.accepted = true }
        else if (k.key === Qt.Key_Left || (ov.hjkl && k.key === Qt.Key_H && !(k.modifiers & ~Qt.KeypadModifier))) { ov.moveH(-1); k.accepted = true }
        else if (k.key === Qt.Key_Right || (ov.hjkl && k.key === Qt.Key_L && !(k.modifiers & ~Qt.KeypadModifier))) { ov.moveH(1); k.accepted = true }
        else if (k.key === Qt.Key_Up || (ov.hjkl && k.key === Qt.Key_K && !(k.modifiers & ~Qt.KeypadModifier))) { ov.moveV(-1); k.accepted = true }
        else if (k.key === Qt.Key_Down || (ov.hjkl && k.key === Qt.Key_J && !(k.modifiers & ~Qt.KeypadModifier))) { ov.moveV(1); k.accepted = true }
        else if (k.key === Qt.Key_Slash) { searchField.forceActiveFocus(); k.accepted = true }
        else if (k.text !== "" && k.text.charCodeAt(0) > 32 && !(k.modifiers & (Qt.ControlModifier | Qt.MetaModifier))) {
          searchField.forceActiveFocus()
          searchField.text += k.text
          k.accepted = true
        }
      }
    }
  }
}
