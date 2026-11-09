#!/bin/bash
# The standard test grid in the nested instance (closes earlier test windows):
#   Terminal  T1 at 0, T2 over T3 stacked at 1.0
#   Agents    A1 at 0.2 (off the step grid), A2 at 1.0   (250 px left gap, like a sidebar)
#   Browser   B1 at -0.5 (full width)      Chat C1 at 0.5      Games G1 at 0
. "$(dirname "$(readlink -f "$0")")/env.sh"
H=$T/h.sh
SOCK=$("$T/nested-sock.sh") || exit 1
for p in $(pgrep -x foot); do tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -qx "WAYLAND_DISPLAY=$SOCK" && kill $p; done
sleep 0.5
"$T/term.sh" T1 stratatest ffb3ba; "$T/term.sh" T2 stratatest ffdfba; "$T/term.sh" T3 stratatest ffffba
"$T/term.sh" A1 agentstest baffc9; "$T/term.sh" A2 agentstest bae1ff
"$T/term.sh" B1 other-B1 e0baff; "$T/term.sh" C1 other-C1 c9c9c9; "$T/term.sh" G1 other-G1 ffd1dc
sleep 1
$H eval 'hl.dispatch(hl.dsp.window.move({ window = "title:^B1$", workspace = "name:browser", follow = false })) hl.dispatch(hl.dsp.window.move({ window = "title:^C1$", workspace = "name:chat", follow = false })) hl.dispatch(hl.dsp.window.move({ window = "title:^G1$", workspace = "name:games", follow = false }))' >/dev/null
sleep 0.5
addr() { $H clients -j | jq -r ".[] | select(.title==\"$1\") | .address"; }
$H eval "local s=hl.plugin.strata s.place('$(addr T1)',0) s.place('$(addr T2)',1.0) s.join('$(addr T3)','$(addr T2)') s.place('$(addr A1)',0.2) s.place('$(addr A2)',1.0) s.place('$(addr B1)',-0.5) s.place('$(addr C1)',0.5) s.place('$(addr G1)',0)" >/dev/null
$H eval 'hl.dispatch(hl.dsp.focus({ workspace = "name:terminal" }))' >/dev/null
sleep 0.4
$H eval "hl.plugin.strata.reveal('$(addr T1)')" >/dev/null
echo "grid ready"
