import Foundation
import CoreBluetooth

/// The Bluetooth service and value Volt on the Mac looks for. The layout is shared with
/// the Mac by agreement, so it is kept deliberately small and fixed:
///
///   byte 0     percent, 0–100
///   byte 1     flags — bit 0 charging, bit 1 full
///   bytes 2–5  when the watch took the reading, Unix seconds, little-endian
enum WatchBatteryPayload {
    static let service = CBUUID(string: "6B1F0001-3C2A-4E7B-9D51-7A2E5C0B9F10")
    static let characteristic = CBUUID(string: "6B1F0002-3C2A-4E7B-9D51-7A2E5C0B9F10")

    static func encode(percent: Int, charging: Bool, full: Bool, reportedAt: Date) -> Data {
        var data = Data()
        data.append(UInt8(max(0, min(100, percent))))
        data.append((charging ? 0x01 : 0) | (full ? 0x02 : 0))
        var seconds = UInt32(max(0, reportedAt.timeIntervalSince1970)).littleEndian
        withUnsafeBytes(of: &seconds) { data.append(contentsOf: $0) }
        return data
    }
}
