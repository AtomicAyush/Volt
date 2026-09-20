import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            AlertSettings()
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
            LifecycleSettings()
                .tabItem { Label("Charging", systemImage: "bolt") }
            AppearanceSettings()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            DeviceSettings()
                .tabItem { Label("Devices", systemImage: "airpods.pro") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 520, height: 560)
    }
}

// MARK: - Alerts

struct AlertSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var newLevel: Double = 30

    var body: some View {
        Form {
            Section {
                Text("Volt alerts you every time the battery falls past one of these levels. macOS only ever gives you 10% and 5%.")
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
                        .frame(width: 120)

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

                Button("Preview an alert") {
                    AlertEngine.shared.present(title: "18% Remaining",
                                               body: "1h 12min until empty",
                                               level: 18, sound: .ping, urgency: .warning)
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
                            .frame(width: 110)
                            .disabled(!binding.wrappedValue.isEnabled)
                            .onChange(of: binding.wrappedValue.sound) { _, sound in
                                if let name = sound.systemName { NSSound(named: name)?.play() }
                            }
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
                }
                .disabled(!prefs.trackDeviceBatteries || !prefs.deviceAlertsEnabled)
            } header: {
                Text("Accessories").font(.system(size: 12, weight: .semibold))
            } footer: {
                Text("AirPods and accessories come from macOS's Bluetooth report. iPhone and iPad levels are read straight from the Bluetooth battery service, which needs the device paired and nearby — health and cycle count still need a cable.")
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
                            Text(device.cells.map { $0.label.isEmpty ? "\($0.percent)%" : "\($0.label) \($0.percent)%" }
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
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
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

            Section {
                Text("Volt reads the battery through IOKit and never sends anything anywhere. It does not modify charging behaviour.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Quit Volt") { NSApp.terminate(nil) }
            } header: {
                Text("About").font(.system(size: 12, weight: .semibold))
            }
        }
        .formStyle(.grouped)
    }
}
