import Foundation

enum DriverInstaller {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func appleScript(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
    static func install(driver: URL, script: URL) async throws {
        let command = "/bin/sh \(shellQuote(script.path)) \(shellQuote(driver.path))"
        let source = appleScript(command)
        // User starts this action explicitly. macOS presents its own password
        // dialog; no password is collected or saved by Mixoto.
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw MixerError.message(String(data: output, encoding: .utf8) ?? "Driver installation was cancelled or failed.")
            }
        }.value
    }
}
