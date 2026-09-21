// VoltHelper — the privileged half of Volt's Low Power Mode switch.
//
// Changing Low Power Mode is `pmset powermode`, which only root may run. This helper
// runs as root so the switch can flip without an administrator prompt each time. Because
// it is root, it is kept as small and as closed as it can be:
//
//  • It does exactly one thing: set powermode to 0 or 1. It never runs a command it was
//    handed, so a caller cannot turn it into a general-purpose root shell.
//  • It only accepts connections from Volt itself, signed by the same team as the helper.
//    If the helper cannot establish its own team — an ad-hoc build, say — it accepts
//    nobody at all rather than guess.
//  • It is not resident. launchd starts it on demand when Volt connects, and it exits
//    once it has been idle for a few seconds.

import Foundation
import Security

@objc(VoltHelperProtocol)
protocol VoltHelperProtocol {
    func setLowPowerMode(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void)
    func version(reply: @escaping (String) -> Void)
}

let helperVersion = "1"
let appIdentifier = "com.ayush.Volt"
let idleTimeout: TimeInterval = 20

/// The Team ID this binary is signed with, read from its own signature.
func ownTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
          let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode,
                                        SecCSFlags(rawValue: kSecCSSigningInformation),
                                        &info) == errSecSuccess,
          let dictionary = info as? [String: Any] else { return nil }
    return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
}

/// Exits once nothing has asked for anything for a while. launchd relaunches the
/// helper the next time Volt connects to its Mach service.
final class IdleExit {
    private var timer: Timer?
    func touch() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { _ in
            exit(0)
        }
    }
}
let idle = IdleExit()

final class Helper: NSObject, VoltHelperProtocol {
    func setLowPowerMode(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.main.async { idle.touch() }

        // A fixed program and fixed arguments: the only input is a Bool.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "powermode", enabled ? "1" : "0"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            reply(false, error.localizedDescription)
            return
        }

        if process.terminationStatus == 0 {
            reply(true, nil)
        } else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            reply(false, message?.isEmpty == false ? message
                  : "pmset exited with status \(process.terminationStatus)")
        }
    }

    func version(reply: @escaping (String) -> Void) {
        DispatchQueue.main.async { idle.touch() }
        reply(helperVersion)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: VoltHelperProtocol.self)
        connection.exportedObject = Helper()
        connection.resume()
        idle.touch()
        return true
    }
}

let listener = NSXPCListener(machServiceName: "com.ayush.Volt.helper")

// Fail closed: with no team to check against, nobody gets in.
guard let team = ownTeamIdentifier() else {
    NSLog("VoltHelper: not signed with a team identity; refusing to serve")
    exit(1)
}
listener.setConnectionCodeSigningRequirement(
    "identifier \"\(appIdentifier)\" and anchor apple generic "
    + "and certificate leaf[subject.OU] = \"\(team)\""
)

let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
idle.touch()
RunLoop.main.run()
