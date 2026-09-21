import Foundation
import Combine

/// Reads and changes macOS Low Power Mode.
///
/// Reading is free: `ProcessInfo` reports it and posts a notification when it changes,
/// whoever changed it. Writing is not — it is `pmset powermode`, which needs root.
///
/// There are two ways to get root. A privileged helper daemon runs permanently as root
/// so the switch can flip silently; that is a root process installed on the machine for
/// the sake of one toggle. The alternative, used here, is the system's own
/// administrator prompt, which accepts Touch ID and leaves nothing privileged behind.
final class LowPowerMode: ObservableObject {
    static let shared = LowPowerMode()

    @Published private(set) var isEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var isChanging = false
    @Published private(set) var lastError: String?

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    /// Applies to every power source, matching "Always" in System Settings.
    func set(_ enabled: Bool) {
        guard !isChanging, enabled != isEnabled else { return }
        isChanging = true
        lastError = nil

        let mode = enabled ? 1 : 0
        let source = """
        do shell script "/usr/bin/pmset -a powermode \(mode)" with administrator privileges
        """

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)

            DispatchQueue.main.async {
                self.isChanging = false
                self.isEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                // Cancelling the prompt is error -128; that is the user's choice, not a
                // failure worth reporting.
                if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
                    self.lastError = error[NSAppleScript.errorMessage] as? String
                        ?? "Could not change Low Power Mode."
                }
            }
        }
    }

    func toggle() { set(!isEnabled) }
}
