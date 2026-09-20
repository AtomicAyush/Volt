import Foundation

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

/// A user-defined low-battery threshold, crossed on the way down.
struct LevelAlert: Codable, Identifiable, Equatable {
    var id = UUID()
    var level: Int
    var isEnabled: Bool = true
    var sound: AlertSound = .ping
    /// Repeat the alert every N minutes while still at or below the level. 0 = once.
    var repeatMinutes: Int = 0

    static let defaults: [LevelAlert] = [
        LevelAlert(level: 20, sound: .ping),
        LevelAlert(level: 10, sound: .submarine, repeatMinutes: 10),
        LevelAlert(level: 5, sound: .sosumi, repeatMinutes: 5)
    ]
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
}

struct LifecycleAlert: Codable, Equatable {
    var isEnabled: Bool
    var sound: AlertSound
}
