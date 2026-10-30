import AppKit
import Foundation

@MainActor
private final class ChatGPTLaunchObserver {
    private static let chatGPTBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.openai.chat",
        "com.openai.chatgpt",
    ]

    private var launchObserver: NSObjectProtocol?
    private let quotaBundleIdentifier = "com.local.codex-quota"
    private let quotaApplicationURL: URL

    init() {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        quotaApplicationURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else {
                return
            }
            MainActor.assumeIsolated {
                self?.handleLaunchedApplication(application)
            }
        }

        if isChatGPTRunning() {
            launchQuotaIfNeeded()
        }
    }

    deinit {
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
    }

    private func handleLaunchedApplication(_ application: NSRunningApplication) {
        guard let bundleIdentifier = application.bundleIdentifier,
              Self.chatGPTBundleIdentifiers.contains(bundleIdentifier)
        else {
            return
        }
        launchQuotaIfNeeded()
    }

    private func isChatGPTRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            guard let bundleIdentifier = application.bundleIdentifier else { return false }
            return Self.chatGPTBundleIdentifiers.contains(bundleIdentifier)
        }
    }

    private func launchQuotaIfNeeded() {
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: quotaBundleIdentifier
        ).isEmpty else {
            return
        }
        guard FileManager.default.fileExists(atPath: quotaApplicationURL.path) else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(
            at: quotaApplicationURL,
            configuration: configuration,
            completionHandler: nil
        )
    }
}

MainActor.assumeIsolated {
    let observer = ChatGPTLaunchObserver()
    withExtendedLifetime(observer) {
        RunLoop.main.run()
    }
}
