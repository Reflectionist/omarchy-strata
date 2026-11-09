# Sourced by the test scripts: where things are.
#   T     this folder        ROOT  the plugin (repo) root
#   RUN   runtime files: the nested instance's signature, its plugin build,
#         config, logs and screenshots. Never inside the plugin folder: a
#         write there makes the Omarchy shell reload its plugins.
T=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$T")
RUN="${XDG_RUNTIME_DIR:-/tmp}/strata-test"
mkdir -p "$RUN/shots"
