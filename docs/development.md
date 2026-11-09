---
title: Development
nav_order: 7
---

# Development
{: .no_toc }

1. TOC
{:toc}

## Repository layout

| Path | Contents |
|---|---|
| `manifest.json` | Omarchy plugin manifest (service and bar widget). |
| `shell/` | QML for the Omarchy shell: `Service.qml` (entry point), `Widget.qml` (bar widget), `StrataState.qml` (config, palette, stack), `OverviewLayer.qml`, `Overlays.qml`, `PipLayer.qml`, `SettingsWindow.qml` and `settings/`. |
| `lua/strata.lua` | The Hyprland Lua module: key bindings, stack order, routing, profiles, themes, wallpapers, picture in picture, overview glue. |
| `native/` | The Hyprland plugin (C++26), built with `make`. |
| `bin/` | `strata-setup` (build, connect, remove), `strata-swap` (hot swap), `strata-theme`, `strata-capture`, `strata-profile`. |
| `config/defaults.json` | Every setting's default. |
| `tests/` | The nested Hyprland test harness. |
| `docs/` | This site (Jekyll with Just the Docs). |

## Architecture

**Layout.** `CStrataAlgorithm` (`native/src/layout.cpp`) derives from Hyprland's scrolling layout, so everything that understands scrolling layouts (Lua's `w.layout`, scrolling's layout messages) keeps working. It adds an absolute x per column in a side table and places windows itself: a hook on `SScrollingData::recalculate`, which every placement path goes through, positions columns against one camera per monitor (`native/src/view.cpp`). Units are screen widths of the usable area.

**Rendering.** The preview cross (`cross.cpp`) and the overview (`overview.cpp`) draw live windows by rendering each one with Hyprland's `renderWindow` into a private render pass, scaled and clipped to its tile. Windows on hidden workspaces are drawn too, with frame callbacks sent so they keep updating. Wallpapers (`wallpaper.cpp`) are decoded on a worker thread and drawn at `RENDER_POST_WALLPAPER` with each workspace's own slide offset. Slide directions follow the stack order, through hooks on `CMonitor::changeWorkspace` and the workspace animation.

**Overview drag.** The shell only reports start, drop and cancel; the plugin follows the pointer every frame, computes the landing from the grid (`landingFor`), builds a preview of the displaced windows (`buildPreview`) and applies exactly that on drop. Drops on another stratum go through Lua as an ordinary window move, with an `expect` record so the window arrives at the previewed position.

**Lua.** `lua/strata.lua` runs on every Hyprland config parse (`~/.config/hypr/strata.lua` loads it with the plugin folder as its argument). It loads the plugin, sets the layout and its options, binds keys, writes routing window rules, and handles events (`workspace.active`, `window.open`, ...). Hyprland discards Lua state on every reload, so anything that must survive one is kept in files under `$XDG_RUNTIME_DIR` or `~/.local/state/strata`.

**Shell.** The QML side reads the same configuration files, listens to the plugin's events, and calls back into Lua with `hyprctl eval`. Calls that must arrive in order (a drag's start before its drop) go through a queue.

## Building

```bash
make -C native                 # builds native/build/hypr-strata.so
make -C native flags           # compile_flags.txt for clangd
bin/strata-setup --rebuild     # build into ~/.local/share/strata and swap into the session
```

The plugin must be built against the exact Hyprland it runs in; `PLUGIN_INIT` refuses to load on a version mismatch. `-fno-gnu-unique` is required so the plugin can be unloaded.

Unloading a plugin that registered render pass elements must remove them first (`m_renderPass.removeAllOfType`): the previous frame's elements are destroyed at the next frame, by which time the plugin's code is gone.

## Test harness

The tests run Strata in a second Hyprland nested inside your session, on a headless output, so they never touch your windows and work with the screen off. Runtime files go to `$XDG_RUNTIME_DIR/strata-test`.

```bash
tests/start.sh       # nested Hyprland with a fresh build and tests/strata.test.json
tests/populate.sh    # a standard grid of coloured test terminals (foot)
tests/qs.sh          # the shell plugin, in a private Quickshell, against the nested instance
tests/ov.sh state | windows | move <dir> | enter    # the overview over IPC
tests/st.sh          # view state and columns
tests/shot.sh        # screenshot of the test output
tests/key.sh -k Right                  # keys (wtype), nested instance only
tests/pointer.sh X Y left              # pointer clicks; DRAG_TO=X2,Y2 for drags
tests/h.sh eval '…'  # hyprctl against the nested instance only
tests/swap.sh        # rebuild and hot-swap into the nested instance
tests/stop.sh        # stop it and report a crash
```

The nested instance's configuration is `tests/nested.lua`. It replaces commands that would reach your session (theme switches, audio profiles, notifications) with no-ops. Keys sent with `wtype` reach windows but don't trigger Hyprland key bindings; open the overview with `tests/h.sh eval 'require("hypr.strata").overview()'`. Pointer coordinates are in an 1800×1125 space (the 1440×900 test output scaled by 1.25).

Requirements: `foot`, `grim`, `wtype`, `jq`, `wayland-scanner` and `gcc`.
