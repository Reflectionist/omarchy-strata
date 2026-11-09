// Strata's shell side against the nested Hyprland: tests/qs.sh copies this
// into its runtime config folder, next to a "strata" link to the plugin.
import QtQuick
import Quickshell
import "strata/shell" as Strata

ShellRoot {
  Strata.Service { id: svc }
}
