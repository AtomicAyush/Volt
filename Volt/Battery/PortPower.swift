import Foundation
import IOKit

/// Power going out of one of this Mac's ports, to something charging from it.
struct PortOutput: Equatable, Identifiable {
    var id: Int { port }
    let port: Int
    let watts: Double
    /// What is plugged in, as best it can be named.
    let name: String
    let symbol: String
    /// The device's USB serial number, which matches its Bluetooth one.
    var serial: String? = nil
}

/// Reads what the Mac's own USB-C ports are supplying.
///
/// The SMC reports each port's output as `D<n>JV` (volts) and `D<n>JI` (amps), with its
/// USB Power Delivery power role in `D<n>PR` — 1 when the port is the source. Checked on
/// a 14" MacBook Pro while AirPods Max charged from port 3: 5.22 V × 0.57 A, about 3 W,
/// refreshed every second, with role 1; the port the charger was on read 0 V, 0 A and
/// role 0, and the empty ports read 0.
enum PortPower {
    /// Below this a port is idling rather than supplying anything.
    private static let threshold = 0.1

    /// The ports the SMC knows about, found once: `D1`, `D2`, … until one is missing.
    private static let ports: [Int] = {
        (1...8).prefix { SMC.shared.float("D\($0)JV") != nil }
    }()

    /// Watts going out of each port that is supplying power right now.
    static func outputs() -> [(port: Int, watts: Double)] {
        ports.compactMap { port in
            guard SMC.shared.uint8("D\(port)PR") == 1,
                  let volts = SMC.shared.float("D\(port)JV"),
                  let amps = SMC.shared.float("D\(port)JI") else { return nil }
            let watts = volts * amps
            return watts > threshold ? (port, watts) : nil
        }
    }

    /// What is plugged into a port, as the USB-C port controller and the USB bus see it.
    struct Identity: Equatable {
        let vendor: Int
        let product: Int
        let usbName: String?
        let serial: String?
    }

    /// The port's own USB transport names whatever enumerated on it. A device that only
    /// negotiated power has no USB transport, and is known by the vendor and product IDs
    /// it gave during power negotiation instead.
    static func identify(port: Int) -> Identity? {
        for transport in ["IOPortTransportStateUSB3", "IOPortTransportStateUSB2"] {
            guard let usb = transportProperties(transport, port: port),
                  usb["Active"] as? Bool == true,
                  let name = usb["Product"] as? String else { continue }
            return Identity(vendor: usb["Vendor ID"] as? Int ?? 0,
                            product: usb["Product ID"] as? Int ?? 0,
                            usbName: name, serial: usb["Serial Number"] as? String)
        }
        guard let metadata = transportProperties("IOPortTransportStateCC", port: port)?["Metadata"]
                as? [String: Any],
              let vendor = metadata["Vendor ID (SOP)"] as? Int else { return nil }
        return Identity(vendor: vendor, product: metadata["Product ID (SOP)"] as? Int ?? 0,
                        usbName: nil, serial: nil)
    }

    /// A transport's properties on the given USB-C port. MagSafe numbers its port from 1
    /// too, so the port type is checked as well as the number.
    private static func transportProperties(_ className: String, port: Int) -> [String: Any]? {
        var found: [String: Any]?
        forEach(serviceMatching: className) { props in
            guard found == nil,
                  props["ParentPortNumber"] as? Int == port,
                  props["ParentPortTypeDescription"] as? String == "USB-C" else { return }
            found = props
        }
        return found
    }

    private static func forEach(serviceMatching name: String, _ body: ([String: Any]) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
                    == KERN_SUCCESS,
                  let props = unmanaged?.takeRetainedValue() as? [String: Any] else { continue }
            body(props)
        }
    }
}
