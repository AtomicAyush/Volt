import Foundation
import WatchKit
import WatchConnectivity

/// Reads the watch battery and sends it to the paired iPhone.
@MainActor
final class BatteryReporter: NSObject, ObservableObject {
    static let shared = BatteryReporter()
    static let refreshIdentifier = "volt.battery"

    @Published private(set) var percent: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var lastSent: Date?
    @Published private(set) var lastError: String?

    private override init() {
        super.init()
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func reportAndReschedule() async {
        await report()
        scheduleNextRefresh()
    }

    func report() async {
        let device = WKInterfaceDevice.current()
        let level = device.batteryLevel            // 0...1, or -1 when unknown
        guard level >= 0 else {
            lastError = "The watch did not report a battery level."
            return
        }

        let value = Int((level * 100).rounded())
        let charging = device.batteryState == .charging
        let full = device.batteryState == .full
        percent = value
        isCharging = charging || full

        let message: [String: Any] = [
            "percent": value,
            "charging": charging,
            "full": full,
            "reportedAt": Date().timeIntervalSince1970
        ]
        await send(message)
    }

    private func send(_ message: [String: Any]) async {
        let session = WCSession.default
        // Give activation a moment when woken in the background.
        for _ in 0..<20 where session.activationState != .activated {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard session.activationState == .activated else {
            lastError = "Not connected to the iPhone yet."
            return
        }

        // The latest value always goes into the application context, which the iPhone
        // picks up whenever it next runs.
        try? session.updateApplicationContext(message)

        if session.isReachable {
            // A live message also wakes the iPhone app if it is not running.
            session.sendMessage(message, replyHandler: nil) { [weak self] error in
                Task { @MainActor in self?.lastError = error.localizedDescription }
            }
        } else {
            // Queued and delivered when the phone comes back into range.
            session.transferUserInfo(message)
        }
        lastSent = Date()
        lastError = nil
    }

    private func scheduleNextRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: 15 * 60),
            userInfo: Self.refreshIdentifier as NSString
        ) { _ in }
    }
}

extension BatteryReporter: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}
}
