---
title: Settings
nav_order: 4
---

# Settings
{: .no_toc }

Open the settings with a left click on the bar icon. Changes are saved to `~/.config/strata/strata.json` (only what you change; see [Configuration file](configuration)) and Hyprland applies them a moment later.

1. TOC
{:toc}

## Strata

The stack: every stratum from top to bottom, plus the block of free strata. Drag to reorder, add a stratum, or open one to edit it. Free strata are numbered workspaces; with **Dynamic free strata** on, the block holds the ones in use plus one empty stratum, otherwise a fixed number (**Free strata count**).

### A stratum's page

**General**

| Setting | Effect |
|---|---|
| Name, Icon | Shown in the bar, the overview and the preview cross. The outline icon is used when the stratum is inactive, the filled one when it is current. Icons come from Nerd Fonts, emoji or an image file. |
| Color | Accent color for its name and icon, taken from the stratum's theme (or a fixed palette color). |
| Hotkey | SUPER+key switches to the stratum; SUPER+SHIFT+key moves the focused window to it. |

**Apps** (routing)

| Setting | Effect |
|---|---|
| App categories | Freedesktop categories (for example `TerminalEmulator`, `WebBrowser`, `Game`) whose apps open on this stratum. |
| Apps | Installed apps, open windows or window class regexes that open on this stratum. Exact app rules become Hyprland window rules, so those windows map directly onto the stratum. |
| Follow routed windows | Switch to this stratum when a window routed here opens. |
| Suggestions | Windows you moved here by hand, as candidate rules: **Add rule** keeps it, **Dismiss** ignores it. |

When more than one stratum matches a window, an exact app rule beats an app category, then the stack order decides.

**SUPER+RETURN**

| Setting | Effect |
|---|---|
| Launches | Terminal, browser, Steam, or a command. The window it opens stays on this stratum regardless of routing rules. |
| Working directory | Start directory for terminals launched with SUPER+RETURN. |
| Autostart | Commands run on the first visit to this stratum after login, one per line. |

**Profile**

| Setting | Effect |
|---|---|
| Private | Its windows are drawn as placeholder cards in the preview cross and the overview. |
| Audio output | Default audio output while this stratum is active; the previous output is restored when you leave. |

**New windows**

| Setting | Effect |
|---|---|
| Open fullscreen | Window class regex; matching windows open fullscreen on this stratum. |
| Float, Maximize | Open new windows on this stratum floating or maximized. |
| Default column width | Width of new columns on this stratum. |

**Appearance**: inner gaps, outer gaps, border width, rounding and window opacity for this stratum only (Hyprland workspace rules).

**Theme & wallpaper**: the stratum's own Omarchy theme and wallpaper, used while per-stratum themes are on.

**Picture in picture**

| Setting | Effect |
|---|---|
| Pop out video players | When you leave this stratum while a matching player is playing, its window follows you as a pinned corner window. |
| Players | Window class regexes, separated by spaces. |

## Navigation

| Setting | Default | Effect |
|---|---|---|
| Focus step | 0.5 | Distance SUPER+LEFT/RIGHT moves through empty space, in screen widths. |
| Window step | 0.5 | Distance SUPER+SHIFT+LEFT/RIGHT moves a window. Columns snap to multiples of it. |
| Fine step | 0.125 | Distance SUPER+CTRL+SHIFT+LEFT/RIGHT moves a window, without snapping. Also the overview's resize step. |
| Jump distance | 2 | Most empty space, in focus steps, that SUPER+LEFT/RIGHT skips to reach the next window. |
| Blank space past the outermost windows | 0 | How far focus and the view can go past the leftmost and rightmost window on any stratum, in focus steps. At 0 there is no space there until a window is opened, moved or widened into it. |
| Wrap between first and last stratum | on | SUPER+UP on the top stratum goes to the bottom one, and the reverse. |
| Wrap at the ends of a row | off | SUPER+RIGHT at the right end goes to the first window of the row, and the reverse. |
| Wrap only when held | off | At an edge, wrap only on a held key or a second press. |
| Focus after switching stratum | Window at the same position | Or the last focused window on that stratum. |
| Landing past a stratum's windows | Stay on blank | Switching to a stratum whose windows are all off to one side of the view: stay on empty space, or go to its nearest window. |
| When a column closes | Leave empty space | Or shift later columns left. Moving a window to another stratum counts as closing it there, except for overview drops. |
| Empty-space indicator | Reticle and ruler | What marks the selected slot when focus is on empty space. |

### Key bindings

Each group of Strata's bindings can be turned off, which leaves those keys to Omarchy's own bindings: grid navigation, stratum hotkeys, overview, SUPER+RETURN, scroll wheel, touchpad gestures.

## Preview cross

| Setting | Default | Effect |
|---|---|---|
| Shown on | Every navigation | Or while SUPER is held, stratum changes only, SUPER held alone, or never. |
| Position | Bottom | Bottom center, center, or top left. |
| Size | 16% | Width of the center tile, as a fraction of the screen. |
| Hide after | 800 ms | How long it stays after the last move. |

## Overview

| Setting | Default | Effect |
|---|---|---|
| Letter keys | Search | Search: typing searches titles and apps right away. Move with HJKL: H, J, K and L move the selection like the arrows, and `/` starts a search. |

The page also lists the keys and mouse actions (see [Usage](usage#overview)).

## Bar widget

| Setting | Effect |
|---|---|
| Change animation | How the icon changes with the stratum: slide, crossfade, flip or none. |
| Icon style | Auto uses the filled icon and leaves restyling to bar icon plugins; Outline and Filled force one variant. |

## Themes & wallpapers

| Setting | Default | Effect |
|---|---|---|
| Per-stratum themes | on | Apply each stratum's theme and wallpaper when it becomes active. Off: one theme and wallpaper for all strata, set with Omarchy's pickers. |
| Per-stratum wallpapers | off | Shown when per-stratum themes are off: assigns the current theme's wallpapers to strata in stack order, starting from the one picked for the current stratum. |
| App retint delay | 1.5 s | The bar, borders and terminals update immediately; other applications are retinted after this delay, so passing through strata doesn't retint everything. |
| Base theme, Base wallpaper | | Used by strata without their own. |
| Stratum change | Crossfade | Wallpaper transition between strata: crossfade, slide, or parallax (the wallpaper moves slower than the windows). |
| Horizontal parallax | off | Shifts the wallpaper slightly while you pan along a stratum. |

With per-stratum themes on and the theme hook installed (see [Installation](install#connect)), a theme or wallpaper picked with Omarchy's pickers is saved to the current stratum. Themes are cached under `~/.cache/strata/themes` the first time they are applied, which makes later switches fast.

## Picture in picture

| Setting | Default | Effect |
|---|---|---|
| Corner | Bottom right | Where popped-out windows go. Each app's last position and size are remembered. |
| Size | 25% | Initial width, as a fraction of the screen. |
| Avoid the focused window | off | Moves to the opposite side when it overlaps the focused window. |
| Show seek bar | on | A slim seek bar under the window. |

Which players pop out is set per stratum, on its page.

## Setup

Plugin status (built, current, connected, running, hooks), the **Connect**, **Rebuild** and **Disconnect** actions (see [Installation](install)), and **Route open windows** with its **Undo**.
