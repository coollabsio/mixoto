import Foundation

// TEMPORARY workaround for a macOS process-tap bug. Remove it when Apple fixes
// the bug: https://developer.apple.com/forums/thread/825780
//
// After a tapped app reconfigures its audio, the tap can deliver only zeros
// while the app is still audible. Helium does this when a page checks the
// microphone (x.com): it opens an input for about 14 ms. Core Audio sends no
// property notification for that, but coreaudiod logs it. This watcher reads
// those log lines and reports the process ID; the router then rebuilds a
// silent tap of that app.
//
// The predicate is evaluated in logd, so this costs about 0% CPU and 3 MB
// (measured over 60 s). If Apple changes the log text, nothing matches and
// the other repairs in AudioRouter still apply.
final class AudioClientLog {
    private var process: Process?
    private let handler: (pid_t?) -> Void
    private var pending = ""
    // nil: a change without a process ID (I/O buffer size change).
    init(handler: @escaping (pid_t?) -> Void) { self.handler = handler }

    func start() {
        guard process == nil else { return }
        // A watcher from a Mixoto that crashed or was force-quit keeps
        // running under launchd (parent PID 1). Stop it first.
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        cleanup.arguments = ["-P", "1", "-f", "PublishRecordingClientInfo: Report client"]
        if (try? cleanup.run()) != nil { cleanup.waitUntilExit() }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "compact", "--predicate",
                             #"process == "coreaudiod" AND (eventMessage CONTAINS "PublishRecordingClientInfo: Report client" OR eventMessage CONTAINS "buffer frame size change")"#]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.read(String(decoding: data, as: UTF8.self)) }
        }
        do { try process.run(); self.process = process } catch { log.error("Audio client log: \(error.localizedDescription, privacy: .public)") }
    }
    func stop() {
        process?.terminate(); process = nil; pending = ""
    }
    func read(_ text: String) {
        pending += text
        while let end = pending.firstIndex(of: "\n") {
            let line = pending[..<end]; pending.removeSubrange(...end)
            log.debug("Audio client log: \(line, privacy: .public)")
            if let range = line.range(of: "Report client ") {
                if let pid = pid_t(line[range.upperBound...].prefix { $0.isNumber }) { handler(pid) }
            } else if line.contains("buffer frame size change") {
                handler(nil)
            }
        }
    }
    deinit { stop() }
}
