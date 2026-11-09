#!/bin/bash
# Drive the nested overview over IPC: ov.sh state | windows | move <dir> | enter
. "$(dirname "$(readlink -f "$0")")/env.sh"
PID=$(pgrep -f "quickshell -p $RUN/[q]s" | head -1)
[ -n "$PID" ] || { echo "nested shell not running (tests/qs.sh)" >&2; exit 1; }
quickshell ipc --pid "$PID" call strataOverview "$@"
