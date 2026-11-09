#!/bin/bash
# Start the nested test Hyprland with a fresh build of the plugin and wait
# until its test output exists. Run it from inside your Hyprland session.
#
# Kept apart from the session you're in:
#   - HYPRLAND_NO_SD_VARS/NOTIFY keep it out of the user manager's
#     environment (a test Hyprland otherwise exports its WAYLAND_DISPLAY there);
#   - a temporary window rule in your session sends its window to a hidden
#     special workspace, so it never lands in one of your strata;
#   - it draws on a headless output (STRATATEST, 1440x900) inside it, which
#     renders on its own timer: screenshots work even while your screen is
#     off or the window is hidden (tests/shot.sh).
set -eu
. "$(dirname "$(readlink -f "$0")")/env.sh"
LIVE=${HYPRLAND_INSTANCE_SIGNATURE:?run this from inside a Hyprland session}
"$T/nested-id.sh" >/dev/null 2>&1 && { echo "a nested instance is already running (tests/stop.sh)" >&2; exit 1; }
make -C "$ROOT/native" BUILD="$RUN/build" >/dev/null
rm -f "$RUN/current.so" "$RUN/nested.sig" "$RUN/nested.sock"
cp "$RUN/build/hypr-strata.so" "$RUN/current.so"
mkdir -p "$RUN/config"
cp "$ROOT/config/defaults.json" "$RUN/config/defaults.json"
# A stack like a real one, but no profiles or theme switching: nothing nested
# may reach the session you're in.
cp "$T/strata.test.json" "$RUN/config/strata.json"
hyprctl eval 'hl.window_rule({ name = "strata-nested-test", match = { class = "^aquamarine$" }, workspace = "special:stratatest silent", float = true, size = "960 600", no_initial_focus = true })' >/dev/null
BEFORE=$(hyprctl instances | awk '/^instance/{print $2}' | tr -d ':')
cd "$T" && (env HYPRLAND_NO_SD_VARS=1 HYPRLAND_NO_SD_NOTIFY=1 STRATA_ROOT="$ROOT" STRATA_CONFIG_DIR="$RUN/config" STRATA_SO="$RUN/current.so" \
  setsid Hyprland -c ./nested.lua >"$RUN/hypr.log" 2>&1 &)
for _ in $(seq 1 40); do
  sleep 0.5
  for N in $(hyprctl instances | awk '/^instance/{print $2}' | tr -d ':'); do
    [ "$N" = "$LIVE" ] && continue
    grep -qx "$N" <<<"$BEFORE" && continue
    MON=$(hyprctl -i "$N" monitors 2>/dev/null | awk '/^Monitor/{print $2; exit}')
    [ -n "$MON" ] || continue
    case "$MON" in
      WAYLAND-*)
        echo "$N" >"$RUN/nested.sig"
        hyprctl instances | awk -v n="$N" '/^instance/{i=$2; sub(":","",i)} /wl socket:/{if (i==n) print $3}' >"$RUN/nested.sock"
        hyprctl -i "$N" output create headless STRATATEST >/dev/null
        sleep 0.3
        hyprctl -i "$N" eval "hl.monitor({ output = 'STRATATEST', mode = '1440x900@60', position = '0x0', scale = 1 }) hl.monitor({ output = '$MON', disabled = true })" >/dev/null
        sleep 0.8
        echo "$N"
        exit 0
        ;;
      *)
        echo "the nested Hyprland grabbed a real output ($MON): stopping it" >&2
        hyprctl -i "$N" dispatch exit >/dev/null 2>&1
        exit 1
        ;;
    esac
  done
done
echo "the nested Hyprland did not come up (see $RUN/hypr.log)" >&2
exit 1
