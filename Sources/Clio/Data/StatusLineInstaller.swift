import Foundation

/// Installs and removes the status-line wrapper in an account's settings.
///
/// The wrapper is this binary in front of whatever status-line command is
/// already configured, so Claude Code keeps rendering the same line and the
/// quota payload it passes on stdin reaches the panel as well.
enum StatusLineInstaller {
    enum State: Equatable {
        case installed
        case notInstalled
        /// No settings file, or one this can't read.
        case unavailable
    }

    static var settingsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
    }

    private static let marker = "--statusline"

    static func state(at settingsPath: URL) -> State {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else { return .notInstalled }
        guard let text = try? String(contentsOf: settingsPath, encoding: .utf8),
              let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return .unavailable }
        let command = (root["statusLine"] as? [String: Any])?["command"] as? String
        guard let command else { return .notInstalled }
        return command.contains("\(marker) -- ") || command.hasSuffix(" \(marker)")
            ? .installed : .notInstalled
    }

    static func install(at settingsPath: URL) throws {
        guard let binary = Bundle.main.executableURL?.path else { return }
        try edit(at: settingsPath) { current in
            let wrapper = "\(quote(binary)) \(marker)"
            guard let original = current.flatMap(originalCommand), !original.isEmpty else { return wrapper }
            return "\(wrapper) -- /bin/sh -c \(quote(original))"
        }
    }

    static func remove(at settingsPath: URL) throws {
        try edit(at: settingsPath) { current in
            guard let current, current.contains(marker) else { return current }
            return originalCommand(current)
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func originalCommand(_ command: String) -> String? {
        // Both the current and legacy wrappers start with a quoted executable.
        guard let markerRange = command.range(of: #"^('[^']*'|"[^"]*") --statusline(?= |$)"#, options: .regularExpression)
        else { return command }
        let tail = command[markerRange.upperBound...]
        guard let separator = tail.range(of: " -- ") else { return nil }
        let original = tail[separator.upperBound...]
        let shell = "/bin/sh -c '"
        if original.hasPrefix(shell), original.hasSuffix("'") {
            return original.dropFirst(shell.count).dropLast().replacingOccurrences(of: "'\\''", with: "'")
        }
        return String(original)
    }

    /// Rewrites `statusLine.command`, keeping the rest of the file byte for byte
    /// when it can: the file is the user's, and it holds far more than this.
    private static func edit(at settingsPath: URL, _ transform: (String?) -> String?) throws {
        let text = FileManager.default.fileExists(atPath: settingsPath.path)
            ? try String(contentsOf: settingsPath, encoding: .utf8) : "{}"
        guard var root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var line = root["statusLine"] as? [String: Any]
        let current = line?["command"] as? String
        let updated = transform(current)
        guard updated != current else { return }

        try backup(settingsPath)

        if let updated {
            if let current, let replaced = replacing(current, with: updated, in: text) {
                try Data(replaced.utf8).write(to: settingsPath, options: .atomic)
                return
            }
            line = line ?? ["type": "command"]
            line?["command"] = updated
            root["statusLine"] = line
        } else {
            root["statusLine"] = nil
        }
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsPath, options: .atomic)
    }

    /// Swaps one JSON string literal for another, so a file with comments,
    /// ordering or spacing of its own survives untouched.
    private static func replacing(_ current: String, with updated: String, in text: String) -> String? {
        guard let from = literal(current), let to = literal(updated),
              text.components(separatedBy: from).count == 2
        else { return nil }
        return text.replacingOccurrences(of: from, with: to)
    }

    private static func literal(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return String(text.dropFirst().dropLast())
    }

    private static func backup(_ settingsPath: URL) throws {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let copy = settingsPath.deletingLastPathComponent()
            .appending(path: "settings.json.bak-clio-\(stamp.string(from: Date()))")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: settingsPath, to: copy)
    }
}
