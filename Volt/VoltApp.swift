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
            BLEBatteryMonitor.shared.start()
            IOSDeviceMonitor.shared.start()
            DeviceMonitor.shared.start()
        }
        if prefs.trackEnergy { EnergyMonitor.shared.start() }
        if prefs.postSystemNotification { Notifier.shared.requestAuthorizationIfNeeded() }
        startDebugLoggingIfRequested()
        snapshotSettingsIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// With ~/.volt-snapshot present, draws each settings pane in a real window and saves
    /// it to ~/.volt-snapshots. It exists because a menu-bar-only app cannot be screen-
    /// grabbed by the usual tools, and offscreen renders cannot draw AppKit controls.
    private func snapshotSettingsIfRequested() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let marker = home.appendingPathComponent(".volt-snapshot")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.removeItem(at: marker)

        let folder = home.appendingPathComponent(".volt-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var remaining = SettingsPane.allCases
        func next() {
            guard !remaining.isEmpty else { return }
            let pane = remaining.removeFirst()
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(initialPane: pane)))
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.title = "Volt Settings"
            window.appearance = NSAppearance(named: .darkAqua)
            window.setContentSize(NSSize(width: 760, height: 580))
            window.center()
            window.orderFrontRegardless()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let view = window.contentView?.superview ?? window.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: folder.appendingPathComponent("\(pane.rawValue).png"))
                }
                window.close()
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { next() }
    }

    /// Run the binary with VOLT_DEBUG=1 to watch device discovery from a terminal.
    /// Useful when checking whether a phone is answering over Bluetooth.
    private func startDebugLoggingIfRequested() {
        // Either VOLT_DEBUG in the environment, or ~/.volt-debug on disk — the file
        // works no matter how the app was launched.
        let marker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".volt-debug")
        let enabled = ProcessInfo.processInfo.environment["VOLT_DEBUG"] != nil
            || FileManager.default.fileExists(atPath: marker.path)
        guard enabled else { return }

        var helperLine = "helper: not checked"
        HelperClient.shared.refreshStatus()
        HelperClient.shared.ping { answer in
            helperLine = "helper: status=\(HelperClient.shared.status.rawValue) version=\(answer ?? "none")"
        }

        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".volt-debug.log")

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            let ble = BLEBatteryMonitor.shared
            var lines = ["--- \(Date())", helperLine]
            lines.append("bluetooth state=\(ble.state.rawValue) ble=\(ble.batteries.map { "\($0.name):\($0.percent)%" })")
            lines.append("cabled=\(IOSDeviceMonitor.shared.devices.map { "\($0.name):\($0.percent)%" })")
            lines.append("tracked(known \(ble.knownCount)): \(ble.trackedSummary)")
            for (model, r) in ble.continuity.sorted(by: { $0.key < $1.key }) {
                lines.append(String(format: "  continuity 0x%04x: %@/%@/%@ rssi=%d",
                                    model,
                                    r.primary.map { "\($0)%" } ?? "-",
                                    r.secondary.map { "\($0)%" } ?? "-",
                                    r.caseLevel.map { "\($0)%" } ?? "-",
                                    r.rssi))
            }
            for d in DeviceMonitor.shared.devices {
                lines.append("  \(d.name) [\(d.kind.rawValue)] cells=\(d.cells.map(\.percent)) note=\(d.note ?? "-")")
            }
            let text = lines.joined(separator: "\n") + "\n"
            if let data = text.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: logURL)
                }
            }
        }
    }
}
