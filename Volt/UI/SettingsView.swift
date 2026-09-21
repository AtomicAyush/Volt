import SwiftUI
import AppKit

/// A compact colour chooser for an alert.
struct ColorWell: View {
    @Binding var selection: AlertColor

    var body: some View {
        HStack(spacing: 6) {
            // Outside the Menu on purpose: macOS strips custom shapes from menu labels,
            // which left the picker showing a colour's name with no colour.
            Circle()
                .fill(selection.color)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 0.5))
            Picker("", selection: $selection) {
                ForEach(AlertColor.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 92)
        }
    }
}

/// The panes of the settings window, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case alerts, charging, menuBar, devices, general, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alerts: return "Alerts"
        case .charging: return "Charging"
        case .menuBar: return "Menu Bar"
        case .devices: return "Devices"
        case .general: return "General"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .alerts: return "bell.badge.fill"
        case .charging: return "bolt.fill"
        case .menuBar: return "menubar.rectangle"
        case .devices: return "airpods.gen3"
        case .general: return "gearshape.fill"
        case .about: return "info.circle.fill"
        }
    }

    /// The coloured tile behind each icon, as System Settings draws them.
    var tile: Color {
        switch self {
        case .alerts: return .red
        case .charging: return .green
        case .menuBar: return .blue
        case .devices: return .purple
        case .general: return .gray
        case .about: return .indigo
        }
    }
}

/// A sidebar on the left, the selected pane on the right — the layout System Settings
/// uses. It replaces a tab bar that, on current macOS, floated up into the title bar and
/// was clipped by it.
struct SettingsView: View {
    @State private var pane: SettingsPane

    init(initialPane: SettingsPane = .alerts) {
        _pane = State(initialValue: initialPane)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPane.allCases, selection: $pane) { item in
                Label {
                    Text(item.title)
                } icon: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(item.tile.gradient))
                }
                .padding(.vertical, 2)
                .tag(item)
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text(pane.title)
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 4)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 760, height: 580)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .alerts: AlertSettings()
        case .charging: LifecycleSettings()
        case .menuBar: AppearanceSettings()
        case .devices: DeviceSettings()
        case .general: GeneralSettings()
        case .about: AboutSettings()
        }
    }
}

// MARK: - Alerts

