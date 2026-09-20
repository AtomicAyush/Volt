import Foundation
import AppKit
import Combine

/// Decides when to fire an alert and hands it to the presenter.
///
/// Every rule is edge-triggered: an alert fires on the transition into a state, not
/// for as long as the state lasts. Plugging in rearms the level alerts, so a charge
/// to 100% and back down to 20% alerts again, but sitting at 19% does not re-nag
/// unless the rule asks it to.
final class AlertEngine {
    static let shared = AlertEngine()

    private let prefs = Preferences.shared
    private var cancellables = Set<AnyCancellable>()

    /// Level alerts already fired during this discharge, and when.
    private var firedLevels: [UUID: Date] = [:]
    private var lastTemperatureAlert: Date = .distantPast
    private var firedDeviceAlerts: Set<String> = []

    private init() {}

    func start() {
        BatteryMonitor.shared.transitions
            .sink { [weak self] old, new in self?.evaluate(old: old, new: new) }
            .store(in: &cancellables)

        DeviceMonitor.shared.transitions
            .sink { [weak self] old, new in self?.evaluateDevices(old: old, new: new) }
            .store(in: &cancellables)
    }

    // MARK: - Internal battery

    private func evaluate(old: BatterySnapshot, new: BatterySnapshot) {
        guard new.isPresent else { return }

        // Connecting power clears the discharge history so the rules rearm.
        if new.isPluggedIn && !old.isPluggedIn {
            firedLevels.removeAll()
            fire(.pluggedIn, snapshot: new)
        }
        if !new.isPluggedIn && old.isPluggedIn {
            fire(.unplugged, snapshot: new)
        }

        // The 80% reminder: only while actually charging, and only on the crossing.
        if new.isPluggedIn, old.percentage < 80, new.percentage >= 80 {
            fire(.reached80, snapshot: new)
        }
        if new.percentage >= 100, old.percentage < 100, new.isPluggedIn {
            fire(.fullyCharged, snapshot: new)
        }

        if new.temperatureC >= prefs.highTemperatureC,
           Date().timeIntervalSince(lastTemperatureAlert) > 1800 {
            lastTemperatureAlert = Date()
            fire(.highTemperature, snapshot: new)
        }

        evaluateLevels(old: old, new: new)
    }

    private func evaluateLevels(old: BatterySnapshot, new: BatterySnapshot) {
        guard new.isDischarging else { return }

        for rule in prefs.levelAlerts where rule.isEnabled {
            let crossedDown = old.percentage > rule.level && new.percentage <= rule.level
            let firedAt = firedLevels[rule.id]

            var shouldFire = false
            if crossedDown, firedAt == nil {
                shouldFire = true
            } else if let firedAt, rule.repeatMinutes > 0, new.percentage <= rule.level,
                      Date().timeIntervalSince(firedAt) >= Double(rule.repeatMinutes) * 60 {
                shouldFire = true
            } else if firedAt == nil, new.percentage <= rule.level, old.percentage <= rule.level,
                      old.updated == .distantPast {
                // Launched while already below the threshold.
                shouldFire = true
            }

            guard shouldFire else { continue }
            firedLevels[rule.id] = Date()
            let urgency = Self.urgency(for: new.percentage)
            present(
                title: "\(new.percentage)% Remaining",
                body: urgency == .critical ? "Connect charger immediately" : new.untilText,
                level: new.percentage,
                sound: rule.sound,
                urgency: urgency
            )
        }
    }

    private func fire(_ event: LifecycleEvent, snapshot: BatterySnapshot) {
        let alert = prefs.lifecycleAlert(event)
        guard alert.isEnabled else { return }

        let body: String
        switch event {
        case .pluggedIn:
            body = snapshot.adapterWatts.map { "\($0)W adapter · \(snapshot.percentage)%" }
                ?? "Charging from \(snapshot.percentage)%"
        case .unplugged:
            body = snapshot.untilText
        case .reached80:
            body = "Unplug now to go easy on the battery."
        case .fullyCharged:
            body = "100% · \(snapshot.cycleCount) cycles"
        case .highTemperature:
            body = String(format: "Pack is at %.0f°C.", snapshot.temperatureC)
        }

        let urgency: HUDUrgency = event == .highTemperature
            ? .warning
            : (event == .unplugged ? Self.urgency(for: snapshot.percentage) : .normal)
        present(title: event.title, body: body, level: snapshot.percentage,
                sound: alert.sound, urgency: urgency)
    }

    // MARK: - Accessories

    private func evaluateDevices(old: [DeviceBattery], new: [DeviceBattery]) {
        guard prefs.deviceAlertsEnabled, prefs.trackDeviceBatteries else { return }
        let threshold = prefs.deviceAlertLevel

        for device in new where device.isConnected && device.hasReading {
            let previous = old.first { $0.id == device.id }
            let wasAbove = previous.map { $0.lowestPercent > threshold } ?? true

            if device.lowestPercent <= threshold {
                guard wasAbove, !firedDeviceAlerts.contains(device.id) else { continue }
                firedDeviceAlerts.insert(device.id)
                present(title: "\(device.name) at \(device.lowestPercent)%",
                        body: "Time to charge it",
                        level: device.lowestPercent, sound: .ping, urgency: .warning,
                        symbol: device.kind.symbol)
            } else if device.lowestPercent > threshold + 5 {
                // Rearm once it has meaningfully recovered.
                firedDeviceAlerts.remove(device.id)
            }
        }
    }

    /// Colour follows the level, the way the alert reads at a glance:
    /// green comfortable, amber getting low, red act now.
    static func urgency(for percent: Int) -> HUDUrgency {
        switch percent {
        case ..<6: return .critical
        case ..<21: return .warning
        default: return .normal
        }
    }

    // MARK: - Presentation

    func present(title: String, body: String, level: Int, sound: AlertSound,
                 urgency: HUDUrgency, symbol: String? = nil) {
        if let name = sound.systemName, let nsSound = NSSound(named: name) {
            nsSound.play()
        }
        if prefs.showHUD {
            let seconds = prefs.hudSeconds
            let glow = prefs.screenGlow
            Task { @MainActor in
                HUDPresenter.shared.show(title: title, body: body, level: level,
                                         urgency: urgency, symbol: symbol,
                                         duration: seconds, glow: glow)
            }
        }
        if prefs.postSystemNotification {
            Notifier.shared.post(title: title, body: body)
        }
    }
}
