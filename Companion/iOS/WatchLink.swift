import Foundation
import WatchConnectivity

struct WatchReading: Codable, Equatable {
    let percent: Int
    let charging: Bool
    let full: Bool
    let reportedAt: Date
}

/// Receives readings from the watch app, keeps the latest, and hands it to Bluetooth.
final class WatchLink: NSObject, ObservableObject {
    static let shared = WatchLink()
    private static let storeKey = "latestWatchReading"

    @Published private(set) var latest: WatchReading?
    @Published private(set) var isPaired = false
    @Published private(set) var isAppInstalled = false

    private override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode(WatchReading.self, from: data) {
            latest = saved
            BatteryPeripheral.shared.update(with: saved)
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let percent = message["percent"] as? Int else { return }
        let reading = WatchReading(
            percent: percent,
            charging: message["charging"] as? Bool ?? false,
            full: message["full"] as? Bool ?? false,
            reportedAt: Date(timeIntervalSince1970: message["reportedAt"] as? Double
                             ?? Date().timeIntervalSince1970)
        )
        // Messages can arrive out of order; never replace a newer reading with an older one.
        if let latest, latest.reportedAt > reading.reportedAt { return }

        DispatchQueue.main.async {
            self.latest = reading
            if let data = try? JSONEncoder().encode(reading) {
                UserDefaults.standard.set(data, forKey: Self.storeKey)
            }
            BatteryPeripheral.shared.update(with: reading)
        }
    }

    private func refreshPairing(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isPaired = session.isPaired
            self.isAppInstalled = session.isWatchAppInstalled
        }
    }
}

extension WatchLink: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        refreshPairing(session)
        if !session.receivedApplicationContext.isEmpty { handle(session.receivedApplicationContext) }
    }
    func sessionWatchStateDidChange(_ session: WCSession) { refreshPairing(session) }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { handle(message) }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { handle(userInfo) }
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) { handle(context) }
}
