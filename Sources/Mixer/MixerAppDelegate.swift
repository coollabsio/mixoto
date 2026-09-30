import AppKit

@MainActor
final class MixerAppDelegate: NSObject, NSApplicationDelegate {
    // The app owns the mixer, not the window. Closing it must not stop audio.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ProcessInfo.processInfo.environment["MIXOTO_SMOKE_REPORT"] != nil {
            return .terminateNow
        }
        return Self.terminationReply {
            sender.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Quit Mixoto?"
            alert.informativeText = "Audio mixing will stop. Closing the window instead keeps Mixoto running in the menu bar."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit")
            return alert.runModal()
        }
    }

    static func terminationReply(confirm: () -> NSApplication.ModalResponse) -> NSApplication.TerminateReply {
        confirm() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
