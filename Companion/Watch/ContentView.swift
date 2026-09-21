import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var reporter: BatteryReporter

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: reporter.isCharging ? "battery.100percent.bolt" : "battery.75percent")
                    .font(.system(size: 26))
                    .foregroundStyle(.green)

                Text(reporter.percent.map { "\($0)%" } ?? "—")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Group {
                    if let sent = reporter.lastSent {
                        Text("Sent to iPhone \(sent, style: .relative) ago")
                    } else {
                        Text("Not sent yet")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                if let error = reporter.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                Button("Send now") {
                    Task { await reporter.report() }
                }
                .padding(.top, 4)

                Text("Volt on your Mac shows this watch's battery through your iPhone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 4)
        }
    }
}
