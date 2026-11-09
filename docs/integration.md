---
title: Integration
nav_order: 6
---

# Integration
{: .no_toc }

Interfaces for scripts, bar widgets and other plugins.

1. TOC
{:toc}

## Lua module

`require("hypr.strata")` returns Strata's Lua module inside Hyprland, so scripts can drive it with `hyprctl eval`:

```bash
hyprctl eval 'require("hypr.strata").go("browser")'      # switch to a stratum by id
hyprctl eval 'require("hypr.strata").send("chat", true)' # move the focused window there and follow
hyprctl eval 'require("hypr.strata").overview()'         # toggle the overview
```

| Function | Action |
|---|---|
| `go(id)` | Switch to a stratum (`"@free"` for the free block). |
| `toggle(id)` | Switch to a stratum, or back to the previous one if already there. |
| `send(id, follow)` | Move the focused window to a stratum, keeping its horizontal position. |
| `nav(dir)` | SUPER+LEFT/RIGHT (`"l"` or `"r"`). |
| `focus_up()`, `focus_down()`, `move_up()`, `move_down()` | SUPER+UP/DOWN and SUPER+SHIFT+UP/DOWN. |
| `nudge(dir)` | Fine step. |
| `home()` | Back to the focused window. |
| `overview()`, `overview_search()` | Toggle the overview. |
| `primary()` | SUPER+RETURN. |
| `migrate()`, `unmigrate()` | Route open windows to their strata / undo it. |
| `config()` | The merged configuration table. |
| `stack()` | The stack, top to bottom, as workspace selectors. |

## Native API

The Hyprland plugin registers `hl.plugin.strata.*` for the Lua module. These are the grid primitives; scripts can use them too.

| Function | Action |
|---|---|
| `state()` | The view on the focused monitor: `camera`, `x`, `w` (cursor slot), `blank`, `workspace`, `lo`/`hi` (grid extent), `step`, `view_step`. |
| `columns(workspace_id)` | That stratum's columns: `x`, `w` (width shown), `cw` (column width) and `windows` (addresses, top to bottom). |
| `place(address, x)` | Move a window's column to grid position `x`; columns it overlaps move right. |
| `width(address, w)` | Set a window's column width (screen widths). |
| `join(address, into_address)` | Stack a window into another window's column. |
| `reveal(address)` | Focus a window and bring it into view. |
| `aim(x, w)` | Put the cursor on empty space at `x` (or the window there). |
| `pan(du)`, `settle()` | Move the camera; snap it to the step grid. |
| `move_window(address, dir)`, `widen(address, dir)` | SUPER+SHIFT+arrow moves and column resizing for any window, without moving the view. |
| `expect(address, x, stack, dir)` | Where a window about to move to another stratum should land. |
| `match(regex, subject)` | ECMAScript regex full match (as in Hyprland window rules). |

Positions and widths are in screen widths of the usable area. The full list, with arguments, is at the end of [`native/src/main.cpp`](https://github.com/Reflectionist/omarchy-strata/blob/main/native/src/main.cpp).

## Events

The plugin posts events on Hyprland's event socket (`$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock`):

| Event | When | Data |
|---|---|---|
| `strata>>{…}` | The view changes | `ws`, `camera`, `x`, `w`, `blank`, `lo`, `hi`, `margin`, `slot`, `cols`, `mon` |
| `strata-cross>>{…}` | The preview cross shows, moves or hides | Tile boxes and the strata they show |
| `strata-overview>>{…}` | The overview opens, closes or its layout changes | Transform, rows and window boxes |
| `strata-overview-drag>>{…}` | A drag in the overview starts, changes target or ends | Landing box and kind |
| `custom>>strata-pip>>{…}` | A player pops out or returns | `open`, `a` (address), `class` |

Socket events are limited to 1024 bytes. A larger payload is written to `$XDG_RUNTIME_DIR/strata-<event>-<pid>-<n>.json` and the event carries `@<path>` instead of JSON. Only the latest few files per event are kept.

## Shell IPC

The shell plugin answers on the Omarchy shell's IPC (`omarchy-shell <target> <function>`, or `qs -p /usr/share/omarchy/shell ipc call <target> <function>`):

| Target | Function | Action |
|---|---|---|
| `strata` | `settings` | Toggle the settings window. |
| `strata` | `showSettings <page>` | Open a settings page (`strata`, `navigation`, `cross`, `overview`, `glyph`, `wallpaper`, `pip`, `setup`, or `strata:<id>` for a stratum's page). |
| `strata` | `hideSettings` | Close it. |
| `strata` | `current` | The current stratum as JSON. |
| `strata` | `stackJson` | The stack as JSON. |
| `strataOverview` | `state`, `windows`, `move <dir>`, `enter` | Inspect and drive the overview's selection (used by the tests). |

## Picture-in-picture handlers

When a browser window pops out, Strata sends it the `f` key so the page's video fills the window. A tool that does this better (for example a browser extension listening for `strata-pip` events) can claim a window class by adding a line to `$XDG_RUNTIME_DIR/strata-pip-handlers`:

```
<pid> <window class regex>
```

While that process runs, Strata sends no keys to matching windows and leaves the video to the tool.
