#!/bin/bash
# The pointer in the NESTED instance (a virtual pointer, built from vptr/ on
# first use). Coordinates are in an 1800x1125 layout: nested pixels x 1.25.
#   pointer.sh X Y [left|right|middle|none]
#   DRAG_TO=X2,Y2 [DRAG_HOLD_US=…] [DRAG_CANCEL=1] pointer.sh X Y left   (press, glide, release)
. "$(dirname "$(readlink -f "$0")")/env.sh"
SOCK=$("$T/nested-sock.sh") || exit 1
V="$RUN/vptr"
if [ ! -x "$V/vptr" ] || [ "$T/vptr/vptr.c" -nt "$V/vptr" ]; then
  mkdir -p "$V"
  wayland-scanner client-header "$T/vptr/vp.xml" "$V/vp-client.h" &&
    wayland-scanner private-code "$T/vptr/vp.xml" "$V/vp-protocol.c" &&
    gcc -O2 -I"$V" -o "$V/vptr" "$T/vptr/vptr.c" "$V/vp-protocol.c" $(pkg-config --cflags --libs wayland-client) || exit 1
fi
WAYLAND_DISPLAY=$SOCK exec "$V/vptr" "$@"
