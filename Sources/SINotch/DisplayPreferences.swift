import Foundation

enum DisplayPreferences {
    static let defaults: [String: Any] = [
        "displayMode": "notch",
        "screenID": "auto",
        "followFocus": false,
        "showOnlyWithSessions": false,
        "hideInFullScreen": true,
        "panelWidth": 680.0,
        "panelHeight": 560.0,
        "fontSize": 11.0,
        "showModel": true,
        "showReasoning": true,
        "showProject": true,
        "showTasks": true,
        "showSubagents": true,
        "showActivity": true
    ]

    static func reset(in preferences: UserDefaults) {
        for (key, value) in defaults { preferences.set(value, forKey: key) }
        preferences.removeObject(forKey: "compactDetail")
    }
}
