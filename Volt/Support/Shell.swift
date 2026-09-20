import Foundation

/// Thin wrapper for the handful of command-line tools that expose data with no
/// public framework equivalent (`system_profiler`, `top`).
enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 20) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        // Drain concurrently; `top` and `system_profiler` can outrun the pipe buffer.
        var data = Data()
        let queue = DispatchQueue(label: "volt.shell.read")
        let done = DispatchSemaphore(value: 0)
        queue.async {
            data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            done.signal()
        }

        let deadline = DispatchTime.now() + timeout
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
        }
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
