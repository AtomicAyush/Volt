import Foundation

/// A battery that belongs to something other than this Mac.
struct DeviceBattery: Identifiable, Equatable {
    enum Kind: String {
        case mac, headphones, earbuds, mouse, keyboard, trackpad, phone, tablet, watch, speaker, other

        var symbol: String {
            switch self {
            case .mac: return "laptopcomputer"
            case .headphones: return "headphones"
            case .earbuds: return "airpods.pro"
            case .mouse: return "magicmouse"
            case .keyboard: return "keyboard"
            case .trackpad: return "rectangle.and.hand.point.up.left"
            case .phone: return "iphone"
            case .tablet: return "ipad"
            case .watch: return "applewatch"
            case .speaker: return "hifispeaker"
            case .other: return "dot.radiowaves.left.and.right"
            }
        }

        static func from(minorType: String?, name: String) -> Kind {
            let n = name.lowercased()
            if n.contains("airpods pro") || n.contains("airpods") && !n.contains("max") { return .earbuds }
            if n.contains("airpods max") { return .headphones }
            if n.contains("trackpad") { return .trackpad }
            if n.contains("iphone") { return .phone }
            if n.contains("ipad") { return .tablet }
            if n.contains("watch") { return .watch }
            switch (minorType ?? "").lowercased() {
            case "headphones", "headset": return n.contains("speaker") ? .speaker : .headphones
            case "mouse": return .mouse
            case "keyboard": return .keyboard
            case "speaker": return .speaker
            default: return .other
            }
        }
    }

    /// A single cell of a device — AirPods report left, right and case separately.
    struct Cell: Identifiable, Equatable {
        var id: String { label }
        let label: String     // "", "L", "R", "Case"
        let percent: Int
    }

    let id: String            // bluetooth address, or a stable synthetic key
    let name: String
    let kind: Kind
    var cells: [Cell]
    var isCharging: Bool
    /// True when the level is live: from macOS for a connected device, from IOBluetooth,
    /// or from the device's own broadcast. False for a level Volt remembered, or one the
    /// report still lists for a device that is off with nothing broadcasting; either is
    /// shown dimmed and never triggers alerts.
    var isConnected: Bool
    /// Shown in place of a level when macOS exposes no battery for this device.
    var note: String?
    /// Apple model number from the Bluetooth report, used to match this device against
    /// the Continuity advertisements it broadcasts.
    var model: UInt16?
    /// Connected over Bluetooth LE alone, with no audio or input profile — the kind of
    /// link System Settings does not list and that says nothing about the device being
    /// in use.
    var isBareLELink: Bool = false
    /// The level came from Volt's own memory of an earlier reading, not from anything
    /// the device is reporting now.
    var isRemembered: Bool = false
    /// From the Bluetooth report; the same serial a device reports over USB, which is how
    /// something charging from one of the Mac's ports is named.
    var serialNumber: String?

    /// The cell most at risk — what alerts and the sort order key off.
    var lowestPercent: Int { cells.map(\.percent).min() ?? 100 }

    /// True when there is an actual reading, rather than just a known pairing.
    var hasReading: Bool { !cells.isEmpty }
}