struct AlertSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var newLevel: Double = 30

    var body: some View {
        Form {
            Section {
                Text("Volt alerts you every time the battery falls past one of these levels. macOS only ever gives you 10% and 5%. Each alert's colour is used for its notification, and for the battery readout once the charge has fallen that far.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                ForEach($prefs.levelAlerts) { $alert in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $alert.isEnabled).labelsHidden()

                        Text("\(alert.level)%")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .leading)

                        Picker("", selection: $alert.sound) {
                            ForEach(AlertSound.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        .onChange(of: alert.sound) { _, sound in
                            if let name = sound.systemName { NSSound(named: name)?.play() }
                        }

                        Picker("", selection: $alert.repeatMinutes) {
                            Text("Once").tag(0)
                            Text("Every 5 min").tag(5)
                            Text("Every 10 min").tag(10)
                            Text("Every 30 min").tag(30)
                        }
                        .labelsHidden()
                        .frame(width: 112)

                        ColorWell(selection: $alert.color)

                        Button {
                            prefs.levelAlerts.removeAll { $0.id == alert.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .opacity(alert.isEnabled ? 1 : 0.5)
                }

                HStack {
                    Slider(value: $newLevel, in: 1...99, step: 1) {
                        Text("\(Int(newLevel))%").monospacedDigit().frame(width: 42)
                    }
                    Button("Add alert") {
                        let level = Int(newLevel)
                        guard !prefs.levelAlerts.contains(where: { $0.level == level }) else { return }
                        prefs.levelAlerts.append(LevelAlert(level: level))
                        prefs.levelAlerts.sort { $0.level > $1.level }
                    }
                }
            } header: {
                Text("Low battery levels").font(.system(size: 12, weight: .semibold))
            }

            Section {
                Toggle("Show Volt's notification pill", isOn: $prefs.showHUD)
                Toggle("Make the screen edges glow", isOn: $prefs.screenGlow)
                    .disabled(!prefs.showHUD)
                HStack {
                    Text("Dismiss after")
                    Slider(value: $prefs.hudSeconds, in: 2...20, step: 1)
                    Text("\(Int(prefs.hudSeconds))s").monospacedDigit().frame(width: 30)
                }
                .disabled(!prefs.showHUD)

                Toggle("Also post to Notification Center", isOn: $prefs.postSystemNotification)
                    .onChange(of: prefs.postSystemNotification) { _, on in
                        if on { Notifier.shared.requestAuthorizationIfNeeded() }
                    }

                HStack {
                    Text("Preview")
                    Spacer()
                    ForEach(prefs.levelAlerts) { alert in
                        Button("\(alert.level)%") {
                            AlertEngine.shared.present(
                                title: "\(alert.level)% Remaining",
                                body: alert.level <= 5 ? "Connect charger immediately"
                                                       : "1h 12min until empty",
                                level: alert.level, sound: alert.sound, accent: alert.color)
                        }
                    }
                }
            } header: {
                Text("How alerts look").font(.system(size: 12, weight: .semibold))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Charging

struct LifecycleSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                ForEach(LifecycleEvent.allCases) { event in
                    let binding = Binding(
                        get: { prefs.lifecycleAlert(event) },
                        set: { prefs.setLifecycle(event, $0) }
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Toggle(event.title, isOn: binding.isEnabled)
                            Spacer()
                            Picker("", selection: binding.sound) {
                                ForEach(AlertSound.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 104)
                            .disabled(!binding.wrappedValue.isEnabled)
                            .onChange(of: binding.wrappedValue.sound) { _, sound in
                                if let name = sound.systemName { NSSound(named: name)?.play() }
                            }

                            ColorWell(selection: binding.color)
                                .disabled(!binding.wrappedValue.isEnabled)
                        }
                        Text(event.explanation)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Charging events").font(.system(size: 12, weight: .semibold))
            } footer: {
                Text("Volt never changes how your Mac charges. It watches and tells you — nothing is written to the charging controller.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Warn above")
                    Slider(value: $prefs.highTemperatureC, in: 33...50, step: 1)
                    Text("\(Int(prefs.highTemperatureC))°C").monospacedDigit().frame(width: 44)
                }
                Text(String(format: "Right now the pack is at %.1f°C.",
                            BatteryMonitor.shared.snapshot.temperatureC))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Temperature").font(.system(size: 12, weight: .semibold))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Menu bar

struct AppearanceSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var battery = BatteryMonitor.shared

    /// The live battery, restated at a given level, so the previews show how each
    /// style looks as the charge falls.
    private func preview(at level: Int) -> BatterySnapshot {
        var snapshot = battery.snapshot
        snapshot.percentage = level
        snapshot.isCharging = false
        return snapshot
    }

    var body: some View {
        Form {
            Section {
                Picker("Icon style", selection: $prefs.iconStyle) {
                    ForEach(IconStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Colour the icon as the battery drops", isOn: $prefs.useColorInIcon)
                Toggle("Show time remaining next to the icon", isOn: $prefs.showTimeRemainingInIcon)
            } header: {
                Text("Appearance").font(.system(size: 12, weight: .semibold))
            }

            Section {
                HStack(spacing: 24) {
                    ForEach([100, 55, 18, 7], id: \.self) { level in
                        VStack(spacing: 6) {
                            Image(nsImage: MenuBarIcon.image(for: preview(at: level),
                                                             style: prefs.iconStyle,
                                                             colored: prefs.useColorInIcon))
                                .renderingMode(prefs.useColorInIcon ? .original : .template)
                            Text("\(level)%")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } header: {
                Text("Preview").font(.system(size: 12, weight: .semibold))
            } footer: {
                Text("macOS's own battery icon can be hidden in System Settings › Control Centre › Battery.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Devices

struct DeviceSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var devices = DeviceMonitor.shared

    var body: some View {
        Form {
            Section {
                Toggle("Track AirPods, mice, keyboards and trackpads", isOn: $prefs.trackDeviceBatteries)
                    .onChange(of: prefs.trackDeviceBatteries) { _, on in
                        if on {
                            BLEBatteryMonitor.shared.start()
                            IOSDeviceMonitor.shared.start()
                            DeviceMonitor.shared.start()
                        } else {
                            BLEBatteryMonitor.shared.stop()
                            DeviceMonitor.shared.stop()
                        }
                    }
                Toggle("Alert me when one runs low", isOn: $prefs.deviceAlertsEnabled)
                    .disabled(!prefs.trackDeviceBatteries)
                HStack {
                    Text("Low at")
                    Slider(value: Binding(get: { Double(prefs.deviceAlertLevel) },
                                          set: { prefs.deviceAlertLevel = Int($0) }),
                           in: 5...50, step: 5)
                    Text("\(prefs.deviceAlertLevel)%").monospacedDigit().frame(width: 40)
                    ColorWell(selection: $prefs.deviceAlertColor)
                }
                .disabled(!prefs.trackDeviceBatteries || !prefs.deviceAlertsEnabled)
            } header: {
                Text("Accessories").font(.system(size: 12, weight: .semibold))
            } footer: {
                Text("AirPods levels come from the Bluetooth framework — the same figures the Sound menu shows. iPhone and iPad are read from their Bluetooth battery service and need to be paired and nearby.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section {
                if devices.devices.isEmpty {
                    Text("Nothing found yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(devices.devices) { device in
                        HStack {
                            Image(systemName: device.kind.symbol).frame(width: 18)
                            Text(device.name).font(.system(size: 12))
                            Spacer()
                            Text(device.cells.isEmpty
                                 ? (device.note ?? "No reading")
                                 : device.cells.map { $0.label.isEmpty ? "\($0.percent)%" : "\($0.label) \($0.percent)%" }
                                    .joined(separator: "  "))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(device.isConnected ? .secondary : .tertiary)
                        }
                    }
                }
                Button("Refresh now") {
                    BLEBatteryMonitor.shared.refresh()
                    IOSDeviceMonitor.shared.refresh()
                    DeviceMonitor.shared.refresh()
                }
            } header: {
                Text("Found").font(.system(size: 12, weight: .semibold))
            } footer: {
                Text("Right-click a device in the panel to hide it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if !prefs.hiddenDevices.isEmpty {
                Section {
                    ForEach(prefs.hiddenDevices.sorted(), id: \.self) { key in
                        HStack {
                            Text(prefs.hiddenDeviceNames[key] ?? key)
                                .font(.system(size: 12))
                            Spacer()
                            Button("Show") { DeviceMonitor.shared.unhide(key: key) }
                        }
                    }
                } header: {
                    Text("Hidden").font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var helper = HelperClient.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var helperError: String?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Low Power Mode helper")
                        Text(helperStatusText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(helper.isReady ? .green
                                             : (helper.needsApproval ? .orange : .secondary))
                    }
                    Spacer()
                    helperButton
                }
                Text("A small helper that runs as administrator so the Low Power Mode switch works without a password prompt each time. It can only switch Low Power Mode on or off, only accepts requests from Volt, and is started by macOS when needed and exits when idle.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let helperError {
                    Text(helperError).font(.system(size: 10)).foregroundStyle(.red)
                }
            } header: {
                Text("Low Power Mode").font(.system(size: 12, weight: .semibold))
            }

            Section {
                Toggle("Open Volt at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        LaunchAtLogin.isEnabled = on
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                if LaunchAtLogin.needsApproval {
                    Text("macOS is waiting for you to allow Volt in System Settings › General › Login Items.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Startup").font(.system(size: 12, weight: .semibold))
            }

            Section {
                Toggle("Track which apps drain the battery", isOn: $prefs.trackEnergy)
                    .onChange(of: prefs.trackEnergy) { _, on in
                        on ? EnergyMonitor.shared.start() : EnergyMonitor.shared.stop()
                    }
                Text("Volt samples running processes every two minutes and keeps 30 days of history in Application Support, on this Mac only.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Energy").font(.system(size: 12, weight: .semibold))
            }

        }
        .formStyle(.grouped)
    }
}

extension GeneralSettings {
    fileprivate var helperStatusText: String {
        switch helper.status {
        case .enabled: return "Installed — the switch works without prompting"
        case .requiresApproval: return "Waiting for approval in System Settings › Login Items"
        case .notFound: return "Not found in this build — reinstall with install.sh"
        default: return "Not installed — the switch asks for a password each time"
        }
    }

    @ViewBuilder
    fileprivate var helperButton: some View {
        switch helper.status {
        case .enabled:
            Button("Remove") { helper.uninstall() }
        case .requiresApproval:
            Button("Approve…") { helper.openApprovalSettings() }
        default:
            Button("Install") {
                do {
                    try helper.install()
                    helperError = nil
                    if helper.needsApproval { helper.openApprovalSettings() }
                } catch {
                    helperError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "1.0"
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(nsImage: MenuBarIcon.image(for: previewSnapshot,
                                                     style: .pillNumber, colored: true))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Volt")
                            .font(.system(size: 22, weight: .bold))
                        Text("Version \(version)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Made by Ayush Kansal")
                        .font(.system(size: 13, weight: .semibold))
                    Text("A battery app for macOS that does what the built-in one won't: alert at any level you choose, show how healthy the pack actually is, and keep track of everything else you carry.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("How it's built")
                        .font(.system(size: 13, weight: .semibold))

                    detail("Written in Swift, with SwiftUI for the panel and settings and AppKit for the menu bar item, the alert overlay and the icon, which is drawn by hand rather than assembled from system symbols.")
                    detail("Charge, health, cycle count and temperature are read from IOKit's AppleSmartBattery entry. Current, voltage and adapter power come from the System Management Controller, which refreshes about once a second — the battery entry itself can go eight seconds or more between updates.")
                    detail("iPhone and iPad report their battery over Bluetooth, through the standard GATT battery service, so no cable is needed. AirPods levels come from the Bluetooth framework — the same figures the Sound menu shows — with their own broadcasts as a fallback.")
                    detail("Low Power Mode is switched through a small helper that runs as administrator, can do nothing else, and only answers to Volt.")
                    detail("Per-app energy use is sampled from the same energy-impact figure Activity Monitor shows, then kept on disk so the 24-hour, 7-day and 30-day views have real history behind them.")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Privacy")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Nothing ever leaves this Mac. Preferences and energy history are stored in ~/Library/Application Support/Volt, and there is no network code anywhere in the app.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Charging")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Volt never changes how your Mac charges. It reads and reports; nothing is written to the charging controller.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func detail(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A healthy-looking battery for the icon shown beside the title.
    private var previewSnapshot: BatterySnapshot {
        var snapshot = BatteryMonitor.shared.snapshot
        if !snapshot.isPresent { snapshot.percentage = 82 }
        return snapshot
    }
}
