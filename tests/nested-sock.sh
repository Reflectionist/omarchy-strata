#!/bin/bash
# Prints the nested Hyprland's Wayland socket name (e.g. wayland-2), or fails.
. "$(dirname "$(readlink -f "$0")")/env.sh"
N=$("$T/nested-id.sh") || exit 1
S=$(hyprctl instances | awk -v n="$N" '/^instance/{i=$2; sub(":","",i)} /wl socket:/{if (i==n) print $3}')
[ -n "$S" ] || { echo "no socket for $N" >&2; exit 1; }
echo "$S"
