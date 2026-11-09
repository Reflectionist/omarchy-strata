import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Setup: whether the Hyprland plugin is built, loaded and connected (from
// bin/strata-setup --status), buttons that run that script in a terminal, and
// sorting the windows already open into their strata.
Item {
  id: page
  property var win: null
  readonly property var theme: Commons.ShellColor || Commons.Color
  readonly property string root: win && win.state ? win.state.pluginDir : ""
  readonly property string setup: root + "/bin/strata-setup"
  property var status: ({})

  function lua(code) { Quickshell.execDetached(["hyprctl", "eval", code]) }
  // In a terminal: the script asks before each change to your config.
  function runSetup(args) {
    var cmd = "'" + setup + "'" + (args ? " " + args : "")
    Quickshell.execDetached(["bash", "-c",
      "if command -v omarchy-launch-floating-terminal-with-presentation >/dev/null; then exec omarchy-launch-floating-terminal-with-presentation \"$1\"; "
      + "else exec xdg-terminal-exec -e bash -c \"$1; read -rp 'Press Enter to close'\"; fi", "_", cmd])
  }

  Process {
    id: probe
    command: [page.setup, "--status"]
    stdout: StdioCollector {
      onStreamFinished: { try { page.status = JSON.parse(text) } catch (e) { page.status = {} } }
    }
  }
  // Fresh while the page is open (the script runs in a terminal meanwhile).
  Timer {
    interval: 2000
    running: page.visible && page.root !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!probe.running) probe.running = true
  }

  readonly property bool built: status.built === true
  readonly property bool current: built && status.stale !== true
  readonly property bool connected: status.connected === true
  readonly property bool running: status.loaded === true

  Flickable {
    anchors.fill: parent
    contentHeight: col.implicitHeight
    clip: true

    ColumnLayout {
      id: col
      width: parent.width
      spacing: 8

      Text { text: "Setup"; color: page.theme.popups.text; font.family: Style.font.family; font.pixelSize: 20; font.bold: true }

      PanelSectionHeader { text: "Hyprland plugin"; Layout.topMargin: 12 }
      Repeater {
        model: [
          { k: "Build", v: !page.built ? "Not built" : !page.current ? "Out of date (Hyprland or Strata changed): rebuild" : "Built for Hyprland " + (page.status.hyprland || "") },
          { k: "Hyprland config", v: page.connected ? "Connected (hyprland.lua loads Strata)" : "Not connected" },
          { k: "Status", v: page.running ? "Running" : "Not running" },
          { k: "Rebuild after updates", v: page.status.updateHook === true ? "On (Omarchy post-update hook)" : "Off" },
          { k: "Theme picker", v: page.status.themeHook === true ? "Picks apply to the current stratum" : "Picks apply globally" }
        ]
        delegate: RowLayout {
          required property var modelData
          Layout.fillWidth: true
          Text { text: modelData.k; color: page.theme.popups.text; font.family: Style.font.family; font.pixelSize: 12; Layout.preferredWidth: 180 }
          Text { text: modelData.v; color: page.theme.muted; font.family: Style.font.family; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        }
      }
      Text {
        Layout.fillWidth: true
        text: "Connect builds the plugin (gcc, about a minute) and asks before each change to your configuration: one line at the end of ~/.config/hypr/hyprland.lua (backed up first) and two optional Omarchy hooks. Disconnect removes all of it; your Strata settings stay."
        color: page.theme.muted; font.family: Style.font.family; font.pixelSize: 12; wrapMode: Text.WordWrap
      }
      RowLayout {
        spacing: 8
        Button { visible: !page.connected || !page.built; text: "Connect"; iconText: "󰌹"; bordered: true; onClicked: page.runSetup("") }
        Button { visible: page.connected && page.built; text: "Rebuild"; iconText: "󰑓"; bordered: true; onClicked: page.runSetup("--rebuild") }
        Button { visible: page.connected || page.built; text: "Disconnect"; iconText: "󰌺"; bordered: true; onClicked: page.runSetup("--remove") }
      }

      PanelSectionHeader { text: "Open windows"; Layout.topMargin: 16 }
      Text {
        Layout.fillWidth: true
        text: "New windows are routed to their strata as they open. This routes windows that are already open; windows no stratum matches stay where they are. Undo puts them back."
        color: page.theme.muted; font.family: Style.font.family; font.pixelSize: 12; wrapMode: Text.WordWrap
      }
      RowLayout {
        spacing: 8
        Button { text: "Route open windows"; iconText: "󰁔"; bordered: true; enabled: page.running; onClicked: page.lua('require("hypr.strata").migrate()') }
        Button { text: "Undo"; iconText: "󰕍"; bordered: true; enabled: page.running; onClicked: page.lua('require("hypr.strata").unmigrate()') }
      }

      PanelSectionHeader { text: "Files"; Layout.topMargin: 16 }
      Repeater {
        model: [
          { k: "Your settings", v: "~/.config/strata/strata.json" },
          { k: "Defaults", v: page.root + "/config/defaults.json" },
          { k: "Built plugin", v: "~/.local/share/strata/hypr-strata.so" },
          { k: "Documentation", v: "https://reflectionist.github.io/omarchy-strata/" }
        ]
        delegate: RowLayout {
          required property var modelData
          Layout.fillWidth: true
          Text { text: modelData.k; color: page.theme.popups.text; font.family: Style.font.family; font.pixelSize: 12; Layout.preferredWidth: 180 }
          Text { text: modelData.v; color: page.theme.muted; font.family: Style.font.family; font.pixelSize: 12; Layout.fillWidth: true; elide: Text.ElideMiddle }
        }
      }
      Item { Layout.preferredHeight: 12 }
    }
  }
}
