#!/bin/bash
# Print Strata's view state and the columns of a workspace (default: active): st.sh [ws]
. "$(dirname "$(readlink -f "$0")")/env.sh"
H=$T/h.sh
WS=${1:-$($H activeworkspace -j | jq -r .id)}
$H repl "local s=hl.plugin.strata.state() if not s then return 'no strata' end return string.format('ws %d cam %.3f cursor %.3f+%.3f %s  bounds %.2f..%.2f', s.workspace, s.camera, s.x, s.w, s.blank and 'BLANK' or 'window', s.lo, s.hi)"
$H repl "local t={} for _,c in ipairs(hl.plugin.strata.columns($WS)) do local n={} for _,a in ipairs(c.windows) do local w=hl.get_window('address:'..a) n[#n+1]=w and w.title or a end t[#t+1]=string.format('[%.3f+%.3f %s]',c.x,c.w,table.concat(n,'/')) end return 'ws $WS: '..table.concat(t,' ')"
$H activewindow -j | jq -r '"focus: \(.title // "(none)") \(.at // "") \(.size // "")"'
