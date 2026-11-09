#!/bin/bash
# Run Strata's shell side (overlays, overview, settings) in a private
# Quickshell against the NESTED Hyprland. Its QML reads ~/.config/strata like
# the real one. The config folder is assembled in $RUN/qs (links to Omarchy's
# shell modules and to this plugin).
. "$(dirname "$(readlink -f "$0")")/env.sh"
N=$("$T/nested-id.sh") || exit 1
SOCK=$("$T/nested-sock.sh") || exit 1
pkill -f "quickshell -p $RUN/[q]s" 2>/dev/null
OMA="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
rm -rf "$RUN/qs" && mkdir -p "$RUN/qs"
cp "$T/qs/shell.qml" "$RUN/qs/shell.qml"
ln -s "$OMA/Commons" "$RUN/qs/Commons"
ln -s "$OMA/Ui" "$RUN/qs/Ui"
ln -s "$ROOT" "$RUN/qs/strata"
cd "$RUN/qs" && (WAYLAND_DISPLAY=$SOCK HYPRLAND_INSTANCE_SIGNATURE=$N setsid quickshell -p "$RUN/qs" >"$RUN/qs.log" 2>&1 &)
sleep 2.5
grep -i "error\|warn\|fail" "$RUN/qs.log" | grep -v "outside of the config\|host portal" | head -10
