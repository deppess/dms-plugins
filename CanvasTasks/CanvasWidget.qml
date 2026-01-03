import QtQuick
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // Icon configuration
    readonly property string iconBar: "school"
    readonly property string iconAssignment: "assignment"
    readonly property string iconLate: "warning"
    readonly property string iconRefresh: "refresh"
    readonly property string iconFolder: "folder"
    readonly property string iconEmpty: "check_circle"
    readonly property string iconError: "error"

    // Settings from pluginData
    property string assignmentsDir: (pluginData && pluginData.assignmentsDir) ? pluginData.assignmentsDir : ""
    property int refreshInterval: (pluginData && pluginData.refreshInterval) ? pluginData.refreshInterval * 1000 : 300000

    // Display state
    property string barText: ""
    property bool isError: false
    property bool isInitialized: false
    property bool isScraperRunning: false
    property var upcomingAssignments: []
    property var dueTodayAssignments: []
    property var lateAssignments: []

    // Popout dimensions
    popoutWidth: 450
    popoutHeight: 500

    function runCanvasScraper() {
        isScraperRunning = true
        canvasScraperProcess.running = true
    }

    Component.onCompleted: {
        // Defer initial load to allow pluginData to fully initialize
        Qt.callLater(function() {
            if (assignmentsDir) {
                refreshAssignments()
            }
            if (refreshInterval > 0) {
                refreshTimer.start()
            }
        })
    }

    // React to settings changes
    onAssignmentsDirChanged: {
        if (assignmentsDir) {
            refreshAssignments()
            if (!refreshTimer.running && refreshInterval > 0) {
                refreshTimer.start()
            }
        }
    }

    onRefreshIntervalChanged: {
        if (refreshTimer.running) {
            refreshTimer.restart()
        }
    }

    Timer {
        id: refreshTimer
        interval: root.refreshInterval
        repeat: true
        running: false
        onTriggered: root.refreshAssignments()
    }

    function refreshAssignments() {
        if (!assignmentsDir) {
            isError = true
            if (isInitialized) {
                barText = "No Dir"
            }
            return
        }
        // Reset error state before fetching
        isError = false
        assignmentsProcess.running = true
    }

    Process {
        id: assignmentsProcess
        command: ["/usr/bin/env", "fish", "-c", buildScript()]
        running: false

        stdout: SplitParser {
            onRead: data => {
                try {
                    const result = JSON.parse(data.trim())
                    const isErrorResult = result.class === "error"

                    // Only set error text if initialized, but always set error state
                    if (root.isInitialized || !isErrorResult) {
                        root.barText = result.text || "Error"
                    }
                    root.isError = isErrorResult

                    const parsed = parseTooltipIntoSections(result.tooltip)
                    root.upcomingAssignments = parsed.upcoming
                    root.dueTodayAssignments = parsed.dueToday
                    root.lateAssignments = parsed.late
                    root.isInitialized = true
                } catch (e) {
                    console.error("Canvas: Failed to parse:", e)
                    if (root.isInitialized) {
                        root.barText = "Error"
                    }
                    root.isError = true
                    root.upcomingAssignments = []
                    root.dueTodayAssignments = []
                    root.lateAssignments = []
                    root.isInitialized = true
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                console.warn("Canvas: Script failed:", exitCode)
                if (root.isInitialized) {
                    root.barText = "Error"
                }
                root.isError = true
                root.upcomingAssignments = []
                root.dueTodayAssignments = []
                root.lateAssignments = []
            }
            root.isInitialized = true
        }
    }

    function buildScript() {
        return `
set ASSIGNMENTS_DIR "${root.assignmentsDir}"
set ICON_BAR "󱉟"
set ICON_ASSIGNMENT ""
set ICON_LATE "󰉀"

function extract_course_code
    set folder_name $argv[1]
    set parts (string split '-' $folder_name)
    if test (count $parts) -ge 3
        echo "$parts[2]-$parts[3]"
    else
        echo Unknown
    end
end

function parse_due_date
    set due_date $argv[1]
    set cleaned_date (string replace ' at ' ' ' "$due_date")
    set due_timestamp (date -d "$cleaned_date" +%s 2>/dev/null)
    if test -z "$due_timestamp"
        set date_only (string replace -r '\\s+\\d+:\\d+.*\$' '' "$cleaned_date")
        set due_timestamp (date -d "$date_only" +%s 2>/dev/null)
    end
    echo $due_timestamp
end

function is_due_today
    set due_timestamp $argv[1]
    set today_start (date -d "today 00:00:00" +%s)
    set today_end (date -d "today 23:59:59" +%s)
    test $due_timestamp -ge $today_start; and test $due_timestamp -le $today_end
end

function is_late
    set due_timestamp $argv[1]
    set labels $argv[2]
    set today_start (date -d "today 00:00:00" +%s)
    if test $due_timestamp -lt $today_start
        return 0
    end
    string match -q "*⚠ MISSING*" "$labels"
end

function format_date_short
    set due_date $argv[1]
    set cleaned_date (string replace ' at ' ' ' "$due_date")
    date -d "$cleaned_date" +'%b %d' 2>/dev/null
end

function truncate_name
    set name $argv[1]
    if test (string length "$name") -gt 20
        echo (string sub -l 17 "$name")"..."
    else
        echo "$name"
    end
end

if not test -d $ASSIGNMENTS_DIR
    printf '{"text":"No Data","tooltip":"Directory not found: $ASSIGNMENTS_DIR","class":"error"}\\n'
    exit 0
end

set assignment_files (find $ASSIGNMENTS_DIR -name "assignments.md" -type f 2>/dev/null | grep -v '/archive/')

if test (count $assignment_files) -eq 0
    printf '{"text":"None","tooltip":"All Caught Up","class":"custom-canvas"}\\n'
    exit 0
end

set -g regular_assignments
set -g late_assignments
set -g due_today_count 0

for file in $assignment_files
    set folder_name (basename (dirname $file))
    set course_code (extract_course_code $folder_name)
    set file_content (cat $file 2>/dev/null)

    test -z "$file_content"; and continue

    set blocks (string split -- '---' "$file_content")

    for block in $blocks
        test -z (string trim "$block"); and continue

        set name_line (echo "$block" | grep -m1 '##' | string trim)
        set assignment_name (echo "$name_line" | string replace -r '^##\\s*' '' | string replace -r '\\s*-\\s*\\*\\*.*\$' '' | string trim)

        test -z "$assignment_name"; and continue

        set due_date (echo "$block" | string match -r '\\*\\*Due:\\*\\*\\s*([^-]+)' | tail -n1 | string trim)

        if test -z "$due_date"; or string match -q "*No due date*" "$due_date"
            continue
        end

        set assignment_status (echo "$block" | string match -r '\\*\\*Status:\\*\\*\\s*([^-]+)' | tail -n1 | string trim)

        string match -q "*Not Submitted*" "$assignment_status"; or continue

        set labels (echo "$block" | string match -r '\\*\\*Labels:\\*\\*\\s*([^-]+)' | tail -n1 | string trim)
        set due_timestamp (parse_due_date "$due_date")

        test -z "$due_timestamp"; and continue

        set short_date (format_date_short "$due_date")
        set display_name (truncate_name "$assignment_name")

        if is_due_today $due_timestamp
            set due_today_count (math $due_today_count + 1)
        end

        if is_late $due_timestamp "$labels"
            set -a late_assignments "$due_timestamp|$display_name|$course_code|$short_date"
        else
            set -a regular_assignments "$due_timestamp|$display_name|$course_code|$short_date"
        end
    end
end

set in_active_semester 0
set three_days_from_now (date -d "3 days" +%s)

for assignment in $regular_assignments
    set due_timestamp (string split '|' $assignment)[1]
    if test $due_timestamp -le $three_days_from_now
        set in_active_semester 1
        break
    end
end

if test $due_today_count -gt 0
    set bar_text "$due_today_count"
else if test (count $regular_assignments) -gt 0
    set sorted (printf '%s\\n' $regular_assignments | sort -n)
    set soonest_date (string split '|' $sorted[1])[4]
    set bar_text "$soonest_date"
else if test (count $late_assignments) -gt 0
    if test $in_active_semester -eq 0
        set bar_text "None"
    else
        set bar_text "Late"
    end
else
    set bar_text "None"
end

set tooltip ""

if test (count $regular_assignments) -gt 0
    set sorted_regular (printf '%s\\n' $regular_assignments | sort -rn)

    for assignment in $sorted_regular
        set parts (string split '|' $assignment)
        test -n "$tooltip"; and set tooltip "$tooltip\\n"
        set tooltip "$tooltip$ICON_ASSIGNMENT $parts[2] - $parts[3] ($parts[4])"
    end
end

if test (count $late_assignments) -gt 0
    set sorted_late (printf '%s\\n' $late_assignments | sort -rn)

    if test -n "$tooltip"
        set tooltip "$tooltip\\n\\n--- Late ---"
    else
        set tooltip "--- Late ---"
    end

    for assignment in $sorted_late
        set parts (string split '|' $assignment)
        set tooltip "$tooltip\\n$ICON_LATE $parts[2] - $parts[3] (was $parts[4])"
    end
end

test -z "$tooltip"; and set tooltip "All Caught Up"

printf '{"text":"%s","tooltip":"%s","class":"custom-canvas"}\\n' "$bar_text" "$tooltip"
`
    }

    function parseTooltipIntoSections(tooltip) {
        const upcoming = []
        const dueToday = []
        const late = []
        const lines = tooltip.split('\n')
        let isLateSection = false

        const today = new Date()
        const todayStr = today.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim()

            if (line === "--- Late ---") {
                isLateSection = true
                continue
            }

            if (!line || line === "All Caught Up") continue

            const match = line.match(/[󱉟󰉀]\s*.\s*(.+?)\s*-\s*(.+?)\s*\((was\s+)?(.+?)\)/)

            if (match) {
                const assignment = {
                    name: match[1].trim(),
                    course: match[2].trim(),
                    date: match[4].trim(),
                    isLate: isLateSection
                }

                if (isLateSection) {
                    late.push(assignment)
                } else if (assignment.date === todayStr) {
                    dueToday.push(assignment)
                } else {
                    upcoming.push(assignment)
                }
            }
        }

        return { upcoming, dueToday, late }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                name: root.iconBar
                size: Theme.iconSize * 0.6
                color: root.isError ? Theme.error : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.barText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Normal
                color: root.isError ? Theme.error : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: root.iconBar
                size: Theme.iconSize * 0.6
                color: root.isError ? Theme.error : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.barText
                font.pixelSize: Theme.fontSizeSmall * 0.8
                font.weight: Font.Normal
                color: root.isError ? Theme.error : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "Assignments"
            detailsText: {
                const total = root.upcomingAssignments.length + root.dueTodayAssignments.length + root.lateAssignments.length
                if (total === 0) return "All caught up"
                if (root.dueTodayAssignments.length > 0) return root.dueTodayAssignments.length + " due today"
                return total + " assignment" + (total === 1 ? "" : "s")
            }
            showCloseButton: false

            Column {
                width: parent.width
                spacing: Theme.spacingS

                // Action buttons
                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingXS
                    spacing: Theme.spacingXS

                    Rectangle {
                        width: 32
                        height: 32
                        radius: 16
                        color: refreshArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                        DankIcon {
                            id: refreshIcon
                            anchors.centerIn: parent
                            name: root.iconRefresh
                            size: 20
                            color: refreshArea.containsMouse ? Theme.primary : Theme.surfaceText

                            NumberAnimation on rotation {
                                id: spinAnimation
                                from: 0
                                to: 360
                                duration: 1000
                                loops: Animation.Infinite
                                running: root.isScraperRunning
                                onStopped: refreshIcon.rotation = 0
                            }
                        }

                        MouseArea {
                            id: refreshArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: !root.isScraperRunning
                            onClicked: root.runCanvasScraper()
                        }
                    }

                    Rectangle {
                        width: 32
                        height: 32
                        radius: 16
                        color: folderArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                        DankIcon {
                            anchors.centerIn: parent
                            name: root.iconFolder
                            size: 20
                            color: folderArea.containsMouse ? Theme.primary : Theme.surfaceText
                        }

                        MouseArea {
                            id: folderArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.assignmentsDir) {
                                    yaziProcess.running = true
                                }
                            }
                        }
                    }
                }

                // Divider
                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.outlineVariant
                    opacity: 0.5
                }

                // Scrollable sections
                Flickable {
                    width: parent.width
                    height: 400
                    contentHeight: sectionsColumn.implicitHeight
                    clip: true

                    Column {
                        id: sectionsColumn
                        width: parent.width
                        spacing: Theme.spacingL

                        // Due Today Section
                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: root.dueTodayAssignments.length > 0

                            Row {
                                width: parent.width
                                spacing: Theme.spacingXS

                                Rectangle {
                                    width: 3
                                    height: 16
                                    radius: 1.5
                                    color: Theme.error
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "Due Today"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Bold
                                    color: Theme.error
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Repeater {
                                model: root.dueTodayAssignments

                                delegate: Item {
                                    width: parent.width
                                    height: 28

                                    Rectangle {
                                        anchors.fill: parent
                                        color: mouseArea.containsMouse ? Theme.surfaceContainerHigh : "transparent"
                                        radius: Theme.cornerRadiusSmall
                                    }

                                    Row {
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.rightMargin: Theme.spacingS
                                        spacing: Theme.spacingS

                                        DankIcon {
                                            name: root.iconAssignment
                                            size: root.iconSize
                                            color: Theme.error
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: modelData.name
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                            width: parent.width - 160
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: modelData.course
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.primary
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    MouseArea {
                                        id: mouseArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                    }
                                }
                            }
                        }

                        // Upcoming Section
                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: root.upcomingAssignments.length > 0

                            Row {
                                width: parent.width
                                spacing: Theme.spacingXS

                                Rectangle {
                                    width: 3
                                    height: 16
                                    radius: 1.5
                                    color: Theme.primary
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "Upcoming"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Repeater {
                                model: root.upcomingAssignments

                                delegate: Item {
                                    width: parent.width
                                    height: 28

                                    Rectangle {
                                        anchors.fill: parent
                                        color: mouseArea.containsMouse ? Theme.surfaceContainerHigh : "transparent"
                                        radius: Theme.cornerRadiusSmall
                                    }

                                    Row {
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.rightMargin: Theme.spacingS
                                        spacing: Theme.spacingS

                                        DankIcon {
                                            name: root.iconAssignment
                                            size: root.iconSize
                                            color: Theme.primary
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: modelData.name
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                            width: parent.width - 220
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: modelData.course
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.primary
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: modelData.date
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    MouseArea {
                                        id: mouseArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                    }
                                }
                            }
                        }

                        // Late Section
                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: root.lateAssignments.length > 0

                            Row {
                                width: parent.width
                                spacing: Theme.spacingXS

                                Rectangle {
                                    width: 3
                                    height: 16
                                    radius: 1.5
                                    color: Theme.error
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "Late"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Bold
                                    color: Theme.error
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Repeater {
                                model: root.lateAssignments

                                delegate: Item {
                                    width: parent.width
                                    height: 28

                                    Rectangle {
                                        anchors.fill: parent
                                        color: mouseArea.containsMouse ? Theme.surfaceContainerHigh : "transparent"
                                        radius: Theme.cornerRadiusSmall
                                    }

                                    Row {
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.rightMargin: Theme.spacingS
                                        spacing: Theme.spacingS

                                        DankIcon {
                                            name: root.iconLate
                                            size: root.iconSize
                                            color: Theme.error
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: modelData.name
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                            width: parent.width - 260
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: modelData.course
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.primary
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: "was " + modelData.date
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.error
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    MouseArea {
                                        id: mouseArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                    }
                                }
                            }
                        }

                        // Empty state
                        Item {
                            width: parent.width
                            height: 100
                            visible: root.upcomingAssignments.length === 0 &&
                                     root.dueTodayAssignments.length === 0 &&
                                     root.lateAssignments.length === 0

                            Column {
                                anchors.centerIn: parent
                                spacing: Theme.spacingS

                                DankIcon {
                                    name: root.isError ? root.iconError : root.iconEmpty
                                    size: root.iconSize * 1.5
                                    color: root.isError ? Theme.error : Theme.primary
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    opacity: 0.6
                                }

                                StyledText {
                                    text: root.isError ? "Error Loading" : "All Caught Up!"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Process {
        id: canvasScraperProcess
        command: ["canvas-scraper"]
        running: false

        onExited: (exitCode, exitStatus) => {
            root.isScraperRunning = false

            if (exitCode === 0) {
                notifySuccess.running = true
                Qt.callLater(function() {
                    root.refreshAssignments()
                })
            } else {
                notifyFail.running = true
            }
        }
    }

    Process {
        id: notifySuccess
        command: ["notify-send", "-t", "3000", "Canvas Synced", "Assignments refreshed successfully"]
        running: false
    }

    Process {
        id: notifyFail
        command: ["notify-send", "-u", "critical", "-t", "5000", "Canvas Sync Failed", "Check journal: journalctl --user -u dms -n 20"]
        running: false
    }

    Process {
        id: yaziProcess
        command: ["kitty", "--hold", "-e", "yazi", root.assignmentsDir]
        running: false
    }
}
