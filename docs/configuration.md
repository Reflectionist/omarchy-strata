---
title: Configuration file
nav_order: 5
---

# Configuration file
{: .no_toc }

1. TOC
{:toc}

Strata reads two JSON files and merges them, the second winning key by key:

1. `config/defaults.json` in the plugin folder: every setting with its default. Updated with the plugin; don't edit it.
2. `~/.config/strata/strata.json`: your changes. The settings window writes only what differs from the defaults, so a fresh install has an almost empty file.

Hyprland re-reads the configuration a moment after the file changes, and the shell plugin watches it too, so hand edits take effect without a restart. Objects merge recursively; arrays and other values replace the default.

## Example

```json
{
  "version": 1,
  "stack": ["terminal", "agents", "browser", "code", "@free", "chat", "media", "games"],
  "strata": {
    "agents": {
      "name": "Agents",
      "icon": "󰚩",
      "iconActive": "󰚩",
      "workspace": "name:agents",
      "hotkey": "2",
      "match": { "apps": ["^my-agent-app$"] },
      "profile": { "windows": { "column_width": 1 } }
    },
    "code": { "hotkey": "4" }
  },
  "navigation": { "fine_step": 0.1, "close_gap": true },
  "keys": { "gestures": false }
}
```

## Top-level keys

| Key | Type | Meaning |
|---|---|---|
| `version` | number | File format version (1). |
| `stack` | array of strings | The strata from top to bottom: stratum ids, plus `"@free"` for the block of free strata. |
| `strata` | object | The named strata, by id (see below). |
| `free` | object | The free strata block (see below). |
| `navigation` | object | Steps, wrapping and focus behaviour. |
| `keys` | object | Which groups of key bindings Strata takes over. |
| `cross` | object | The preview cross. |
| `overview` | object | The overview. |
| `glyph` | object | The bar widget. |
| `blank` | object | The empty-space indicator. |
| `themes` | object | Per-stratum themes and wallpapers. |
| `pip` | object | Picture in picture placement. |
| `learned` | array | Title rules you added from suggestions. |
| `suggestions` | array | Dismissed suggestions. |

## `strata.<id>`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | | Display name. |
| `icon`, `iconActive` | string | | Icon when inactive / current: a Nerd Font glyph, an emoji, or the path of an SVG or PNG image (monochrome SVGs take the accent color). |
| `accent` | string | `"accent"` | Color role from the stratum's theme palette (`accent`, `foreground`, `red`, `bright_blue`, ...). |
| `workspace` | string | | The Hyprland workspace: `"name:<name>"`. |
| `hotkey` | string | | Key for SUPER+key (`"1"`…`"9"`, a letter, or a key name such as `"grave"`). |
| `extraHotkeys` | array | `[]` | More keys; these toggle (go there, or back where you were). |
| `follow` | boolean | `true` | Switch here when a routed window opens. |
| `primary` | string | `""` | What SUPER+RETURN launches: `"terminal"`, `"browser"`, `"steam"`, or a command. Empty: terminal. |
| `cwd` | string | | Working directory for its terminal. |
| `match.types` | array | | Freedesktop app categories routed here. |
| `match.apps` | array | | Window class regexes (full match) routed here. |
| `match.titles` | array | | Window title regexes routed here. |
| `theme` | string or null | `null` | Omarchy theme name for this stratum. |
| `wallpaper` | string or null | `null` | Wallpaper path for this stratum; `null` uses the theme's. |
| `pip.enabled` | boolean | `false` | Pop out players when leaving. |
| `pip.apps` | array | `[]` | Player window class regexes. |
| `profile.private` | boolean | `false` | Draw its windows as placeholder cards in previews. |
| `profile.audio_output` | string | `""` | PulseAudio/PipeWire sink name to switch to while active. |
| `profile.autostart` | array | `[]` | Commands run on the first visit after login. |
| `profile.fullscreen` | string | `""` | Window class regex for windows that open fullscreen. |
| `profile.windows.float`, `.maximize` | boolean | `false` | New windows open floating / maximized. |
| `profile.windows.column_width` | number | | Width of windows that open on this stratum (screen widths, 0.05–1). A window routed elsewhere as it opens, or moved here later, doesn't get it; an app's own `scrolling_width` window rule wins. |
| `profile.look.gaps_in`, `.gaps_out`, `.border_size`, `.rounding`, `.opacity` | number | | Appearance overrides for this stratum. |

