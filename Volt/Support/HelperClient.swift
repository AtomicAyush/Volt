import Foundation
import ServiceManagement
import Security

/// Must match the helper's protocol exactly, down to the Objective-C name.
@objc(VoltHelperProtocol)
protocol VoltHelperProtocol {
    func setLowPowerMode(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void)
    func version(reply: @escaping (String) -> Void)
}

/// Installs and talks to VoltHelper, the root daemon that lets the Low Power Mode
/// switch work without an administrator prompt each time.
///
/// The daemon is registered with `SMAppService`, so macOS asks the user to approve it
/// once under Login Items; until they do, the switch falls back to the prompt. The
/// connection is checked in both directions — the helper only accepts Volt, and Volt
/// only trusts a helper signed by the same team as itself.
final class HelperClient: ObservableObject {
    static let shared = HelperClient()
    static let machService = "com.ayush.Volt.helper"

    private let service = SMAppService.daemon(plistName: "com.ayush.Volt.helper.plist")

    @Published private(set) var status: SMAppService.Status = .notRegistered

    enum HelperError: LocalizedError {
        case failed(String?)
        case unsigned
        var errorDescription: String? {
            switch self {
            case .failed(let message): return message ?? "The helper could not change Low Power Mode."
            case .unsigned: return "This build is not signed with a team identity, so the helper cannot be used."
            }
        }
    }

    private init() { refreshStatus() }

    func refreshStatus() {
        status = service.status
    }

    var isReady: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    /// Registers the daemon. macOS then lists it under Login Items for approval.
    func install() throws {
        try service.register()
        refreshStatus()
    }

    func uninstall() {
        service.unregister { [weak self] _ in
            DispatchQueue.main.async { self?.refreshStatus() }
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Talking to it

    func setLowPowerMode(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let team = Self.ownTeamIdentifier() else {
            completion(.failure(HelperError.unsigned))
            return
        }

        let connection = NSXPCConnection(machServiceName: Self.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: VoltHelperProtocol.self)
        // Only trust a helper signed by the same team as this app. Without this, anything
        // registered under the same Mach name would be believed.
        connection.setCodeSigningRequirement(
            "identifier \"com.ayush.Volt.helper\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(team)\""
        )
        connection.resume()

        var finished = false
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(result)
                connection.invalidate()
            }
        }

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            finish(.failure(error))
        } as? VoltHelperProtocol

        proxy?.setLowPowerMode(enabled) { ok, message in
            finish(ok ? .success(()) : .failure(HelperError.failed(message)))
        }
    }

    /// Asks the helper for its version and nothing else. Used to confirm it is installed
    /// and answering without touching Low Power Mode.
    func ping(completion: @escaping (String?) -> Void) {
        guard let team = Self.ownTeamIdentifier() else { completion(nil); return }
        let connection = NSXPCConnection(machServiceName: Self.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: VoltHelperProtocol.self)
        connection.setCodeSigningRequirement(
            "identifier \"com.ayush.Volt.helper\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(team)\""
        )
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async { completion("error: \(error.localizedDescription)") }
            connection.invalidate()
        } as? VoltHelperProtocol
        proxy?.version { version in
            DispatchQueue.main.async { completion(version) }
            connection.invalidate()
        }
    }

    /// The Team ID this app is signed with, read from its own signature.
    static func ownTeamIdentifier() -> String? {
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
}
