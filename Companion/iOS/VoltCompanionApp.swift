import SwiftUI

/// The iPhone half: receives the watch battery from the watch app and publishes it as a
/// Bluetooth value the Mac can read. Volt on the Mac already holds a Bluetooth connection
/// to this iPhone for the phone's own battery, so it reads this extra value over the same
/// link — no network and no cloud account involved.
@main
struct VoltCompanionApp: App {
    @StateObject private var link = WatchLink.shared
    @StateObject private var peripheral = BatteryPeripheral.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(link)
                .environmentObject(peripheral)
        }
    }
}
