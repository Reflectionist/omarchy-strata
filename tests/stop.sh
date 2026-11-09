#!/bin/bash
# Stop the nested instance (never the main session), report a crash if it left
# one, and check the user session's environment wasn't touched.
. "$(dirname "$(readlink -f "$0")")/env.sh"
pkill -f "quickshell -p $RUN/[q]s" 2>/dev/null
N=$("$T/nested-id.sh" 2>/dev/null) || { rm -f "$RUN/nested.sig"; exit 0; }
hyprctl -i "$N" dispatch exit >/dev/null 2>&1 || hyprctl -i "$N" eval 'hl.dispatch(hl.dsp.exit())' >/dev/null 2>&1
sleep 1
rm -f "$RUN/nested.sig"
ls -t ~/.cache/hyprland/hyprlandCrashReport*.txt 2>/dev/null | head -1 | xargs -r -I{} find {} -newer "$RUN/current.so" -print
# A test compositor that reached the user manager's environment breaks apps
# started later in the real session (they'd connect to the test display).
busctl --user get-property org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager Environment 2>/dev/null |
  grep -q "WAYLAND_DISPLAY=$(cat "$RUN/nested.sock" 2>/dev/null || echo none)\"" &&
  echo "WARNING: the user session's environment has the test WAYLAND_DISPLAY" >&2
exit 0
