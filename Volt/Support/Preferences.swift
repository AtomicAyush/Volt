import Foundation
import Combine

/// Menu bar icon styles.
enum IconStyle: String, Codable, CaseIterable, Identifiable {
    case pill          // iPhone-style horizontal battery
    case pillNumber    // same, with the number inside
    case numberOnly
    case ring

    var id: String { rawValue }
    var label: String {
        switch self {
        case .pill: return "Battery"
        case .pillNumber: return "Battery with percentage inside"
        case .numberOnly: return "Number only"
        case .ring: return "Ring"
        }
    }
}

/// Everything the user can change, persisted as JSON next to the energy history.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var levelAlerts: [LevelAlert] = LevelAlert.defaults { didSet { save() } }
    @Published var lifecycle: [String: LifecycleAlert] = Preferences.defaultLifecycle { didSet { save() } }

    @Published var iconStyle: IconStyle = .pillNumber { didSet { save() } }
    @Published var useColorInIcon: Bool = true { didSet { save() } }
    @Published var showTimeRemainingInIcon: Bool = false { didSet { save() } }

    @Published var showHUD: Bool = true { didSet { save() } }
    @Published var screenGlow: Bool = true { didSet { save() } }
    @Published var hudSeconds: Double = 5 { didSet { save() } }
    @Published var postSystemNotification: Bool = false { didSet { save() } }

    @Published var trackDeviceBatteries: Bool = true { didSet { save() } }
    @Published var deviceAlertLevel: Int = 15 { didSet { save() } }
    @Published var deviceAlertsEnabled: Bool = true { didSet { save() } }

    @Published var highTemperatureC: Double = 40 { didSet { save() } }
    @Published var trackEnergy: Bool = true { didSet { save() } }

    private var isLoading = false

    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Volt", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("preferences.json")
    }

    static var defaultLifecycle: [String: LifecycleAlert] {
        var result: [String: LifecycleAlert] = [:]
        for event in LifecycleEvent.allCases {
            // Only the 80% reminder is on out of the box; the rest would be chatty.
            result[event.rawValue] = LifecycleAlert(isEnabled: event == .reached80,
                                                    sound: event.defaultSound)
        }
        return result
    }

    func lifecycleAlert(_ event: LifecycleEvent) -> LifecycleAlert {
        lifecycle[event.rawValue] ?? LifecycleAlert(isEnabled: false, sound: event.defaultSound)
    }

    func setLifecycle(_ event: LifecycleEvent, _ alert: LifecycleAlert) {
        lifecycle[event.rawValue] = alert
    }

    private init() { load() }

    // MARK: - Persistence

    private struct Payload: Codable {
        var levelAlerts: [LevelAlert]
        var lifecycle: [String: LifecycleAlert]
        var iconStyle: IconStyle
        var useColorInIcon: Bool
        var showTimeRemainingInIcon: Bool
        var showHUD: Bool
        var screenGlow: Bool
        var hudSeconds: Double
        var postSystemNotification: Bool
        var trackDeviceBatteries: Bool
        var deviceAlertLevel: Int
        var deviceAlertsEnabled: Bool
        var highTemperatureC: Double
        var trackEnergy: Bool
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        isLoading = true
        levelAlerts = p.levelAlerts
        lifecycle = p.lifecycle
        iconStyle = p.iconStyle
        useColorInIcon = p.useColorInIcon
        showTimeRemainingInIcon = p.showTimeRemainingInIcon
        showHUD = p.showHUD
        screenGlow = p.screenGlow
        hudSeconds = p.hudSeconds
        postSystemNotification = p.postSystemNotification
        trackDeviceBatteries = p.trackDeviceBatteries
        deviceAlertLevel = p.deviceAlertLevel
        deviceAlertsEnabled = p.deviceAlertsEnabled
        highTemperatureC = p.highTemperatureC
        trackEnergy = p.trackEnergy
        isLoading = false
    }

    private func save() {
        guard !isLoading else { return }
        let payload = Payload(levelAlerts: levelAlerts, lifecycle: lifecycle, iconStyle: iconStyle,
                              useColorInIcon: useColorInIcon,
                              showTimeRemainingInIcon: showTimeRemainingInIcon,
                              showHUD: showHUD, screenGlow: screenGlow, hudSeconds: hudSeconds,
                              postSystemNotification: postSystemNotification,
                              trackDeviceBatteries: trackDeviceBatteries,
                              deviceAlertLevel: deviceAlertLevel,
                              deviceAlertsEnabled: deviceAlertsEnabled,
                              highTemperatureC: highTemperatureC, trackEnergy: trackEnergy)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
