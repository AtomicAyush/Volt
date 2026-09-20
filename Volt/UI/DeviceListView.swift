import SwiftUI

/// Every other battery in reach, lowest first.
struct DeviceListView: View {
    let devices: [DeviceBattery]
    let enabled: Bool

    var body: some View {
        if !enabled {
            empty("Accessory tracking is off", "Turn it on in Settings › Devices.")
        } else if devices.isEmpty {
            empty("No accessory batteries yet",
                  "Connect AirPods, a Magic Mouse or a keyboard and they will show up here.")
        } else {
            VStack(spacing: 10) {
                ForEach(devices) { DeviceRow(device: $0) }
            }
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

struct DeviceRow: View {
    let device: DeviceBattery

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: device.kind.symbol)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundStyle(device.isConnected ? .primary : .tertiary)

                Text(device.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(device.isConnected ? .primary : .secondary)

                // Only meaningful where a level exists and has gone stale.
                if !device.isConnected && device.hasReading {
                    Text("last seen")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }

                Spacer()
            }

            if let note = device.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Panel.tertiary)
                    .padding(.leading, 26)
            }

            ForEach(device.cells) { cell in
                HStack(spacing: 8) {
                    if !cell.label.isEmpty {
                        Text(cell.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .leading)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule().fill(tint(cell.percent).opacity(device.isConnected ? 1 : 0.4))
                                .frame(width: max(3, geo.size.width * CGFloat(cell.percent) / 100))
                        }
                    }
                    .frame(height: 6)

                    Text("\(cell.percent)%")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(device.isConnected ? .primary : .secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.leading, cell.label.isEmpty ? 26 : 26)
            }
        }
        .padding(.vertical, 4)
    }

    private func tint(_ percent: Int) -> Color {
        switch percent {
        case ..<16: return .red
        case ..<31: return .orange
        default: return .green
        }
    }
}
