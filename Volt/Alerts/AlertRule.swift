import Foundation
import SwiftUI
import AppKit

/// A sound the user can attach to an alert. Values map to files in /System/Library/Sounds.
enum AlertSound: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case ping = "Ping"
    case glass = "Glass"
    case submarine = "Submarine"
    case funk = "Funk"
    case hero = "Hero"
    case sosumi = "Sosumi"
    case blow = "Blow"
    case purr = "Purr"
    case tink = "Tink"

    var id: String { rawValue }
    var systemName: String? { self == .none ? nil : rawValue }
}

/// The colours an alert can be given. Stored by name so the choice survives in
/// preferences, and offered in both SwiftUI and AppKit flavours because the menu bar
/// icon is drawn with NSColor while everything else is SwiftUI.
enum AlertColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, amber, yellow, lime, green, mint, teal, blue, purple, pink, graphite

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    private var components: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .red: return (0.96, 0.24, 0.21)
        case .orange: return (0.98, 0.45, 0.13)
        case .amber: return (1.00, 0.72, 0.11)
        case .yellow: return (0.95, 0.86, 0.18)
        case .lime: return (0.80, 0.80, 0.14)
        case .green: return (0.20, 0.78, 0.35)
        case .mint: return (0.24, 0.84, 0.66)
        case .teal: return (0.19, 0.69, 0.78)
        case .blue: return (0.25, 0.56, 1.00)
        case .purple: return (0.64, 0.42, 0.95)
        case .pink: return (0.96, 0.35, 0.60)
        case .graphite: return (0.60, 0.62, 0.66)
        }
    }

    var color: Color {
        let (r, g, b) = components
        return Color(red: r, green: g, blue: b)
    }

    var nsColor: NSColor {
        let (r, g, b) = components
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

/// A user-defined low-battery threshold, crossed on the way down.
struct LevelAlert: Codable, Identifiable, Equatable {
    var id = UUID()
    var level: Int
    var isEnabled: Bool = true
    var sound: AlertSound = .ping
    /// Repeat the alert every N minutes while still at or below the level. 0 = once.
    var repeatMinutes: Int = 0
    /// Used for this alert's notification, and for the battery readout once the
    /// charge has fallen to this level.
    var color: AlertColor = .amber

    static let defaults: [LevelAlert] = [
        LevelAlert(level: 20, sound: .ping, color: .amber),
        LevelAlert(level: 10, sound: .submarine, repeatMinutes: 10, color: .orange),
        LevelAlert(level: 5, sound: .sosumi, repeatMinutes: 5, color: .red)
    ]

    // Decoded by hand so preferences saved before colours existed still load.
    private enum CodingKeys: String, CodingKey {
        case id, level, isEnabled, sound, repeatMinutes, color
    }

    init(id: UUID = UUID(), level: Int, isEnabled: Bool = true, sound: AlertSound = .ping,
         repeatMinutes: Int = 0, color: AlertColor = .amber) {
        self.id = id
        self.level = level
        self.isEnabled = isEnabled
        self.sound = sound
        self.repeatMinutes = repeatMinutes
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        level = try c.decode(Int.self, forKey: .level)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sound = try c.decodeIfPresent(AlertSound.self, forKey: .sound) ?? .ping
        repeatMinutes = try c.decodeIfPresent(Int.self, forKey: .repeatMinutes) ?? 0
        color = try c.decodeIfPresent(AlertColor.self, forKey: .color)
            ?? LevelAlert.defaultColor(for: level)
    }

    /// Sensible colour for a threshold with none saved. Spread across the range so a
    /// set of alerts reads as escalating rather than all landing on the same amber.
    static func defaultColor(for level: Int) -> AlertColor {
        switch level {
        case ...25: return .red
        case ..<35: return .amber
        // Not yellow: that is Low Power Mode's colour, and a default alert colour that
        // matched it would make the mode impossible to spot.
        default: return .lime
        }
    }
}

/// Events that are not about crossing a percentage.
enum LifecycleEvent: String, Codable, CaseIterable, Identifiable {
    case pluggedIn
    case unplugged
    case reached80
    case fullyCharged
    case highTemperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pluggedIn: return "Charger connected"
        case .unplugged: return "Charger disconnected"
        case .reached80: return "Charged to 80%"
        case .fullyCharged: return "Fully charged"
        case .highTemperature: return "Battery running hot"
        }
    }

    var explanation: String {
        switch self {
        case .pluggedIn: return "When power is connected."
        case .unplugged: return "When you pull the charger."
        case .reached80: return "Unplug here to spare the battery. Volt only tells you — it never stops charging."
        case .fullyCharged: return "When the battery reaches 100%."
        case .highTemperature: return "When the pack goes above the threshold below."
        }
    }

    var defaultSound: AlertSound {
        switch self {
        case .pluggedIn: return .tink
        case .unplugged: return .blow
        case .reached80: return .glass
        case .fullyCharged: return .hero
        case .highTemperature: return .sosumi
        }
    }

    var defaultColor: AlertColor {
        switch self {
        case .pluggedIn: return .blue
        case .unplugged: return .graphite
        case .reached80: return .green
        case .fullyCharged: return .mint
        case .highTemperature: return .orange
        }
    }
}

struct LifecycleAlert: Codable, Equatable {
    var isEnabled: Bool
    var sound: AlertSound
    var color: AlertColor = .green

    private enum CodingKeys: String, CodingKey { case isEnabled, sound, color }

    init(isEnabled: Bool, sound: AlertSound, color: AlertColor = .green) {
        self.isEnabled = isEnabled
        self.sound = sound
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        sound = try c.decode(AlertSound.self, forKey: .sound)
        color = try c.decodeIfPresent(AlertColor.self, forKey: .color) ?? .green
    }
}
