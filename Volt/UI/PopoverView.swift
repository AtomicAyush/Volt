import SwiftUI

/// Carries the measured height of the popover's content up to the frame.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Which group of panels the selector is showing.
enum PanelTab: String, CaseIterable, Identifiable {
    case battery = "Battery", devices = "Devices", energy = "Energy"
    var id: String { rawValue }
}

/// Stands in for a panel whose feature has been switched off in settings.
struct DisabledCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        Card {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(Panel.tertiary)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Panel.label)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Panel.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .padding(.horizontal, 14)
        }
    }
}

/// The panel that drops out of the menu bar: current charge at the top, then
/// collapsible cards for health, accessories and what is draining the battery.
struct PopoverView: View {
    let openSettings: () -> Void
    let quit: () -> Void

    @ObservedObject private var battery = BatteryMonitor.shared
    @ObservedObject private var devices = DeviceMonitor.shared
    @ObservedObject private var prefs = Preferences.shared

    @State private var tab: PanelTab = .battery

    /// Measured height of the card column, so the popover is exactly as tall as it
    /// needs to be and grows as sections are expanded.
    @State private var contentHeight: CGFloat = 520

    private let minHeight: CGFloat = 320
    private let maxHeight: CGFloat = 760

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                StatusCard(snapshot: battery.snapshot)

                Segments(options: PanelTab.allCases, title: { $0.rawValue }, selection: $tab)

                switch tab {
                case .battery:
                    HealthCard(snapshot: battery.snapshot)
                    TemperatureCard(snapshot: battery.snapshot)
                    PowerCard(snapshot: battery.snapshot)
                    CapacityCard(snapshot: battery.snapshot)
                case .devices:
                    if prefs.trackDeviceBatteries {
                        DevicesCard(devices: devices.devices)
                    } else {
                        DisabledCard(symbol: "airpods.pro", title: "Accessory tracking is off",
                                     detail: "Turn it on in Settings › Devices.")
                    }
                case .energy:
                    if prefs.trackEnergy {
                        EnergyCard()
                    } else {
                        DisabledCard(symbol: "bolt.slash", title: "Energy tracking is off",
                                     detail: "Turn it on in Settings › General.")
                    }
                }

                ActionsCard(openSettings: openSettings, quit: quit)
            }
            .padding(12)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
                }
            )
        }
        .frame(width: 348)
        .frame(height: min(max(contentHeight, minHeight), maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { height in
            guard height > 0 else { return }
            contentHeight = height
        }
        .background(Panel.background)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Status

struct StatusCard: View {
    let snapshot: BatterySnapshot

    private var tint: Color {
        BatteryTint.swiftUIColor(percentage: snapshot.percentage, charging: snapshot.isCharging)
    }

    private var stateText: String {
        if snapshot.isCharging { return "Charging" }
        if snapshot.isPluggedIn { return snapshot.isFullyCharged ? "Charged" : "Plugged In" }
        return "On Battery"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(snapshot.percentage)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(tint)
                        Text("%")
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(tint.opacity(0.75))

                        if snapshot.isCharging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(tint)
                                .padding(.leading, 3)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 0) {
                        Text(snapshot.isPluggedIn ? "TIME TO FULL" : "TIME LEFT")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Panel.secondary)
                        if let shortTime {
                            Text(shortTime)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Panel.label)
                        } else {
                            Text(snapshot.isFullyCharged && snapshot.isPluggedIn
                                 ? "Full" : "Estimating")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Panel.secondary)
                                .padding(.top, 3)
                        }
                    }
                    .padding(.top, 4)
                }

                HStack(spacing: 8) {
                    BatteryGlyph(level: snapshot.percentage, tint: tint,
                                 outlineTint: true, isCharging: snapshot.isCharging)
                        .frame(width: 26, height: 13)

                    // While charging the state is tinted and sits on a matching chip,
                    // so it reads as a state rather than a caption.
                    Text(stateText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(snapshot.isCharging ? tint : Panel.label)
                        .padding(.horizontal, snapshot.isCharging ? 7 : 0)
                        .padding(.vertical, snapshot.isCharging ? 2 : 0)
                        .background {
                            if snapshot.isCharging {
                                Capsule().fill(tint.opacity(0.16))
                            }
                        }

                    Spacer()

                    Text(String(format: "%@%.1f W", snapshot.watts >= 0 ? "+" : "", snapshot.watts))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(snapshot.isCharging ? tint : Panel.secondary)
                }

                MeterBar(fraction: Double(snapshot.percentage) / 100,
                         tint: tint, segments: 4, height: 8,
                         isCharging: snapshot.isCharging)
            }
            .padding(14)
        }
    }

    /// "2h 10m", or nil while the gauge is still working it out.
    private var shortTime: String? {
        guard let m = snapshot.minutesRemaining, m > 0 else { return nil }
        let h = m / 60, mm = m % 60
        return h > 0 ? "\(h)h \(mm)m" : "\(mm)m"
    }
}

