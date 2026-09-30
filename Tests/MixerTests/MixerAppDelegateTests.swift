import AppKit
import XCTest
@testable import Mixer

@MainActor
final class MixerAppDelegateTests: XCTestCase {
    func testClosingLastWindowKeepsAppRunning() {
        XCTAssertFalse(MixerAppDelegate().applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    func testQuitRequiresExplicitConfirmation() {
        XCTAssertEqual(MixerAppDelegate.terminationReply { .alertSecondButtonReturn }, .terminateNow)
        XCTAssertEqual(MixerAppDelegate.terminationReply { .alertFirstButtonReturn }, .terminateCancel)
        XCTAssertEqual(MixerAppDelegate.terminationReply { .abort }, .terminateCancel)
    }
}
