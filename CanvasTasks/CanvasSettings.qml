import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "canvasTasks"

    StyledText {
        width: parent.width
        text: "Canvas Assignments Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Configure your Canvas assignments directory and refresh interval."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "assignmentsDir"
        label: "Assignments Directory"
        description: "Full path to your Canvas assignments folder"
        placeholder: "/home/user/Documents/Canvas"
        defaultValue: ""
    }

    SliderSetting {
        settingKey: "refreshInterval"
        label: "Refresh Interval"
        description: "How often to check for new assignments"
        defaultValue: 300
        minimum: 10
        maximum: 600
        unit: "sec"
    }
}
