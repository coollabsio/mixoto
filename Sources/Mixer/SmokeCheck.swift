import AppKit

@MainActor
enum SmokeCheck {
    // Opt-in local verification. Does not start audio, request recording access,
    // change devices, read saved settings, or write user settings.
    static func runIfRequested(store: MixerStore) async {
        guard let path = ProcessInfo.processInfo.environment["MIXOTO_SMOKE_REPORT"] else { return }
        try? await Task.sleep(nanoseconds: 500_000_000)
        do {
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }), window.contentView != nil else {
                throw MixerError.message("No native window is visible.")
            }
            let report: [String: Any] = ["windowTitle": window.title, "width": window.frame.width, "height": window.frame.height,
                                         "deviceCount": store.devices.count, "applicationCount": store.apps.count, "channelCount": store.settings.channels.count,
                                         "streamDeviceUID": store.settings.streamUID,
                                         "streamDeviceLoaded": store.devices.contains(where: \.isStreamMix),
                                         "driverBundled": Bundle.main.url(forResource: "MixotoAudio", withExtension: "driver") != nil,
                                         "installerBundled": Bundle.main.url(forResource: "install-driver", withExtension: "sh") != nil,
                                         "running": store.running, "message": store.message]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            print("Native window smoke test passed: \(path)")
            NSApplication.shared.terminate(nil)
        } catch {
            fputs("Native window smoke test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