The default strata are `terminal`, `code`, `browser`, `notes`, `chat`, `media`, `creative` and `games`, with hotkeys 1–4 and 6–9 and the free block on 5.

## `free`

| Key | Default | Meaning |
|---|---|---|
| `dynamic` | `true` | Create free strata on demand (the ones in use plus one empty one). |
| `count` | `5` | Number of free strata when not dynamic. |
| `name`, `accent`, `hotkey`, `primary`, `theme`, `wallpaper` | | As for a named stratum; the hotkey goes to the first free stratum. |

## `navigation`

| Key | Default | Meaning |
|---|---|---|
| `view_step` | `0.5` | Focus step through empty space (screen widths). |
| `step` | `0.5` | Window step; columns snap to its multiples. |
| `fine_step` | `0.125` | Fine step (nudges, overview resizing). |
| `jump_near` | `2` | Jump distance, in focus steps. |
| `margin` | `0` | Blank space past the leftmost and rightmost window on any stratum, in focus steps (how far focus and the view can go past them). |
| `wrap_vertical` | `true` | Wrap between the first and last stratum. |
| `wrap_horizontal` | `false` | Wrap at the ends of a row. |
| `wrap_hold` | `false` | Wrap only on a held key or a second press. |
| `land_focus` | `"grid"` | Focus after switching stratum: `"grid"` (same position) or `"last"`. |
| `land_past` | `"blank"` | Switching to a stratum whose windows are all off to one side of the view: `"blank"` (stay on empty space) or `"nearest"` (its nearest window). |
| `close_gap` | `false` | Shift later columns left when a column closes. |

## `keys`

All `true` by default. `false` leaves those keys to Omarchy.

| Key | Bindings |
|---|---|
| `grid` | SUPER+arrows, SUPER+SHIFT+arrows, SUPER+CTRL+SHIFT+LEFT/RIGHT, SUPER+CTRL+HOME |
| `strata` | Stratum hotkeys with SUPER, SUPER+SHIFT and SUPER+SHIFT+ALT |
| `overview` | SUPER+TAB, SUPER+SHIFT+TAB |
| `launch` | SUPER+RETURN |
| `wheel` | SUPER+scroll, SUPER+SHIFT+scroll |
| `gestures` | Three-finger swipes |

## Other sections

| Key | Default | Meaning |
|---|---|---|
| `cross.trigger` | `"move"` | `"move"`, `"held"`, `"change"`, `"hold"` or `"off"`. |
| `cross.placement` | `"bottom"` | `"bottom"`, `"center"` or `"topleft"`. |
| `cross.size` | `0.16` | Center tile width (fraction of the screen). |
| `cross.fade_ms` | `800` | Time it stays after the last move. |
| `overview.search_on_shift` | `true` | SUPER+SHIFT+TAB opens the overview with search. |
| `overview.letters` | `"search"` | Letter keys in the overview: `"search"` (typing searches) or `"hjkl"` (H/J/K/L move the selection; `/` starts a search). |
| `glyph.animation` | `"cage"` | `"cage"` (slide), `"crossfade"`, `"flip"` or `"none"`. |
| `glyph.outline` | `"auto"` | `"auto"`, `"outline"` or `"filled"`. |
| `blank.look` | `"both"` | `"both"`, `"reticle"`, `"ruler"` or `"none"`. |
| `themes.switching` | `true` | Per-stratum themes and wallpapers. |
| `themes.auto_wallpapers` | `false` | Per-stratum wallpapers from the current theme (with switching off). |
| `themes.base`, `themes.base_wallpaper` | `null` | Theme and wallpaper for strata without their own. |
| `themes.wallpaper_vertical` | `"crossfade"` | `"crossfade"`, `"slide"` or `"parallax"`. |
| `themes.wallpaper_parallax` | `false` | Horizontal parallax. |
| `themes.parallax_strength` | `0.08` | Parallax amount. |
| `themes.settle_ms` | `1500` | App retint delay. |
| `pip.corner` | `"bottom-right"` | Where each new card starts: `"top-left"`, `"top-right"`, `"bottom-left"` or `"bottom-right"`. |
| `pip.width` | `0.25` | Each new card's width (fraction of the screen). |
| `pip.avoid_focus` | `false` | Move away from the focused window. |
| `pip.seek_bar` | `true` | Show the thin progress line while the controls are hidden. |
