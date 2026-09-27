import Foundation

/// Battery decoded from one of Apple's Continuity advertisements.
struct ContinuityReading: Equatable {
    /// One battery the broadcast reports on.
    struct Part: Equatable {
        let percent: Int
        /// False when only the tens digit could be read, so the level is rounded down
        /// to ten.
        let isExact: Bool
        let isCharging: Bool
    }

    let model: UInt16
    let left: Part?
    let right: Part?
    let casing: Part?
    /// The level of a device with a single battery, such as AirPods Max, from the
    /// accessory-status message. A proximity-pairing message from a single-battery
    /// device reports in `left` or `right` instead.
    let main: Part?
    let rssi: Int
    let seen: Date

    /// True when any part of the device is taking charge.
    var isCharging: Bool { [left, right, casing, main].contains { $0?.isCharging == true } }
}

/// Decodes the battery broadcasts AirPods and Beats send in Apple's manufacturer data.
///
/// Apple does not document these, so every layout here was checked against the Mac's
/// own decode of the same bytes: audioaccessoryd logs each advertisement it receives
/// next to the levels it reads from it. 415 distinct payloads from this Mac's AirPods
/// Pro 2 and AirPods Max decode here exactly as macOS decodes them.
///
/// Two message types carry a battery:
///
/// - **Proximity pairing** (0x07, length 0x19), from AirPods. Levels come twice: as
///   tens digits in the clear, and as exact percentages further on. The exact bytes are
///   encrypted with a key from pairing, and arrive readable only from this Mac's own
///   AirPods. They are used only when they agree with the tens digits and the readable
///   part carries its signature: three bytes that are either zero or the end of a
///   paired device's address (282 of 282 of this Mac's AirPods' broadcasts).
/// - **Accessory status** (0x07, length 0x11, subtype 0x06), from AirPods Max and from
///   AirPods cases. Exact percentages only.
///
/// The catch is attribution: the address is randomised, so nothing in the broadcast
/// names the device. What does tell them apart is the encryption. This Mac's own
/// AirPods arrive readable — in a live capture, 26 of 26 of their broadcasts decoded
/// exactly, and 0 of 86 from other people's AirPods of the same model did — and a
/// neighbour's accessory-status message arrives scrambled, model number included. So a
/// reading is only used when it decoded exactly, for a model paired to this Mac; see
/// `BLEBatteryMonitor.captureAdvertisement`.
enum ContinuityDecoder {
    private static let apple: (UInt8, UInt8) = (0x4C, 0x00)
    private static let nearbyAccessory: UInt8 = 0x07

    /// `pairedAddressTails` holds the last three bytes of each paired device's address.
    static func decode(manufacturerData data: Data, rssi: Int, now: Date = Date(),
                       pairedAddressTails: Set<UInt32> = []) -> ContinuityReading? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == apple.0, bytes[1] == apple.1 else { return nil }

