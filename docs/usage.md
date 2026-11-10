---
title: Usage
nav_order: 3
---

# Usage
{: .no_toc }

1. TOC
{:toc}

Distances below are in **steps**, set in [Settings › Navigation](settings#navigation): the focus step (default half a screen) for moving focus through empty space, the window step (default half a screen) for moving windows, and the fine step (default an eighth of a screen).

## Moving focus

| Keys | Action |
|---|---|
| SUPER+LEFT/RIGHT | Focus the next window in that direction if it is within the jump distance; otherwise move one focus step into empty space. Focus stops at the leftmost and rightmost window on any stratum (plus the blank-space margin, 0 by default). |
| SUPER+UP/DOWN | Focus the window above or below in the same column; at the top or bottom of the column, switch to the stratum above or below at the same horizontal position. |
| SUPER+CTRL+HOME | Bring the view back to the window that has keyboard focus. |
| SUPER+1…9 | Switch to a stratum by its hotkey. |
| SUPER+scroll | Same as SUPER+LEFT/RIGHT. SUPER+SHIFT+scroll switches stratum. |
| Three-finger swipe | Horizontal: pan along the row, settling on the step grid when you let go. Vertical: switch stratum. |
| SUPER+drag on empty space | Pan the view. |

When focus is on empty space, no window has keyboard focus. A window opened then appears in that slot.

All strata share one horizontal span: from the leftmost to the rightmost window on any of them. There is no empty space past it until a window is opened, moved or widened there; the view, swipes, SUPER+scroll and SUPER+drag stop at its ends. When it shrinks under you (the outermost window closes, moves away or moves in), the view goes to the nearest window. [Settings › Navigation › Blank space past the outermost windows](settings#navigation) brings back room to travel past it.

Switching strata focuses the window at the same position on the target stratum, or the window last focused there ([Settings › Navigation › Focus after switching stratum](settings#navigation)). Where the target stratum has no window at that position because all of its windows are off to one side, you land on empty space, or on its nearest window with **Landing past a stratum's windows** set to Nearest window.

Vertical wrapping (from the last stratum to the first) is on by default; horizontal wrapping is off. With **Wrap only when held**, a wrap needs a held key or a second press at the edge.

## Moving windows

| Keys | Action |
|---|---|
| SUPER+SHIFT+LEFT/RIGHT | Move the focused window's column one window step. A window that touches its neighbour stacks into the neighbour's column; a stacked window pops out into its own column on that side. |
| SUPER+CTRL+SHIFT+LEFT/RIGHT | Move the column by the fine step, without snapping. |
| SUPER+SHIFT+UP/DOWN | Move the window up or down within its column; at the top or bottom, move it to the stratum above or below at the same horizontal position (stacked into a column there, if one is at that position). |
| SUPER+SHIFT+1…9 | Move the window to that stratum and follow it. SUPER+SHIFT+ALT+1…9 moves it without following. |
| Drag with the mouse | Hyprland's normal drag; a tiled window dropped on empty space lands at the drop position. Dragging near a screen edge pans the view, up to a screen past the outermost windows. |
| SUPER+right drag, Omarchy's resize keys | Change the column's width, from a twentieth of a screen up to a full screen. It grows into empty space and pushes columns on that side along. Resizing from the keyboard keeps the window in view. |

## Strata

| Keys | Action |
|---|---|
| SUPER+RETURN | Launch the current stratum's app (a terminal by default, or the stratum's own command). The window stays on this stratum regardless of routing. |
| SUPER+` | Toggle the Games stratum (go there, or back to where you were). |

## Overview

SUPER+TAB opens the overview; SUPER+SHIFT+TAB opens it with the search field focused. Every stratum is shown as a band, labelled with its name and colour.

| Input | Action |
|---|---|
| Arrows | Move the selection, by the same rules as SUPER+arrows on the desktop. H/J/K/L too, with [Settings › Overview › Letter keys](settings#overview) set to Move with HJKL. |
| Enter, or click | Go to the selected window or empty slot. |
| Esc, right click, SUPER+TAB | Close and return to where you were. |
| Typing | Search window titles and classes; the first match is selected. Up/Down/Tab cycle through matches. With the letter keys moving the selection (HJKL), press `/` first. |
| Middle click | Close a window. |
| Drag a stratum name | Reorder the stack. |
| SHIFT+arrows | Move the selected window, by the SUPER+SHIFT+arrow rules (the view doesn't move). |
| CTRL+LEFT/RIGHT | Make the selected window's column a fine step narrower or wider. |

### Dragging windows

Drag a tiled window to move it. The live window follows the pointer, the windows it would displace slide aside, and an outline marks where it will land. The drop target depends on what is under the pointer:

| Pointer over | Result |
|---|---|
| The middle half of a window | Stack into that window's column: above it in the window's upper half, below it in the lower half. |
| The left or right quarter of a window | A column of its own, directly before or after that column. |
| Empty space | A column of its own at that position, flush against a neighbouring column within one window step, otherwise on the window-step grid. |

Drops work on every stratum, including empty ones. While you drag, the bands make room past the outermost windows, so a window can be dropped beyond them. Room is made by pushing columns to the right, never to the left; the place the window came from stays empty. Esc or a right click during a drag cancels it. After a drop the overview stays open with the window selected.

Grab a window within a few pixels of its left or right edge to resize its column instead. The width changes in fine steps (from one fine step to a full screen) while you drag; the opposite edge stays put, and columns on the growing side move aside.

Floating windows can't be dragged.

## Preview cross

The cross shows live thumbnails around a centre tile: the areas left and right of the view on the current stratum, and the strata above and below. By default it appears on every navigation and fades out shortly after; [Settings › Preview cross](settings#preview-cross) sets when it appears, where and how large.

## Picture in picture

When you leave a stratum while a video plays in one of its configured players (by default mpv, VLC, Celluloid, Totem and browser video sites on the Media stratum), a live copy of the video follows you in a small card on every stratum. The player window itself stays in its tile. Browsers are told they're fullscreen and get the `f` key there, so the page's video fills the window; the copy is then cropped to the picture (black bars trimmed, or cut to the moving part when page around the video still shows).

| Input | Action |
|---|---|
| Drag the card | Move it anywhere; it snaps flush to screen edges. |
| Drag an edge or corner, or scroll | Resize it. It keeps the video's shape. |
| Hover | Show the controls: the stratum's icon (go there), X (send the video home; it keeps playing), back and forward 10 seconds, play/pause, mute (a volume slider on hover), the seek bar and the time. |

A thin progress line runs along the bottom while the controls are hidden. The controls work over MPRIS; mute and volume act on the app's audio streams in PipeWire. A fullscreen window covers the card. Returning to the video's stratum, or the X, ends it. Each new card starts in the corner and at the size set in [Settings › Picture in picture](settings#picture-in-picture).
