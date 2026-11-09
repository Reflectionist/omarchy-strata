#!/bin/bash
# hyprctl against the nested instance only: h.sh eval '<lua>'
. "$(dirname "$(readlink -f "$0")")/env.sh"
N=$("$T/nested-id.sh") || exit 1
exec hyprctl -i "$N" "$@"
