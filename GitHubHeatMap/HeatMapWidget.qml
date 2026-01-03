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
    popoutWidth: 450
    popoutHeight: 650

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

# Calculate date range (last 7 days including today)
set today (date +%Y-%m-%d)
set start_date (date -d "$today -6 days" +%Y-%m-%d)
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

            # Initialize contribution array
            set -l contributions_json "["
            set day_count 0
            set total_contributions 0

            # Parse each day's data
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

                        # Convert weekday number to name
                        set weekday_names "Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"
                        set weekday_index (math "$weekday + 1")
                        set weekday_name $weekday_names[$weekday_index]

                        # Format date as "MM/DD"
                        set formatted_date (date -d "$date" +%m/%d)

                        # Add to JSON array
                        if test $day_count -gt 0
                            set contributions_json "$contributions_json,"
                        end

                        set contributions_json "$contributions_json{\\\"weekday\\\":\\\"$weekday_name\\\",\\\"date\\\":\\\"$formatted_date\\\",\\\"count\\\":$count,\\\"color\\\":\\\"$color\\\"}"

                        set total_contributions (math "$total_contributions + $count")
                        set day_count (math "$day_count + 1")
                    end
                end
            end

            set contributions_json "$contributions_json]"

            # Output final JSON
            printf '{"contributions":%s,"total":%d,"error":false}\n' "$contributions_json" $total_contributions
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

                    console.log("GitHub: Successfully fetched", result.contributions.length, "days")

                    root.isError = false
                    root.isLoading = false

                    // Ensure we always have exactly 7 items
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
                if (root.isLoading) return "Loading contributions..."
                const total = root.totalContributions
                return "Total: " + total + " contribution" + (total === "1" ? "" : "s") + " this week"
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
                                root.isManualRefresh = true  // Manual refresh via button
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

                // Compact rows contribution view
                Column {
                    visible: !root.isError
                    width: parent.width
                    spacing: Theme.spacingXS

                    Repeater {
                        model: root.contributions

                        Row {
                            width: parent.width
                            height: 36
                            spacing: Theme.spacingM

                            // Left padding
                            Item { width: Theme.spacingM; height: 1 }

                            // Colored square
                            Rectangle {
                                width: 16
                                height: 16
                                radius: 3
                                color: modelData.color
                                border.color: Qt.darker(modelData.color, 1.2)
                                border.width: 1
                                anchors.verticalCenter: parent.verticalCenter

                                Behavior on color {
                                    ColorAnimation { duration: 300 }
                                }
                            }

                            // Day name and date
                            Row {
                                spacing: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter

                                StyledText {
                                    text: modelData.weekday
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    width: 50
                                }

                                StyledText {
                                    text: modelData.date
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }

                            // Spacer
                            Item {
                                width: parent.width - 200
                                height: 1
                            }

                            // Count
                            StyledText {
                                text: modelData.count.toString()
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: modelData.count > 0 ? Theme.primary : Theme.surfaceVariantText
                                horizontalAlignment: Text.AlignRight
                                width: 30
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            // Right padding
                            Item { width: Theme.spacingM; height: 1 }
                        }
                    }
                }

                // Total summary
                StyledRect {
                    visible: !root.isError
                    width: parent.width
                    height: 40
                    color: Theme.surfaceContainerHigh
                    radius: Theme.cornerRadius

                    Row {
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        StyledText {
                            text: "Total:"
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: root.totalContributions
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: root.totalContributions === "1" ? "contribution" : "contributions"
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                // Empty state
                StyledRect {
                    visible: !root.isError && root.totalContributions === "0"
                    width: parent.width
                    height: 80
                    color: Theme.surfaceContainerHigh
                    radius: Theme.cornerRadius

                    Column {
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        DankIcon {
                            name: root.iconSuccess
                            color: Theme.primary
                            size: Theme.iconSize * 1.5
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        StyledText {
                            text: "No contributions this week"
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }
            }
        }
    }
}
