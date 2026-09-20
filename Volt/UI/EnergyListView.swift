import SwiftUI

/// What is actually draining the battery, live or averaged over a window.
struct EnergyListView: View {
    let enabled: Bool

    @ObservedObject private var monitor = EnergyMonitor.shared
    @State private var window: EnergyWindow = .live

    var body: some View {
        if !enabled {
            VStack(spacing: 6) {
                Image(systemName: "bolt.slash").font(.system(size: 22)).foregroundStyle(.tertiary)
                Text("Energy tracking is off").font(.system(size: 12, weight: .medium))
                Text("Turn it on in Settings › Energy.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $window) {
                    ForEach(EnergyWindow.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if !monitor.callouts.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text("\(monitor.callouts.joined(separator: ", ")) — using far more than usual right now.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
                }

                let entries = monitor.ranked(window)
                if entries.isEmpty {
                    Text(window == .live
                         ? "Sampling…"
                         : "No history for this window yet — Volt needs to run a while to fill it in.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                } else {
                    let peak = entries.map(\.impact).max() ?? 1
                    ForEach(entries) { entry in
                        EnergyRow(entry: entry, peak: peak,
                                  series: monitor.series(for: entry.name, window: window))
                    }
                }
            }
        }
    }
}

struct EnergyRow: View {
    let entry: EnergyEntry
    let peak: Double
    let series: [Double]

    var body: some View {
        HStack(spacing: 9) {
            if let icon = entry.icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 20, height: 20)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(tint)
                            .frame(width: max(3, geo.size.width * CGFloat(entry.impact / max(peak, 1))))
                    }
                }
                .frame(height: 5)
            }

            if series.contains(where: { $0 > 0 }) {
                Sparkline(values: series, tint: tint)
                    .frame(width: 50, height: 18)
            }

            Text(String(format: "%.0f", entry.impact))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private var tint: Color {
        switch entry.impact {
        case ..<20: return .green
        case ..<60: return .orange
        default: return .red
        }
    }
}

/// A flat line chart with no axes — just the shape of the last N buckets.
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let maxValue = max(values.max() ?? 1, 1)
            Path { path in
                guard values.count > 1 else { return }
                let step = geo.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step,
                                        y: geo.size.height * (1 - CGFloat(value / maxValue)))
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }
}
