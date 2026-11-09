#!/bin/bash
# Swap a fresh build into the NESTED instance the way strata-setup --rebuild
# does it live: replace the loaded file with a new inode, then strata-swap
# (snapshot the grid, unload, load, restore).
. "$(dirname "$(readlink -f "$0")")/env.sh"
N=$("$T/nested-id.sh") || exit 1
export STRATA_LIVE_SIG=$HYPRLAND_INSTANCE_SIGNATURE
export HYPRLAND_INSTANCE_SIGNATURE=$N
make -C "$ROOT/native" BUILD="$RUN/build" >/dev/null || exit 1
cp "$RUN/build/hypr-strata.so" "$RUN/current.so.new"
mv -f "$RUN/current.so.new" "$RUN/current.so"
"$ROOT/bin/strata-swap" "$RUN/current.so"