// MARK: - Battery information

/// Health, temperature, power and capacity each get their own panel rather than
/// sitting as divided sub-sections inside one "Battery Information" container.
struct HealthCard: View {
    let snapshot: BatterySnapshot

    /// Apple's own "Maximum Capacity" when macOS has reported it, otherwise the
    /// figure computed from the gauge.
    private var health: Int? {
        snapshot.appleMaxCapacity ?? snapshot.healthPercent.map { Int($0.rounded()) }
    }

    private var grade: (String, Color, String) {
        switch health ?? 100 {
        case 90...: return ("Excellent", Panel.green, "Nothing to do — this battery is in great shape.")
        case 80..<90: return ("Good", Panel.green, "Apple considers a battery healthy down to 80%.")
        case 60..<80: return ("Fair", Panel.amber, "Consider servicing your battery with Apple.")
        default: return ("Poor", Panel.red, "Runtime will be noticeably short. A replacement will help.")
        }
    }

    var body: some View {
        let (label, tint, advice) = grade
        Card {
            SectionHeader(symbol: (health ?? 100) >= 80 ? "checkmark.circle.fill"
                                                        : "exclamationmark.triangle.fill",
                          tint: tint, title: "Battery Health")
                .sectionDivider()

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(health.map { "\($0)%" } ?? "—")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(grouped(snapshot.cycleCount))/1000")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Panel.label)
                        Text("Cycle Count")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Panel.secondary)
                    }
                }

                MeterBar(fraction: Double(health ?? 0) / 100, tint: tint)

                Text(snapshot.condition.map {
                    $0.lowercased() == "normal" ? advice : "macOS reports: \($0)"
                } ?? advice)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Panel.secondary)
            }
            .padding(14)
        }
    }
}

struct TemperatureCard: View {
    let snapshot: BatterySnapshot

    private var grade: (String, Color, String) {
        switch snapshot.temperatureC {
        case ..<35: return ("Normal", Panel.green, "Optimal performance")
        case 35..<40: return ("Warm", Panel.amber, "Still within range")
        default: return ("Hot", Panel.red, "Ease off the load")
        }
    }

    var body: some View {
        let (label, tint, detail) = grade
        Card {
            SectionHeader(symbol: "thermometer.medium", tint: tint, title: "Temperature")
                .sectionDivider()

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "%.1f°C", snapshot.temperatureC))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    Text(String(format: "%.1f°F", snapshot.temperatureC * 9 / 5 + 32))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Panel.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                        Text(label).font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(tint)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Panel.secondary)
                }
                .padding(.top, 3)
            }
            .padding(14)
        }
    }
}

struct PowerCard: View {
    let snapshot: BatterySnapshot

