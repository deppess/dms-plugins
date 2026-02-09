import QtQuick
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property bool isDiskMode: false
    property bool isLoading: true

    ccWidgetIcon: "screenshot_monitor"
    ccWidgetPrimaryText: "Screenshot Mode"
    ccWidgetSecondaryText: isLoading ? "Checking..." : (isDiskMode ? "Save to Disk" : "Clipboard Only")
    ccWidgetIsActive: isDiskMode

    onCcWidgetToggled: {
        if (!isLoading) {
            root.isLoading = true
            toggleProcess.running = true
        }
    }

    Process {
        id: checkProcess
        command: ["/usr/bin/env", "fish", "-c", "grep -q '^screenshot-path' ~/.config/niri/screenshot.kdl"]
        running: false
        onExited: (exitCode, exitStatus) => {
            root.isDiskMode = (exitCode === 0)
            root.isLoading = false
        }
    }

    Process {
        id: toggleProcess
        command: ["/usr/bin/env", "fish", "-c", root.isDiskMode
            ? "sed -i 's/^screenshot-path/\\/\\/screenshot-path/' ~/.config/niri/screenshot.kdl; and niri msg action reload-config"
            : "sed -i 's/^\\/\\/screenshot-path/screenshot-path/' ~/.config/niri/screenshot.kdl; and niri msg action reload-config"]
        running: false
        onExited: (exitCode, exitStatus) => {
            checkProcess.running = true
        }
    }

    Component.onCompleted: {
        checkProcess.running = true
    }
}