        // After the company ID the data is a run of type–length–value records. An
        // AirPods case puts another record ahead of its battery one, so walk them all.
        var offset = 2
        while offset + 2 <= bytes.count {
            let type = bytes[offset]
            let length = Int(bytes[offset + 1])
            let body = Array(bytes[(offset + 2)..<min(offset + 2 + length, bytes.count)])
            if type == nearbyAccessory {
                return decodeRecord(body, length: length, rssi: rssi, now: now,
                                    pairedAddressTails: pairedAddressTails)
            }
            offset += 2 + length
        }
        return nil
    }

    /// `body` starts just after the type and length bytes.
    private static func decodeRecord(_ body: [UInt8], length: Int, rssi: Int, now: Date,
                                     pairedAddressTails: Set<UInt32>) -> ContinuityReading? {
        guard body.count >= 4 else { return nil }
        let model = UInt16(body[1]) | (UInt16(body[2]) << 8)

        switch (length, body[0]) {
        case (0x19, 0x01): return proximityPairing(body, model: model, rssi: rssi, now: now,
                                                   pairedAddressTails: pairedAddressTails)
        case (0x11, 0x06): return accessoryStatus(body, model: model, rssi: rssi, now: now)
        default: return nil
        }
    }

    // MARK: - Proximity pairing

    /// prefix | model (LE) | status | pods | flags+case | lid | colour | ? | ? |
    /// sender pod | other pod | case | last host (3) | bud in case (3) | …
    private static func proximityPairing(_ b: [UInt8], model: UInt16, rssi: Int, now: Date,
                                         pairedAddressTails: Set<UInt32>) -> ContinuityReading? {
        guard b.count >= 6 else { return nil }
        let status = b[3], pods = b[4], box = b[5]

        // The pod sending this broadcast reports in the low nibble and the other in the
        // high one. Status bit 0x20 says whether the sender is the left pod.
        let senderIsLeft = status & 0x20 != 0
        let senderNibble = pods & 0x0F
        let otherNibble = pods >> 4
        let caseNibble = box & 0x0F

        // The high nibble of the case byte flags which parts are charging, relative to
        // the sender. All four bits set is how the format says "unknown".
        let flags = box >> 4
        let flagsKnown = flags != 0x0F
        let senderCharging = flagsKnown && flags & 0x01 != 0
        let otherCharging = flagsKnown && flags & 0x02 != 0
        let caseCharging = flagsKnown && flags & 0x04 != 0

        let exact: [UInt8]? = b.count >= 19 ? [b[10], b[11], b[12]] : nil
        let nibbles = [senderNibble, otherNibble, caseNibble]
        let charging = [senderCharging, otherCharging, caseCharging]
        // macOS calls these three bytes the bud in the case with this one: zero, or the
        // end of the pair's own address. Scrambled bytes almost never are either.
        let signed = b.count >= 19 && {
            let tail = UInt32(b[16]) << 16 | UInt32(b[17]) << 8 | UInt32(b[18])
            return tail == 0 || pairedAddressTails.contains(tail)
        }()
        let useExact = signed
            && exact.map { agrees($0, nibbles: nibbles, charging: flagsKnown ? charging : nil) } ?? false

        var parts: [ContinuityReading.Part?] = []
        for i in 0..<3 {
            guard nibbles[i] <= 10 else { parts.append(nil); continue }
            if useExact, let byte = exact?[i] {
                parts.append(.init(percent: Int(byte & 0x7F), isExact: true, isCharging: byte & 0x80 != 0))
            } else {
                parts.append(.init(percent: Int(nibbles[i]) * 10, isExact: false, isCharging: charging[i]))
            }
        }
        let sender = parts[0], other = parts[1]

        return ContinuityReading(model: model,
                                 left: senderIsLeft ? sender : other,
                                 right: senderIsLeft ? other : sender,
                                 casing: parts[2],
                                 main: nil,
                                 rssi: rssi,
                                 seen: now)
    }

    /// True when the exact bytes say the same thing as the tens digits: each part is
    /// absent in both or in the same ten in both, and charging matches wherever the flags
    /// are known. Encrypted bytes fail this almost always, and are then ignored.
    private static func agrees(_ exact: [UInt8], nibbles: [UInt8], charging: [Bool]?) -> Bool {
        for i in 0..<3 {
            let byte = exact[i]
            if nibbles[i] > 10 {
                guard byte == 0xFF else { return false }
                continue
            }
            let percent = Int(byte & 0x7F)
            guard byte != 0xFF, percent <= 100, min(percent / 10, 10) == Int(nibbles[i]) else { return false }
            if let charging, charging[i] != (byte & 0x80 != 0) { return false }
        }
        return true
    }

    // MARK: - Accessory status

    /// subtype | model (LE) | status | main | left | right | … | 00 00 00 | …
    ///
    /// For AirPods Max the main byte is the headphones' own level; for a case it is the
    /// case, and left and right are the pods inside it. 0xFF means not reported; the top
    /// bit marks charging.
    private static func accessoryStatus(_ b: [UInt8], model: UInt16, rssi: Int, now: Date) -> ContinuityReading? {
        // Readable messages carry three zero bytes at 10–12: every one of 2,344 that
        // macOS decoded here did, charging or not. Scrambled ones from other people's
        // devices — whose model number is scrambled too — almost never do, which is the
        // only way to tell them apart, as there are no tens digits here to check against.
        guard b.count >= 13, b[10] == 0, b[11] == 0, b[12] == 0 else { return nil }
        let fields = [b[4], b[5], b[6]]

        // No tens digits to check against here, so at least refuse what cannot be a level.
        guard fields.allSatisfy({ $0 == 0xFF || $0 & 0x7F <= 100 }) else { return nil }
        let parts = fields.map { byte -> ContinuityReading.Part? in
            byte == 0xFF ? nil : .init(percent: Int(byte & 0x7F), isExact: true, isCharging: byte & 0x80 != 0)
        }
        guard parts.contains(where: { $0 != nil }) else { return nil }

        return ContinuityReading(model: model,
                                 left: parts[1],
                                 right: parts[2],
                                 casing: parts[0],
                                 main: parts[0],
                                 rssi: rssi,
                                 seen: now)
    }
}
