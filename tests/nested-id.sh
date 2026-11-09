#!/bin/bash
# Prints the instance signature of the nested Hyprland, or fails. It is the one
# start.sh recorded, still running, and never the live session's own.
. "$(dirname "$(readlink -f "$0")")/env.sh"
LIVE=${STRATA_LIVE_SIG:-${HYPRLAND_INSTANCE_SIGNATURE:-}}
N=$(cat "$RUN/nested.sig" 2>/dev/null)
[ -n "$N" ] || { echo "no nested instance (tests/start.sh)" >&2; exit 1; }
[ "$N" != "$LIVE" ] || { echo "refusing: that is the live session" >&2; exit 1; }
hyprctl instances | grep -q "^instance $N:" || { echo "nested instance $N is gone" >&2; exit 1; }
echo "$N"
