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
    let cells: [Cell]
    let isCharging: Bool
    /// False for a paired device that is not currently connected: the levels are the
    /// last ones macOS saw, so they are shown dimmed and never trigger alerts.
    let isConnected: Bool
    /// Shown in place of a level when macOS exposes no battery for this device.
    var note: String?

    /// The cell most at risk — what alerts and the sort order key off.
    var lowestPercent: Int { cells.map(\.percent).min() ?? 100 }

    /// True when there is an actual reading, rather than just a known pairing.
    var hasReading: Bool { !cells.isEmpty }
}
