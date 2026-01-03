import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "ssh-monitor"

    // State - array of connection strings
    property var connections: []
    property bool hasConnections: connections.length > 0

    // Settings from pluginData (convert seconds to milliseconds)
    property int refreshInterval: (pluginData.refreshInterval || 5) * 1000

    // Icons
    readonly property string iconDisconnected: "cloud_off"
    readonly property string iconConnected: "cloud_done"

    // Popout dimensions
    popoutWidth: 400
    popoutHeight: 300

    // Accumulator for process output
    property string processOutput: ""

    // Fish script process - uses your EXACT script
    Process {
        id: connectionChecker
        command: ["/usr/bin/env", "fish", "-c", fishScript]
        running: false

        property string fishScript: `
#!/usr/bin/env fish
# Get all connection processes
set ssh_procs (pgrep -af '^ssh ' 2>/dev/null)
set sftp_procs (pgrep -af '^sftp ' 2>/dev/null)
set ftp_procs (pgrep -af '^ftp ' 2>/dev/null)
set gvfs_procs (pgrep -af '/usr/lib/gvfsd-sftp' 2>/dev/null)
set gvfs_ssh_procs (pgrep -af 'ssh.*gvfsd-sftp' 2>/dev/null)

# Combine all processes
set all_procs $ssh_procs $sftp_procs $ftp_procs $gvfs_procs $gvfs_ssh_procs

# No connections
if test (count $all_procs) -eq 0
    echo "DISCONNECTED"
    exit 0
end

# Parse SSH config
set -l config_map
if test -f ~/.ssh/config
    set current_host ""
    for line in (cat ~/.ssh/config)
        if string match -qr '^Host\\s+(\\S+)' $line
            set host (string match -r '^Host\\s+(\\S+)' $line)[2]
            if test "$host" != "*"
                set current_host $host
            end
        else if string match -qr '^\\s*HostName\\s+(\\S+)' $line
            if test -n "$current_host"
                set host_addr (string match -r '^\\s*HostName\\s+(\\S+)' $line)[2]
                set -a config_map "$host_addr:$current_host"
                set -a config_map "$current_host:$current_host"
            end
        end
    end
end

# Resolve target
function resolve_target
    set target $argv[1]
    set config_map $argv[2..]
    for mapping in $config_map
        set parts (string split ':' $mapping)
        if test "$parts[1]" = "$target"
            echo $parts[2]
            return
        end
    end
    echo $target
end

# Build connection list
set connections
for proc in $all_procs
    set fields (string split -n ' ' $proc)
    if test (count $fields) -lt 2
        continue
    end
    
    set cmd_and_args $fields[2..]
    set cmd $fields[2]
    
    set conn_type SSH
    set target ""
    
    # Skip GVFS daemon
    if string match -q '*/usr/lib/gvfsd-sftp*' $cmd
        continue
    end
    
    # SSH process
    if string match -q ssh $cmd
        if string match -q '*-s*sftp' $proc
            set conn_type SFTP
            for i in (seq (count $cmd_and_args))
                if test "$cmd_and_args[$i]" = sftp
                    if test $i -gt 1
                        set potential_target $cmd_and_args[(math $i - 1)]
                        if not string match -q -- '-*' $potential_target
                            set target $potential_target
                            if string match -q '*@*' $target
                                set target (string split '@' $target)[2]
                            end
                            break
                        end
                    end
                end
            end
        else
            set conn_type SSH
            for arg in $cmd_and_args
                if not string match -q -- '-*' $arg
                    and test "$arg" != ssh
                    and test "$arg" != "ssh:"
                    if string match -q '*@*' $arg
                        set target (string split '@' $arg)[2]
                    else
                        set target $arg
                    end
                    break
                end
            end
        end
    # SFTP command
    else if string match -q sftp $cmd
        set conn_type SFTP
        for arg in $cmd_and_args
            if not string match -q -- '-*' $arg
                and test "$arg" != sftp
                if string match -q '*@*' $arg
                    set target (string split '@' $arg)[2]
                else
                    set target $arg
                end
                break
            end
        end
    # FTP command
    else if string match -q ftp $cmd
        set conn_type FTP
        for arg in $cmd_and_args
            if not string match -q -- '-*' $arg
                and test "$arg" != ftp
                if string match -q '*@*' $arg
                    set target (string split '@' $arg)[2]
                else
                    set target $arg
                end
                break
            end
        end
    end
    
    # Skip if no valid target
    if test -z "$target"
        continue
    end
    
    # Resolve target
    set resolved (resolve_target $target $config_map)
    
    # Add to connections (avoid duplicates)
    set conn_string "$conn_type → $resolved"
    if not contains $conn_string $connections
        set -a connections $conn_string
    end
end

# Check for running sftp-sync processes
set sftp_sync_procs (pgrep -af 'sftp-sync' 2>/dev/null)
for proc in $sftp_sync_procs
    set fields (string split -n ' ' $proc)
    if test (count $fields) -ge 4
        set cmd_path $fields[2]
        # Check if it's the sftp-sync binary
        if string match -q '*sftp-sync' $cmd_path
            # Get action (up/down) and profile name
            if test (count $fields) -ge 4
                set action $fields[3]
                set profile $fields[4]
                # Only show if we have a valid profile
                if test -n "$profile"
                    set conn_string "REMOTE → $profile"
                    if not contains $conn_string $connections
                        set -a connections $conn_string
                    end
                end
            end
        end
    end
end

# Check for Yazi VFS SFTP connections
set yazi_pids (pgrep yazi 2>/dev/null)
for pid in $yazi_pids
    # Get remote IPs from ESTABLISHED connections to port 22
    for remote_ip in (netstat -anp 2>/dev/null | awk -v pid="$pid/yazi" '$6=="ESTABLISHED" && $7==pid && $5~/:22$/ {split($5,a,":"); print a[1]}')
        if test -n "$remote_ip"
            # Resolve IP using SSH config mapping
            set resolved (resolve_target $remote_ip $config_map)
            set conn_string "YAZI → $resolved"
            if not contains $conn_string $connections
                set -a connections $conn_string
            end
        end
    end
end

# Output
if test (count $connections) -eq 0
    echo "DISCONNECTED"
else
    for conn in $connections
        echo $conn
    end
end
`
        
        stdout: SplitParser {
            onRead: data => {
                // Accumulate output - don't update connections yet
                root.processOutput += data + '\n';
            }
        }

        onExited: (exitCode, exitStatus) => {
            // Now process all accumulated output
            var lines = root.processOutput.trim().split('\n');
            var newConnections = [];

            for (var i = 0; i < lines.length; i++) {
                var line = lines[i].trim();
                if (line === "" || line === "DISCONNECTED") {
                    continue;
                }
                newConnections.push(line);
            }

            root.connections = newConnections;
            root.processOutput = ""; // Reset for next run
        }
    }

    // Timer to trigger checks
    Timer {
        interval: root.refreshInterval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            connectionChecker.running = true
        }
    }

    // Horizontal bar - ICON ONLY
    horizontalBarPill: Component {
        DankIcon {
            name: root.hasConnections ? root.iconConnected : root.iconDisconnected
            size: Theme.iconSize * 0.6
            color: root.hasConnections ? Theme.primary : Theme.surfaceVariantText
        }
    }

    // Vertical bar - ICON ONLY
    verticalBarPill: Component {
        DankIcon {
            name: root.hasConnections ? root.iconConnected : root.iconDisconnected
            size: Theme.iconSize * 0.6
            color: root.hasConnections ? Theme.primary : Theme.surfaceVariantText
        }
    }

    // Popout with connection list
    popoutContent: Component {
        StyledRect {
            implicitWidth: 400
            implicitHeight: contentColumn.implicitHeight + Theme.spacingL * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainer

            Column {
                id: contentColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                // Header
                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    DankIcon {
                        name: root.hasConnections ? root.iconConnected : root.iconDisconnected
                        size: root.iconSize
                        color: root.hasConnections ? Theme.primary : Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: "SSH Monitor"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                StyledRect {
                    width: parent.width
                    height: 1
                    color: Theme.surfaceVariant
                }

                // Status
                StyledText {
                    width: parent.width
                    text: root.hasConnections
                        ? root.connections.length + " active connection" + (root.connections.length !== 1 ? "s" : "")
                        : "No active connections"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Normal
                    color: root.hasConnections ? Theme.primary : Theme.surfaceVariantText
                }

                // Connection list - VERTICAL STACK
                ListView {
                    width: parent.width
                    height: Math.min(contentHeight, 300)
                    spacing: Theme.spacingS
                    model: root.connections
                    clip: true

                    delegate: StyledRect {
                        required property string modelData
                        required property int index

                        width: ListView.view.width
                        height: 40
                        radius: Theme.cornerRadiusSmall
                        color: Theme.surfaceContainerHigh

                        property string connectionText: modelData

                        Row {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingM

                            DankIcon {
                                name: {
                                    var text = parent.parent.connectionText;
                                    if (text.indexOf("SSH") === 0) return "terminal";
                                    if (text.indexOf("SFTP") === 0) return "folder";
                                    if (text.indexOf("FTP") === 0) return "storage";
                                    if (text.indexOf("YAZI") === 0) return "sync";
                                    if (text.indexOf("REMOTE") === 0) return "sync";
                                    return "cloud_sync";
                                }
                                size: root.iconSize
                                color: Theme.primary
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: parent.parent.connectionText
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }

                // Empty state
                StyledText {
                    visible: !root.hasConnections
                    width: parent.width
                    text: "No SSH, SFTP, or FTP connections detected"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
    }
}
