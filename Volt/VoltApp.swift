import SwiftUI
import AppKit

@main
struct VoltApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Volt lives entirely in the menu bar; the status item is created by the
        // delegate, so this scene intentionally has no windows of its own.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        BatteryMonitor.shared.start()
        AlertEngine.shared.start()
        statusItem.install()

        let prefs = Preferences.shared
        if prefs.trackDeviceBatteries {
            IOSDeviceMonitor.shared.start()
            DeviceMonitor.shared.start()
        }
        if prefs.trackEnergy { EnergyMonitor.shared.start() }
        if prefs.postSystemNotification { Notifier.shared.requestAuthorizationIfNeeded() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
