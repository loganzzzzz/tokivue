import Foundation

public final class CodexLocator {
    public static let customPathDefaultsKey = "CodexExecutablePath"

    private let defaults: UserDefaults
    private let fileManager: FileManager

    public init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    public var customExecutableURL: URL? {
        guard let path = defaults.string(forKey: Self.customPathDefaultsKey) else {
            return nil
        }
        return validatedExecutable(URL(fileURLWithPath: path))
    }

    public func resolveExecutable() -> URL? {
        if let customExecutableURL { return customExecutableURL }

        for candidate in automaticCandidates() {
            if let executable = validatedExecutable(candidate) {
                return executable
            }
        }
        return nil
    }

    @discardableResult
    public func setCustomExecutable(_ selection: URL) -> URL? {
        guard let executable = executableInsideSelection(selection) else { return nil }
        defaults.set(executable.path, forKey: Self.customPathDefaultsKey)
        return executable
    }

    public func clearCustomExecutable() {
        defaults.removeObject(forKey: Self.customPathDefaultsKey)
    }

    public func executableInsideSelection(_ selection: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: selection.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            let candidates: [URL]
            if selection.pathExtension.lowercased() == "app" {
                candidates = [
                    selection.appendingPathComponent("Contents/Resources/codex"),
                    selection.appendingPathComponent("Contents/MacOS/codex"),
                ]
            } else {
                candidates = [selection.appendingPathComponent("codex")]
            }
            return candidates.compactMap(validatedExecutable).first
        }
        return validatedExecutable(selection)
    }

    public func validatedExecutable(_ url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        guard fileManager.isExecutableFile(atPath: standardized.path) else { return nil }
        return standardized
    }

    private func automaticCandidates() -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent("bin/codex"),
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex")
            })
        }
        return candidates
    }
}
