import SwiftUI
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    var isAvailable: Bool { controller != nil }
    private let controller: SPUStandardUpdaterController?

    init() {
        // Local builds without a signing key and smoke tests must not contact
        // the update server or display Sparkle dialogs.
        guard Self.isConfigured(info: Bundle.main.infoDictionary ?? [:],
                                smoke: ProcessInfo.processInfo.environment["MIXOTO_SMOKE_REPORT"] != nil) else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        controller.startUpdater()
    }

    static func isConfigured(info: [String: Any], smoke: Bool) -> Bool {
        guard !smoke,
              let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = info["SUPublicEDKey"] as? String,
              let data = Data(base64Encoded: key), data.count == 32 else { return false }
        return true
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }
}
