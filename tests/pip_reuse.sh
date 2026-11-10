#!/bin/sh
# Runs tests/pip_reuse.lua with a scratch runtime dir (no Hyprland needed).
set -e
cd "$(dirname "$0")/.."
dir=$(mktemp -d "${TMPDIR:-/tmp}/pip_reuse.XXXXXX")
trap 'rm -rf "$dir"' EXIT
XDG_RUNTIME_DIR=$dir HYPRLAND_INSTANCE_SIGNATURE=test STRATA_CONFIG_DIR="$PWD/tests" exec lua tests/pip_reuse.lua
