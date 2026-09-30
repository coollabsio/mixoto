import AppKit
import XCTest
@testable import Mixer

@MainActor
final class MixerAppDelegateTests: XCTestCase {
    func testMenuBarIconIsAnAccessibleTemplate() {
        let image = MixerMenuBar.icon
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(image.accessibilityDescription, "Mixoto")
        XCTAssertNotNil(image.tiffRepresentation)
    }

    func testClosingLastWindowKeepsAppRunning() {
        XCTAssertFalse(MixerAppDelegate().applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    func testQuitRequiresExplicitConfirmation() {
        XCTAssertEqual(MixerAppDelegate.terminationReply { .alertSecondButtonReturn }, .terminateNow)
        XCTAssertEqual(MixerAppDelegate.terminationReply { .alertFirstButtonReturn }, .terminateCancel)
        XCTAssertEqual(MixerAppDelegate.terminationReply { .abort }, .terminateCancel)
    }
}
