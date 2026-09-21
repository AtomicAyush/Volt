import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @EnvironmentObject private var link: WatchLink
    @EnvironmentObject private var peripheral: BatteryPeripheral

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "applewatch")
                            .font(.system(size: 34))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.latest.map { "\($0.percent)%" } ?? "—")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            if let latest = link.latest {
                                Text("Reported \(latest.reportedAt, style: .relative) ago")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else {
                                Text("Open Volt on your watch to send its battery")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Apple Watch")
                }

                Section {
                    row("Watch paired", link.isPaired)
                    row("Watch app installed", link.isAppInstalled)
                    row("Sharing with your Mac", peripheral.isPublishing)
                    HStack {
                        Text("Mac listening")
                        Spacer()
                        Text(peripheral.subscribers > 0 ? "Yes" : "Not yet")
                            .foregroundStyle(peripheral.subscribers > 0 ? .green : .secondary)
                    }
                } header: {
                    Text("Status")
                } footer: {
                    Text("Volt on your Mac reads your watch's battery from this app over Bluetooth. Leave it installed, and avoid force-quitting it from the app switcher — iOS keeps it available in the background otherwise.")
                }
            }
            .navigationTitle("Volt")
        }
    }

    private func row(_ title: String, _ ok: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
        }
    }
}
