import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // Popout dimensions
    popoutWidth: 280
    popoutHeight: 340

    // Icons
    readonly property string iconBar: "commit"
    readonly property string iconRefresh: "refresh"
    readonly property string iconError: "error"
    readonly property string iconOpen: "open_in_browser"
    readonly property string iconSuccess: "check_circle"

    // Settings from pluginData
    property string githubUsername: (pluginData && pluginData.username) ? pluginData.username : ""
    property string githubPAT: (pluginData && pluginData.pat) ? pluginData.pat : ""
    property int refreshInterval: (pluginData && pluginData.refreshInterval) ? pluginData.refreshInterval : 300

    // State - Always 7 items for fixed width
    property var contributions: []
    property var gridData: []  // 4 weeks of data for calendar grid
    property string totalContributions: "0"
    property bool isError: false
    property bool isLoading: false
    property string errorMessage: ""
    property var lastRefreshTime: null
    property bool isManualRefresh: false

    // Initialize with 7 placeholder items
    Component.onCompleted: {
        initializePlaceholders()

        // Start timer if credentials present
        Qt.callLater(function() {
            if (githubUsername && githubPAT) {
                refreshTimer.start()
            }
        })
    }

    // Watch for credential changes
    onGithubUsernameChanged: checkAndStartTimer()
    onGithubPATChanged: checkAndStartTimer()
    onRefreshIntervalChanged: {
        if (refreshTimer.running) {
            refreshTimer.restart()
        }
    }

    function checkAndStartTimer() {
        if (githubUsername && githubPAT) {
            if (!refreshTimer.running) {
                refreshTimer.start()
            }
        } else {
            refreshTimer.stop()
            initializePlaceholders()
        }
    }

    // Initialize 7 placeholder squares
    function initializePlaceholders() {
        const placeholders = []
        const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

        for (let i = 0; i < 7; i++) {
            placeholders.push({
                weekday: days[i],
                date: "--/--",
                count: 0,
                color: Theme.surfaceContainer
            })
        }

        contributions = placeholders
        totalContributions = "0"
        isError = false

        // Initialize grid placeholders (8 weeks × 7 days)
        const gridPlaceholders = []
        for (let week = 0; week < 8; week++) {
            const weekData = []
            for (let day = 0; day < 7; day++) {
                weekData.push({
                    weekday: day,
                    weekdayName: days[day],
                    date: "--/--",
                    count: 0,
                    color: Theme.surfaceContainer
                })
            }
            gridPlaceholders.push(weekData)
        }
        gridData = gridPlaceholders
    }

    // Shell escape function for security
    function escapeShellString(str) {
        if (!str) return ""
        return str.replace(/\\/g, "\\\\")
                  .replace(/"/g, "\\\"")
                  .replace(/\$/g, "\\$")
                  .replace(/`/g, "\\`")
    }

    // Auto-refresh timer
    Timer {
        id: refreshTimer
        interval: root.refreshInterval * 1000
        repeat: true
        running: false
        triggeredOnStart: true
        onTriggered: {
            if (root.githubUsername && root.githubPAT) {
                root.isManualRefresh = false  // Automatic refresh
                root.refreshHeatmap()
            } else {
                root.isError = true
                root.errorMessage = "Configure GitHub credentials in settings"
            }
        }
    }

    // Refresh function
    function refreshHeatmap() {
        if (!githubUsername || !githubPAT) {
            isError = true
            errorMessage = "Configure GitHub credentials in settings"
            return
        }

        // Cooldown: prevent refreshes within 30 seconds of last refresh
        const now = Date.now()
        if (lastRefreshTime && (now - lastRefreshTime) < 30000) {
            console.log("GitHub: Skipping refresh (cooldown active, last refresh was", Math.floor((now - lastRefreshTime) / 1000), "seconds ago)")
            return
        }

        console.log("GitHub: Fetching contributions for", githubUsername)
        lastRefreshTime = now
        isLoading = true
        githubProcess.running = true
    }

    // Build the embedded Fish script with escaped credentials
    function buildScript() {
        const escapedUsername = escapeShellString(githubUsername)
        const escapedPAT = escapeShellString(githubPAT)

        return `
# GitHub Heatmap Fetcher
set GITHUB_USERNAME "${escapedUsername}"
set GITHUB_PAT "${escapedPAT}"

# GitHub contribution color scheme (dark theme)
set COLOR_0 "#202329"
set COLOR_1 "#0e4429"
set COLOR_2 "#006d32"
set COLOR_3 "#26a641"
set COLOR_4 "#39d353"

# Calculate date range (4 weeks, aligned to Sunday)
set today (date +%Y-%m-%d)
set today_dow (date -d "$today" +%u)  # 1=Mon, 7=Sun

# Find the Sunday of current week
if test "$today_dow" = "7"
    set current_sunday "$today"
else
    set current_sunday (date -d "$today -$today_dow days" +%Y-%m-%d)
end

# Go back 7 more weeks to get 8 weeks total (starting Sunday)
set start_date (date -d "$current_sunday -49 days" +%Y-%m-%d)
set from_date "$start_date"T00:00:00Z
set to_date "$today"T23:59:59Z

# GraphQL query
set query 'query($user: String!, $from: DateTime!, $to: DateTime!) {
  user(login: $user) {
    contributionsCollection(from: $from, to: $to) {
      contributionCalendar {
        weeks {
          contributionDays {
            date
            contributionCount
            weekday
          }
        }
      }
    }
  }
}'

# Escape query for JSON
set query_escaped (echo $query | tr -d '\\n' | sed 's/"/\\\\"/g')

# Build JSON payload
set payload '{"query":"'$query_escaped'","variables":{"user":"'$GITHUB_USERNAME'","from":"'$from_date'","to":"'$to_date'"}}'

# Make API request with retry logic
set MAX_RETRIES 5
set RETRY_DELAY 3
set attempt 1

while test $attempt -le $MAX_RETRIES
    # Execute curl
    set temp_response (mktemp)
    set http_code (curl -s -w "%{http_code}" -o "$temp_response" \\
        -H "Authorization: Bearer $GITHUB_PAT" \\
        -H "Content-Type: application/json" \\
        -H "Accept: application/vnd.github.v4.idl" \\
        -d "$payload" \\
        https://api.github.com/graphql 2>/dev/null)

    set body (cat "$temp_response")
    rm -f "$temp_response"

    # Check if successful
    if test "$http_code" = "200"
        # Check for GraphQL errors
        set has_errors (echo "$body" | jq -r '.errors // empty' 2>/dev/null)

        if test -n "$has_errors"
            # GraphQL returned errors
            set error_msg (echo "$body" | jq -r '.errors[0].message' 2>/dev/null)
            printf '{"contributions":[],"total":0,"error":true,"errorMessage":"GraphQL error: %s"}\n' "$error_msg"
            exit 1
        end

        if test -z "$has_errors"
            # Success! Process the data
            set weeks_data (echo "$body" | jq -r '.data.user.contributionsCollection.contributionCalendar.weeks')

            # Initialize arrays
            set -l grid_json "["
            set -l pill_json "["
            set -l all_days
            set total_contributions 0
            set week_count 0

            # Collect all days with their data
            for week in (echo "$weeks_data" | jq -c '.[]')
                for day in (echo "$week" | jq -c '.contributionDays[]')
                    set date (echo "$day" | jq -r '.date')
                    set count (echo "$day" | jq -r '.contributionCount')
                    set weekday (echo "$day" | jq -r '.weekday')

                    # Check if date is in our range
                    set day_timestamp (date -d "$date" +%s)
                    set start_timestamp (date -d "$start_date" +%s)
                    set today_timestamp (date -d "$today" +%s)

                    if test $day_timestamp -ge $start_timestamp; and test $day_timestamp -le $today_timestamp
                        # Determine color based on count
                        if test $count -eq 0
                            set color $COLOR_0
                        else if test $count -le 3
                            set color $COLOR_1
                        else if test $count -le 6
                            set color $COLOR_2
                        else if test $count -le 9
                            set color $COLOR_3
                        else
                            set color $COLOR_4
                        end

                        set total_contributions (math "$total_contributions + $count")

                        # Store day data
                        set formatted_date (date -d "$date" +%m/%d)
                        set weekday_names "Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"
                        set weekday_index (math "$weekday + 1")
                        set weekday_name $weekday_names[$weekday_index]

                        # Add to all_days array (will be sorted by date)
                        set -a all_days "$date|$weekday|$count|$color|$formatted_date|$weekday_name"
                    end
                end
            end

            # Sort days by date
            set sorted_days (printf '%s\n' $all_days | sort)

            # Build grid data (organized by week columns)
            # Each week is Sun(0) through Sat(6)
            set -l current_week "["
            set -l current_week_day -1
            set -l first_week 1
            set -l first_day_in_week 1

            for day_data in $sorted_days
                set parts (string split "|" $day_data)
                set date $parts[1]
                set weekday $parts[2]
                set count $parts[3]
                set color $parts[4]
                set formatted_date $parts[5]
                set weekday_name $parts[6]

                # If we hit Sunday (weekday 0) and it's not the first day, start new week
                if test "$weekday" = "0"; and test $first_day_in_week -eq 0
                    # Close previous week
                    set current_week "$current_week]"
                    if test $first_week -eq 1
                        set grid_json "$grid_json$current_week"
                        set first_week 0
                    else
                        set grid_json "$grid_json,$current_week"
                    end
                    set current_week "["
                    set first_day_in_week 1
                end

                # Add day to current week
                set day_obj "{\\\"weekday\\\":$weekday,\\\"weekdayName\\\":\\\"$weekday_name\\\",\\\"date\\\":\\\"$formatted_date\\\",\\\"count\\\":$count,\\\"color\\\":\\\"$color\\\"}"

                if test $first_day_in_week -eq 1
                    set current_week "$current_week$day_obj"
                    set first_day_in_week 0
                else
                    set current_week "$current_week,$day_obj"
                end
            end

            # Close last week
            set current_week "$current_week]"
            if test $first_week -eq 1
                set grid_json "$grid_json$current_week"
            else
                set grid_json "$grid_json,$current_week"
            end
            set grid_json "$grid_json]"

            # Build pill data (last 7 days)
            set day_count (count $sorted_days)
            set pill_start (math "max(1, $day_count - 6)")
            set pill_count 0

            for i in (seq $pill_start $day_count)
                set day_data $sorted_days[$i]
                set parts (string split "|" $day_data)
                set weekday_name $parts[6]
                set formatted_date $parts[5]
                set count $parts[3]
                set color $parts[4]

                if test $pill_count -gt 0
                    set pill_json "$pill_json,"
                end
                set pill_json "$pill_json{\\\"weekday\\\":\\\"$weekday_name\\\",\\\"date\\\":\\\"$formatted_date\\\",\\\"count\\\":$count,\\\"color\\\":\\\"$color\\\"}"
                set pill_count (math "$pill_count + 1")
            end
            set pill_json "$pill_json]"

            # Output final JSON
            printf '{"contributions":%s,"gridData":%s,"total":%d,"error":false}\n' "$pill_json" "$grid_json" $total_contributions
            exit 0
        end
    end

    # Retry logic
    if test $attempt -lt $MAX_RETRIES
        sleep $RETRY_DELAY
        set attempt (math "$attempt + 1")
    else
        # Max retries reached - provide specific error based on HTTP code
        if test "$http_code" = "401"
            printf '{"contributions":[],"total":0,"error":true,"errorMessage":"Authentication failed (HTTP 401). Check your PAT token."}\n'
        else if test "$http_code" = "403"
            printf '{"contributions":[],"total":0,"error":true,"errorMessage":"Rate limited or forbidden (HTTP 403). Try increasing refresh interval."}\n'
        else if test "$http_code" = "404"
            printf '{"contributions":[],"total":0,"error":true,"errorMessage":"User not found (HTTP 404). Check your GitHub username."}\n'
        else if test "$http_code" = "000"
            printf '{"contributions":[],"total":0,"error":true,"errorMessage":"Network error. Check internet connection."}\n'
        else
            printf '{"contributions":[],"total":0,"error":true,"errorMessage":"GitHub API error (HTTP %s) after %d attempts"}\n' "$http_code" $MAX_RETRIES
        end
        exit 1
    end
end

# Fallback error
printf '{"contributions":[],"total":0,"error":true,"errorMessage":"Unknown error occurred"}\n'
exit 1
`
    }

    // Fish process
    Process {
        id: githubProcess
        command: ["/usr/bin/env", "fish", "-c", buildScript()]
        running: false

        stdout: SplitParser {
            onRead: data => {
                try {
                    const result = JSON.parse(data.trim())

                    if (result.error) {
                        console.error("GitHub: API error -", result.errorMessage)
                        console.error("GitHub: Full response:", data)
                        root.isError = true
                        root.errorMessage = result.errorMessage || "Unknown error"
                        root.initializePlaceholders()
                        root.isLoading = false
                        if (root.isManualRefresh) {
                            notifyFail.running = true
                        }
                        return
                    }

                    console.log("GitHub: Successfully fetched", result.contributions.length, "days for pill,", result.gridData.length, "weeks for grid")

                    root.isError = false
                    root.isLoading = false

                    // Ensure we always have exactly 7 items for pill
                    let newContributions = result.contributions || []

                    // Pad with placeholders if less than 7
                    while (newContributions.length < 7) {
                        newContributions.push({
                            weekday: "---",
                            date: "--/--",
                            count: 0,
                            color: Theme.surfaceContainer
                        })
                    }

                    // Trim if more than 7
                    newContributions = newContributions.slice(0, 7)

                    root.contributions = newContributions
                    root.totalContributions = result.total.toString()

                    // Process grid data - ensure 4 weeks with 7 days each
                    const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                    let newGridData = result.gridData || []

                    // Pad to 8 weeks if needed
                    while (newGridData.length < 8) {
                        const emptyWeek = []
                        for (let d = 0; d < 7; d++) {
                            emptyWeek.push({
                                weekday: d,
                                weekdayName: days[d],
                                date: "--/--",
                                count: 0,
                                color: Theme.surfaceContainer
                            })
                        }
                        newGridData.unshift(emptyWeek)  // Add empty weeks at start (older)
                    }

                    // Ensure each week has 7 days
                    for (let w = 0; w < newGridData.length; w++) {
                        while (newGridData[w].length < 7) {
                            const missingDay = newGridData[w].length
                            newGridData[w].push({
                                weekday: missingDay,
                                weekdayName: days[missingDay],
                                date: "--/--",
                                count: 0,
                                color: Theme.surfaceContainer
                            })
                        }
                    }

                    // Take only last 8 weeks
                    newGridData = newGridData.slice(-8)

                    root.gridData = newGridData

                    if (root.isManualRefresh) {
                        notifySuccess.running = true
                    }

                } catch (e) {
                    console.error("GitHub: Failed to parse response -", e, "Data:", data)
                    root.isError = true
                    root.errorMessage = "Failed to parse GitHub response"
                    root.initializePlaceholders()
                    root.isLoading = false
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            root.isLoading = false
            if (exitCode !== 0 && !root.isError) {
                console.error("GitHub: Script failed with exit code", exitCode)
                root.isError = true
                root.errorMessage = "Script failed with exit code: " + exitCode
                if (root.isManualRefresh) {
                    notifyFail.running = true
                }
            }
        }
    }

    // Notification processes
    Process {
        id: notifySuccess
        command: ["notify-send", "-t", "3000", "GitHub Synced", "Contributions refreshed successfully"]
        running: false
    }

    Process {
        id: notifyFail
        command: ["notify-send", "-u", "critical", "-t", "5000", "GitHub Sync Failed", root.errorMessage]
        running: false
    }

    Process {
        id: openProfileProcess
        command: ["xdg-open", "https://github.com/" + root.githubUsername]
        running: false
    }

    // Horizontal bar pill - ALWAYS 7 squares
    horizontalBarPill: Component {
        Row {
            spacing: 2

            Repeater {
                model: 7  // ALWAYS 7 - prevents width changes

                Rectangle {
                    width: 8
                    height: 16
                    radius: 2
                    color: index < root.contributions.length
                           ? root.contributions[index].color
                           : Theme.surfaceContainer
                    border.color: Qt.darker(color, 1.2)
                    border.width: 1

                    // Subtle loading animation
                    opacity: root.isLoading ? 0.6 : 1.0

                    Behavior on opacity {
                        NumberAnimation { duration: 200 }
                    }

                    Behavior on color {
                        ColorAnimation { duration: 300 }
                    }
                }
            }
        }
    }

    // Vertical bar pill - ALWAYS 7 squares
    verticalBarPill: Component {
        Column {
            spacing: 2

            Repeater {
                model: 7  // ALWAYS 7 - prevents height changes

                Rectangle {
                    width: 16
                    height: 8
                    radius: 2
                    color: index < root.contributions.length
                           ? root.contributions[index].color
                           : Theme.surfaceContainer
                    border.color: Qt.darker(color, 1.2)
                    border.width: 1

                    // Subtle loading animation
                    opacity: root.isLoading ? 0.6 : 1.0

                    Behavior on opacity {
                        NumberAnimation { duration: 200 }
                    }

                    Behavior on color {
                        ColorAnimation { duration: 300 }
                    }
                }
            }
        }
    }

    // Popout position persistence
    property int popoutX: (pluginData && pluginData.popoutX) ? pluginData.popoutX : -1
    property int popoutY: (pluginData && pluginData.popoutY) ? pluginData.popoutY : -1

    function savePopoutPosition(x, y) {
        PluginService.savePluginData("githubHeatmap", "popoutX", x)
        PluginService.savePluginData("githubHeatmap", "popoutY", y)
        PluginService.setGlobalVar("githubHeatmap", "popoutX", x)
        PluginService.setGlobalVar("githubHeatmap", "popoutY", y)
    }

    // Popout content
    popoutContent: Component {
        PopoutComponent {
            id: popout

            // Restore saved position
            x: root.popoutX >= 0 ? root.popoutX : x
            y: root.popoutY >= 0 ? root.popoutY : y

            // Save position when moved
            onXChanged: if (visible) Qt.callLater(() => root.savePopoutPosition(x, y))
            onYChanged: if (visible) Qt.callLater(() => root.savePopoutPosition(x, y))

            headerText: "GitHub Contributions"
            detailsText: {
                if (root.isError) return root.errorMessage
                if (root.isLoading) return "Loading..."
                return root.totalContributions + " contributions (8 weeks)"
            }
            showCloseButton: false

            Column {
                width: parent.width
                spacing: Theme.spacingM

                // Action buttons row
                Row {
                    anchors.right: parent.right
                    spacing: Theme.spacingS

                    // Refresh button
                    Rectangle {
                        width: Theme.iconSize * 1.5
                        height: Theme.iconSize * 1.5
                        radius: Theme.iconSize * 0.75
                        color: refreshArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                        DankIcon {
                            anchors.centerIn: parent
                            name: root.iconRefresh
                            size: Theme.iconSize * 0.8
                            color: refreshArea.containsMouse ? Theme.primary : Theme.surfaceText

                            NumberAnimation on rotation {
                                from: 0
                                to: 360
                                duration: 1000
                                loops: Animation.Infinite
                                running: root.isLoading
                            }
                        }

                        MouseArea {
                            id: refreshArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.isManualRefresh = true
                                root.refreshHeatmap()
                            }
                        }
                    }

                    // Open profile button
                    Rectangle {
                        width: Theme.iconSize * 1.5
                        height: Theme.iconSize * 1.5
                        radius: Theme.iconSize * 0.75
                        color: openArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                        DankIcon {
                            anchors.centerIn: parent
                            name: root.iconOpen
                            size: Theme.iconSize * 0.8
                            color: openArea.containsMouse ? Theme.primary : Theme.surfaceText
                        }

                        MouseArea {
                            id: openArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.githubUsername) {
                                    openProfileProcess.running = true
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
                }

                // Error state
                StyledRect {
                    visible: root.isError
                    width: parent.width
                    height: 100
                    color: Theme.surfaceContainerHigh
                    radius: Theme.cornerRadius

                    Column {
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        DankIcon {
                            name: root.iconError
                            color: Theme.error
                            size: Theme.iconSize * 1.5
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        StyledText {
                            text: "Failed to load contributions"
                            color: Theme.error
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }

                // Calendar grid view
                Row {
                    visible: !root.isError
                    spacing: 6
                    anchors.horizontalCenter: parent.horizontalCenter

                    // Day labels column
                    Column {
                        spacing: 3
                        topPadding: 2

                        Repeater {
                            model: ["S", "M", "T", "W", "T", "F", "S"]

                            StyledText {
                                text: modelData
                                font.pixelSize: 10
                                color: Theme.surfaceVariantText
                                width: 14
                                height: 26
                                horizontalAlignment: Text.AlignRight
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }

                    // Grid of contribution squares (8 weeks × 7 days)
                    Row {
                        spacing: 3

                        Repeater {
                            model: root.gridData  // 8 weeks

                            Column {
                                spacing: 3
                                required property var modelData
                                required property int index

                                Repeater {
                                    model: modelData  // 7 days per week

                                    Rectangle {
                                        width: 26
                                        height: 26
                                        radius: 4
                                        color: modelData.color || Theme.surfaceContainer
                                        border.color: Qt.darker(color, 1.15)
                                        border.width: 1

                                        required property var modelData

                                        opacity: root.isLoading ? 0.6 : 1.0

                                        Behavior on opacity {
                                            NumberAnimation { duration: 200 }
                                        }

                                        Behavior on color {
                                            ColorAnimation { duration: 300 }
                                        }

                                        // Tooltip on hover
                                        MouseArea {
                                            id: cellMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                        }

                                        // Tooltip popup
                                        Rectangle {
                                            visible: cellMouse.containsMouse && modelData.date !== "--/--"
                                            x: -25
                                            y: -30
                                            width: tooltipText.implicitWidth + 12
                                            height: tooltipText.implicitHeight + 8
                                            color: Theme.surfaceContainerHighest
                                            radius: 4
                                            z: 100

                                            StyledText {
                                                id: tooltipText
                                                anchors.centerIn: parent
                                                text: modelData.date + ": " + modelData.count
                                                font.pixelSize: 11
                                                color: Theme.surfaceText
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Empty state
                StyledRect {
                    visible: !root.isError && root.totalContributions === "0"
                    width: parent.width
                    height: 50
                    color: Theme.surfaceContainerHigh
                    radius: Theme.cornerRadius

                    StyledText {
                        anchors.centerIn: parent
                        text: "No contributions yet"
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }
                }
            }
        }
    }
}
