#!/bin/bash
# Screenshot the nested test output: shot.sh [file.png] (default: $RUN/shots/<time>.png)
. "$(dirname "$(readlink -f "$0")")/env.sh"
SOCK=$("$T/nested-sock.sh") || exit 1
OUT=${1:-$RUN/shots/$(date +%H%M%S).png}
WAYLAND_DISPLAY=$SOCK timeout 5 grim -o STRATATEST -t png "$OUT" && echo "$OUT"
