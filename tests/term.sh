#!/bin/bash
# Open a labelled test terminal (foot) in the nested instance: term.sh <label> [app-id] [rrggbb]
. "$(dirname "$(readlink -f "$0")")/env.sh"
SOCK=$("$T/nested-sock.sh") || exit 1
BG=${3:-$(printf '%s' "$1" | md5sum | cut -c1-6)}
WAYLAND_DISPLAY=$SOCK setsid foot -o "colors-dark.background=$BG" -o colors-dark.foreground=000000 -o main.font=monospace:size=28 \
  --app-id "${2:-stratatest}" --title "$1" sh -c "printf '\n  $1\n'; sleep 100000" >/dev/null 2>&1 &
sleep 0.6