    var body: some View {
        Card {
            SectionHeader(symbol: "bolt.circle.fill", tint: Panel.amber,
                          title: "Power & Electrical")
                .sectionDivider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    StatBlock(label: "Power Usage",
                              value: String(format: "%.1f", abs(snapshot.watts)), unit: "W")
                    StatBlock(label: "Voltage",
                              value: String(format: "%.2f", snapshot.voltage), unit: "V",
                              alignment: .trailing)
                }

                HStack(alignment: .top) {
                    StatBlock(label: "Current",
                              value: "\(abs(Int(snapshot.amperage * 1000)))", unit: "mA")

                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 4) {
                            Image(systemName: snapshot.isCharging ? "arrow.up.circle.fill"
                                                                  : "arrow.down.circle.fill")
                                .font(.system(size: 11))
                            Text(snapshot.isCharging ? "Charging"
                                 : (snapshot.isPluggedIn ? "Holding" : "Discharging"))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(snapshot.isCharging ? Panel.green : Panel.amber)

                        if let watts = snapshot.adapterWatts, snapshot.isPluggedIn {
                            // The negotiated ceiling, not the charger's rating.
                            Text("\(watts)W negotiated")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Panel.secondary)
                        } else {
                            Text("Normal voltage")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Panel.green)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 10)
                }

                Divider().overlay(Panel.hairline).padding(.vertical, 2)

                PowerFlowView(snapshot: snapshot)
            }
            .padding(14)
        }
    }
}

struct CapacityCard: View {
    let snapshot: BatterySnapshot

    var body: some View {
        Card {
            SectionHeader(symbol: "battery.100percent", tint: Panel.blue,
                          title: "Capacity Details")
                .sectionDivider()

            VStack(alignment: .leading, spacing: 6) {
                ValueRow(label: "Remaining", value: grouped(snapshot.rawCurrentCapacity),
                         unit: "mAh", tint: Panel.green)
                ValueRow(label: "Current Full", value: grouped(snapshot.rawMaxCapacity),
                         unit: "mAh", tint: Panel.blue)
                ValueRow(label: "Design Capacity", value: grouped(snapshot.designCapacity),
                         unit: "mAh", tint: Panel.secondary)
            }
            .padding(14)
        }
    }
}


// MARK: - Accessories

struct DevicesCard: View {
    let devices: [DeviceBattery]

    var body: some View {
        Card {
            SectionHeader(symbol: "airpods.pro", tint: Panel.green,
                          title: "Other Devices")
                .sectionDivider()

            if devices.isEmpty {
                Text("Nothing reporting a battery yet. Connect AirPods, a Magic Mouse or a keyboard.")
                    .font(.system(size: 11))
                    .foregroundStyle(Panel.secondary)
                    .padding(14)
            } else {
                VStack(spacing: 10) {
                    ForEach(devices) { DeviceRow(device: $0) }
                }
                .padding(14)
            }
        }
    }
}

// MARK: - Energy

struct EnergyCard: View {
    @ObservedObject private var monitor = EnergyMonitor.shared
    @State private var window: EnergyWindow = .live

    var body: some View {
        Card {
            SectionHeader(symbol: "bolt.fill", tint: Panel.amber,
                          title: "Energy Use")
                .sectionDivider()

            VStack(alignment: .leading, spacing: 10) {
                Segments(options: EnergyWindow.allCases,
                         title: { $0.rawValue },
                         selection: $window)

                if !monitor.callouts.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Panel.amber)
                        Text("\(monitor.callouts.joined(separator: ", ")) — far above its usual draw.")
                            .font(.system(size: 10))
                            .foregroundStyle(Panel.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Panel.amber.opacity(0.12)))
                }

                let entries = monitor.ranked(window)
                if entries.isEmpty {
                    Text(window == .live ? "Sampling…"
                         : "No history for this window yet — Volt fills it in as it runs.")
                        .font(.system(size: 11))
                        .foregroundStyle(Panel.secondary)
                } else {
                    let peak = entries.map(\.impact).max() ?? 1
                    ForEach(entries) { entry in
                        EnergyRow(entry: entry, peak: peak,
                                  series: monitor.series(for: entry.name, window: window))
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Actions

struct ActionsCard: View {
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        Card {
            ActionRow(symbol: "gearshape.fill", tint: Panel.secondary,
                      title: "Settings…", action: openSettings)
                .sectionDivider()
            ActionRow(symbol: "power", tint: Panel.red, title: "Quit Volt",
                      trailing: version, action: quit)
        }
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v" + (v ?? "1.0")
    }
}

struct ActionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var trailing: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Panel.label)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Panel.tertiary)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Panel.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isHovering ? Color.white.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: action)
    }
}
