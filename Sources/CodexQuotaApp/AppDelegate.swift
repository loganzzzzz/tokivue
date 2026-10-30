import AppKit
import CodexQuotaCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenuController: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusMenuController = StatusMenuController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusMenuController?.stop()
    }
}
