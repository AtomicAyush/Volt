import AppKit
import SwiftUI
import Combine

/// Owns the menu bar item and the panel that drops out of it.
///
/// An `NSStatusItem` is used rather than SwiftUI's `MenuBarExtra` so the icon can be a
/// custom-drawn, optionally coloured image whose width changes with the style.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    /// Holds the panel's view only while it is open; see `popoverDidClose`.
    private let popoverContent = NSHostingController(rootView: AnyView(EmptyView()))
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = popoverContent

        BatteryMonitor.shared.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in self?.render(snapshot) }
            .store(in: &cancellables)

        // Redraw when the icon style or colour preference changes.
        let prefs = Preferences.shared
        Publishers.Merge4(
            prefs.$iconStyle.map { _ in () },
            prefs.$useColorInIcon.map { _ in () },
            prefs.$showTimeRemainingInIcon.map { _ in () },
            prefs.objectWillChange.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.render(BatteryMonitor.shared.snapshot) }
        .store(in: &cancellables)

        LowPowerMode.shared.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render(BatteryMonitor.shared.snapshot) }
            .store(in: &cancellables)

        render(BatteryMonitor.shared.snapshot)
    }

    private func render(_ snapshot: BatterySnapshot) {
        guard let button = statusItem.button else { return }
        let prefs = Preferences.shared

        button.image = MenuBarIcon.image(for: snapshot,
                                         style: prefs.iconStyle,
                                         colored: prefs.useColorInIcon)
        button.imagePosition = prefs.showTimeRemainingInIcon ? .imageLeading : .imageOnly

        if prefs.showTimeRemainingInIcon, let minutes = snapshot.minutesRemaining, minutes > 0 {
            let hours = minutes / 60, rest = minutes % 60
            button.title = hours > 0 ? " \(hours):\(String(format: "%02d", rest))" : " \(rest)m"
        } else {
            button.title = ""
        }

        var tooltip = "\(snapshot.percentage)% · \(snapshot.timeRemainingText)"
        if LowPowerMode.shared.isEnabled { tooltip += " · Low Power Mode" }
        if let health = snapshot.healthPercent {
            tooltip += String(format: "\nHealth %.0f%% · %d cycles", health, snapshot.cycleCount)
        }
        button.toolTip = tooltip
    }

    // MARK: - Interaction

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            BatteryMonitor.shared.refresh()
            DeviceMonitor.shared.refresh()
            EnergyMonitor.shared.sample()
            popoverContent.rootView = AnyView(
                PopoverView(openSettings: { [weak self] in self?.openSettings() },
                            quit: { NSApp.terminate(nil) })
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// A closed panel's view stays in its window, still following every reading and
    /// running its animations. Dropping it once the panel is gone stops all of that; it
    /// is built again, with fresh readings, the next time the panel opens.
    func popoverDidClose(_ notification: Notification) {
        popoverContent.rootView = AnyView(EmptyView())
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Test Alert", action: #selector(testAlert), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Volt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // restore click-to-popover for the next left click
    }

    @objc private func testAlert() {
        let snapshot = BatteryMonitor.shared.snapshot
        AlertEngine.shared.present(title: "\(snapshot.percentage)% Remaining",
                                   body: snapshot.untilText,
                                   level: snapshot.percentage,
                                   sound: .ping,
                                   accent: BatteryTint.color(percentage: snapshot.percentage,
                                                             charging: snapshot.isCharging))
    }

    @objc func openSettings() {
        popover.performClose(nil)

        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Volt Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 760, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Settings is built afresh each time it opens, so a closed one is let go rather
    /// than kept updating in the background.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        settingsWindow = nil
    }
}
