import XCTest
import Sparkle
@testable import Mixer

@MainActor
final class AppUpdaterTests: XCTestCase {
    private var configured: [String: Any] {
        ["SUFeedURL": "https://github.com/coollabsio/Mixoto/releases/latest/download/appcast.xml",
         "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]
    }

    func testConfiguredUpdaterRequiresHTTPSAndPublicKey() {
        XCTAssertTrue(AppUpdater.isConfigured(info: configured, smoke: false))
        XCTAssertFalse(AppUpdater.isConfigured(info: [:], smoke: false))
        var info = configured
        info.removeValue(forKey: "SUPublicEDKey")
        XCTAssertFalse(AppUpdater.isConfigured(info: info, smoke: false))
        for key in ["", "not-base64", Data(repeating: 1, count: 31).base64EncodedString()] {
            info["SUPublicEDKey"] = key
            XCTAssertFalse(AppUpdater.isConfigured(info: info, smoke: false))
        }
        for feed in ["http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https:", ""] {
            info = configured
            info["SUFeedURL"] = feed
            XCTAssertFalse(AppUpdater.isConfigured(info: info, smoke: false))
        }
    }

    func testSmokeDisablesEvenConfiguredUpdater() {
        XCTAssertFalse(AppUpdater.isConfigured(info: configured, smoke: true))
    }

    func testReleaseVersionsSortNumerically() {
        let comparator = SUStandardVersionComparator()
        XCTAssertEqual(comparator.compareVersion("0.2.0", toVersion: "0.2.1"), .orderedAscending)
        XCTAssertEqual(comparator.compareVersion("0.2.9", toVersion: "0.2.10"), .orderedAscending)
        XCTAssertEqual(comparator.compareVersion("0.9.0", toVersion: "1.0.0"), .orderedAscending)
        XCTAssertEqual(comparator.compareVersion("1.0.0", toVersion: "1.0.0"), .orderedSame)
    }

    func testUnconfiguredUpdaterDoesNotStartOrCheck() {
        // swift test has no app Info.plist, so no Sparkle instance is started.
        let updater = AppUpdater()
        XCTAssertFalse(updater.isAvailable)
        XCTAssertFalse(updater.canCheckForUpdates)
        updater.checkForUpdates()
        updater.setAutomaticChecks(true)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
    }
}
