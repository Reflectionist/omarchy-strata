---
title: Installation
nav_order: 2
---

# Installation
{: .no_toc }

1. TOC
{:toc}

## Requirements

- Omarchy 4 with Hyprland 0.56 or newer, using the Lua configuration (`~/.config/hypr/hyprland.lua`).
- Hyprland's development headers. They ship with Arch's `hyprland` package (`/usr/include/hyprland`).
- `gcc` 14 or newer, `make`, `pkgconf` and `jq`. On Omarchy: `omarchy pkg add base-devel pkgconf jq` if any is missing.

## Add the plugin

```bash
omarchy plugin add https://github.com/Reflectionist/omarchy-strata --enable
```

This clones the repository into `~/.config/omarchy/plugins/io.github.reflectionist.strata` and enables the shell plugin. Its bar widget appears in the left section of the bar. At this point nothing outside the plugin folder has changed, and Hyprland still uses its own layout.

## Connect

Click the bar icon, open **Setup** and choose **Connect**, or run the script directly:

```bash
~/.config/omarchy/plugins/io.github.reflectionist.strata/bin/strata-setup
```

Setup runs these steps in order:

1. **Checks** the requirements above and stops with an install hint if something is missing.
2. **Builds** the Hyprland plugin from `native/` into `~/.local/share/strata/` (about a minute). Building happens outside the plugin folder, because any write inside it makes the Omarchy shell reload its plugins.
3. **Writes `~/.config/hypr/strata.lua`**, a short loader that runs `lua/strata.lua` from the plugin folder and does nothing if the plugin is removed. An existing file of that name that Strata didn't write is only replaced if you agree, with a backup.
4. **Asks to add one line** at the end of `~/.config/hypr/hyprland.lua`:

   ```lua
   require("default.hypr.require_optional").module("hypr.strata")
   ```

   It goes last because Strata's layout, animations and key bindings must override Omarchy's defaults. The file is backed up first (`hyprland.lua.bak.strata-<date>`); a symlinked `hyprland.lua` stays a symlink.
5. **Asks about two optional Omarchy hooks**:
   - `~/.config/omarchy/hooks/post-update.d/strata-rebuild` rebuilds the plugin after Omarchy updates Hyprland.
   - `~/.config/omarchy/hooks/theme-set.d/60-strata-capture` saves a theme picked with Omarchy's theme picker to the current stratum (needed for per-stratum themes; see [Settings](settings#themes--wallpapers)).
6. **Starts Strata** by reloading Hyprland.

`--yes` answers every question with yes, for scripted installs.

### First run

New windows are routed to their strata as they open. Windows that were already open stay where they are until you choose **Setup › Route open windows**; **Undo** next to it puts them back.

## Updating

```bash
omarchy plugin update io.github.reflectionist.strata
```

The QML and Lua parts take effect after `omarchy restart shell` and `hyprctl reload`. If the update changed the C++ source, **Setup** reports the plugin as out of date: choose **Rebuild**, or run `bin/strata-setup --rebuild`. A rebuild swaps the new plugin into the running session and restores every window's position, column width and stacking.

Hyprland updates need a rebuild too, because a Hyprland plugin is built against one Hyprland version. With the post-update hook enabled this happens automatically after `omarchy update`. Otherwise, after a Hyprland update, Strata shows a notification at login and Hyprland keeps its own layout until you rebuild.

## Removal

1. Choose **Setup › Disconnect**, or run:

   ```bash
   ~/.config/omarchy/plugins/io.github.reflectionist.strata/bin/strata-setup --remove
   ```

   This removes the `hyprland.lua` line (with a backup), `~/.config/hypr/strata.lua`, the hooks Strata installed and `~/.local/share/strata`, then reloads Hyprland, which unloads the plugin and returns to its own layout. Your settings in `~/.config/strata` stay; `--purge` deletes them too, with Strata's state and caches.

2. Remove the shell plugin:

   ```bash
   omarchy plugin remove io.github.reflectionist.strata
   ```

## Troubleshooting

**"Strata is not running" at login.** The built plugin doesn't match the running Hyprland (usually after a Hyprland update). Choose **Setup › Rebuild**.

**The build fails.** The last lines of the compiler output are shown, and the full log is in `~/.local/share/strata/build.log`. Check that `pkg-config --modversion hyprland` prints the running Hyprland version.

**Settings changes don't apply.** Settings are written to `~/.config/strata/strata.json` and Hyprland re-reads the configuration a moment later. `hyprctl configerrors` shows Lua errors.

**Shell changes don't appear after an update.** The Omarchy shell keeps compiled QML in memory; run `omarchy restart shell`.

**Status at a glance.** `bin/strata-setup --status` prints one line of JSON: whether the plugin is built, current, loaded and connected, and which hooks are installed.
