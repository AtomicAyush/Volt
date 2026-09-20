import SwiftUI
import AppKit

/// The single source of truth for what colour the battery is showing right now.
///
/// The menu bar icon and the panel's readout used to decide this independently, which
/// is how a 25% charge could be amber in one place and green in the other. Both go
/// through here, as do the alerts themselves.
enum BatteryTint {
    /// Once the charge has fallen to a level the user set an alert for, that alert's
    /// colour takes over. Above every configured level there is nothing user-defined
    /// to go on, so a default scale is used.
    static func color(percentage: Int, charging: Bool) -> AlertColor {
        if charging { return .green }

        let triggered = Preferences.shared.levelAlerts
            .filter { $0.isEnabled && percentage <= $0.level }
        // The lowest threshold reached is the most severe one.
        if let rule = triggered.min(by: { $0.level < $1.level }) { return rule.color }

        return defaultScale(percentage)
    }

    /// Used above every configured alert level.
    static func defaultScale(_ percentage: Int) -> AlertColor {
        switch percentage {
        case ..<10: return .red
        case ..<20: return .orange
        case ..<35: return .amber
        case ..<60: return .lime
        default: return .green
        }
    }

    static func swiftUIColor(percentage: Int, charging: Bool) -> Color {
        color(percentage: percentage, charging: charging).color
    }

    static func nsColor(percentage: Int, charging: Bool) -> NSColor {
        color(percentage: percentage, charging: charging).nsColor
    }
}
