import SwiftUI

/// Volt on the watch: reads the watch's own battery and hands it to the iPhone, which
/// passes it on to the Mac. The Mac cannot read an Apple Watch's battery by any route of
/// its own, so this app exists purely to report it.
@main
struct VoltWatchApp: App {
    @StateObject private var reporter = BatteryReporter.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(reporter)
                .task { await reporter.reportAndReschedule() }
        }
        // Background refresh keeps the Mac's figure current while the app is closed.
        // watchOS decides the actual cadence; asking for fifteen minutes is a request.
        .backgroundTask(.appRefresh(BatteryReporter.refreshIdentifier)) {
            await BatteryReporter.shared.reportAndReschedule()
        }
    }
}
