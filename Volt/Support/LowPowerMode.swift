import Foundation
import Combine

/// Reads and changes macOS Low Power Mode.
///
/// Reading is free: `ProcessInfo` reports it and posts a notification when it changes,
/// whoever changed it. Writing is not — it is `pmset powermode`, which needs root.
///
/// The switch goes through VoltHelper, a root daemon that exists to do only this, so it
/// flips without a prompt. Until the helper is installed and approved, it falls back to
/// the system's administrator prompt, and the first use kicks off the installation.
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

        let helper = HelperClient.shared
        helper.refreshStatus()

        if helper.isReady {
            helper.setLowPowerMode(enabled) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.isChanging = false
                    self.isEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                case .failure:
                    // The helper is registered but not answering — maybe mid-update.
                    // Fall back rather than leave the switch dead.
                    self.setWithPrompt(enabled)
                }
            }
            return
        }

        // First use: register the helper so later switches are silent, and use the
        // prompt for this one.
        if helper.status == .notRegistered || helper.status == .notFound {
            try? helper.install()
        }
        setWithPrompt(enabled)
    }

    private func setWithPrompt(_ enabled: Bool) {
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

    #if DEBUG
    /// Lets previews and render checks show the Low Power look without changing the
    /// real setting.
    func overrideForPreview(_ enabled: Bool) { isEnabled = enabled }
    #endif
}
