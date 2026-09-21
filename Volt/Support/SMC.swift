import Foundation
import IOKit

/// Reads Apple's System Management Controller.
///
/// The IO registry's battery entry republishes on its own schedule — sometimes eight
/// seconds or more apart — so current and voltage taken from there visibly lag and
/// often repeat. The SMC carries the same measurements and refreshes about once a
/// second, which is what makes a live power readout look live.
///
/// This is not a documented interface. The layout below was checked against the
/// hardware: `#KEY` reports the key count, `B0AV` reads 11997 against a 12.0 V pack,
/// and `B0AC` tracks the discharge current the gauge reports more slowly.
final class SMC {
    static let shared = SMC()

    // MARK: - Wire format

    private struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    }

    private struct KeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        /// Swift drops a nested struct's trailing padding where C keeps it. Without
        /// this the whole message is 76 bytes instead of 80 and the kernel rejects
        /// every call with a bad-argument error.
        var pad: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }

    private struct KeyData {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfoData()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
    }

    private enum Selector {
        static let handleEvent: UInt32 = 2
    }

    private enum Command {
        static let readKey: UInt8 = 5
        static let keyInfo: UInt8 = 9
    }

    // MARK: - Connection

    private var connection: io_connect_t = 0
    private(set) var isAvailable = false
    /// Key sizes and types never change, so they are looked up once.
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]

    private init() { open() }
    deinit { close() }

    private func open() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }
        isAvailable = IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
    }

    private func close() {
        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
    }

    // MARK: - Reading

    private func call(_ input: inout KeyData, _ output: inout KeyData) -> Bool {
        var outSize = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, Selector.handleEvent,
                                               &input, MemoryLayout<KeyData>.stride,
                                               &output, &outSize)
        return result == kIOReturnSuccess && output.result == 0
    }

    private static func fourCC(_ key: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in key.utf8.prefix(4) { value = (value << 8) | UInt32(byte) }
        return value
    }

    private func raw(_ key: String) -> (type: UInt32, bytes: [UInt8])? {
        guard isAvailable else { return nil }
        let code = Self.fourCC(key)

        var info = infoCache[code]
        if info == nil {
            var input = KeyData(), output = KeyData()
            input.key = code
            input.data8 = Command.keyInfo
            guard call(&input, &output) else { return nil }
            info = (output.keyInfo.dataSize, output.keyInfo.dataType)
            infoCache[code] = info
        }
        guard let info, info.size > 0 else { return nil }

        var input = KeyData(), output = KeyData()
        input.key = code
        input.keyInfo.dataSize = info.size
        input.data8 = Command.readKey
        guard call(&input, &output) else { return nil }

        let all = withUnsafeBytes(of: output.bytes) { Array($0) }
        return (info.type, Array(all.prefix(Int(info.size))))
    }

    /// A float key such as PPBR, PDTR or PSTR, in watts.
    func float(_ key: String) -> Double? {
        guard let (type, bytes) = raw(key), bytes.count >= 4,
              type == Self.fourCC("flt ") else { return nil }
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let value = Float(bitPattern: bits)
        guard value.isFinite else { return nil }
        return Double(value)
    }

    /// A signed 16-bit key such as B0AC, in whatever unit the key uses. These arrive
    /// little-endian: B0AV reads 11997 that way against a 12 V pack, and 56622 if the
    /// bytes are taken the other way round.
    func int16(_ key: String) -> Int? {
        guard let (_, bytes) = raw(key), bytes.count >= 2 else { return nil }
        return Int(Int16(bitPattern: UInt16(bytes[1]) << 8 | UInt16(bytes[0])))
    }

    func uint16(_ key: String) -> Int? {
        guard let (_, bytes) = raw(key), bytes.count >= 2 else { return nil }
        return Int(UInt16(bytes[1]) << 8 | UInt16(bytes[0]))
    }
}
