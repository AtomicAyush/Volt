import Foundation

/// Battery decoded from one of Apple's Continuity advertisements.
struct ContinuityReading: Equatable {
    let model: UInt16
    /// 0–100 in steps of ten, or nil when the field reads as unknown.
    let primary: Int?
    let secondary: Int?
    let caseLevel: Int?
    /// The low nibble of the case byte carries charging flags, one bit per part.
    let primaryCharging: Bool
    let secondaryCharging: Bool
    let caseCharging: Bool

    /// True when any part of the device is taking charge.
    var isCharging: Bool { primaryCharging || secondaryCharging || caseCharging }
    let rssi: Int
    let seen: Date
}

/// Decodes the "proximity pairing" advertisement AirPods broadcast.
///
/// Apple does not document this, so the layout here was written against captured
/// bytes and checked against levels macOS reports for the same device: a pair whose
/// real levels were 91% / 91% / 78% decoded as 90% / 90% / 80%, which is the format's
/// resolution — every level is a nibble counting tens.
///
/// The catch is attribution. The advertisement carries a model number but no stable
/// identifier: the address is randomised and the rest of the payload is encrypted, so
/// a neighbour's AirPods of the same model look identical to yours. Readings are
/// therefore only accepted for models actually paired to this Mac, and only from the
/// closest broadcaster of that model.
enum ContinuityDecoder {
    /// 0x004C, little-endian, then message type 0x07.
    private static let appleCompany: [UInt8] = [0x4C, 0x00]
    private static let proximityPairing: UInt8 = 0x07

    static func decode(manufacturerData data: Data, rssi: Int) -> ContinuityReading? {
        // 4c00 | type | length | prefix | model (LE) | status | pods | case
        guard data.count >= 10,
              data[0] == appleCompany[0], data[1] == appleCompany[1],
              data[2] == proximityPairing else { return nil }

        let bytes = [UInt8](data)
        let model = UInt16(bytes[5]) | (UInt16(bytes[6]) << 8)
        let pods = bytes[8]
        let casing = bytes[9]

        // Every bit set is how this format says "unknown" for the level nibbles, and the
        // flag nibble reads 0xF on devices that are plainly not all charging at once, so
        // it is taken the same way here: no information rather than three bolts.
        let flags = casing & 0x0F
        let flagsKnown = flags != 0x0F
        return ContinuityReading(model: model,
                                 primary: level(pods >> 4),
                                 secondary: level(pods & 0x0F),
                                 caseLevel: level(casing >> 4),
                                 primaryCharging: flagsKnown && flags & 0x02 != 0,
                                 secondaryCharging: flagsKnown && flags & 0x01 != 0,
                                 caseCharging: flagsKnown && flags & 0x04 != 0,
                                 rssi: rssi,
                                 seen: Date())
    }

    /// A nibble counts tens; 15 means the device did not report.
    private static func level(_ nibble: UInt8) -> Int? {
        guard nibble <= 10 else { return nil }
        return Int(nibble) * 10
    }
}
