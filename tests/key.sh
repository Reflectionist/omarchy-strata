#!/bin/bash
# Type into the NESTED instance only (never the live one): key.sh <wtype args...>
# e.g. key.sh -M logo -k Tab -m logo     key.sh -k Right
. "$(dirname "$(readlink -f "$0")")/env.sh"
SOCK=$("$T/nested-sock.sh") || exit 1
WAYLAND_DISPLAY=$SOCK wtype "$@"
