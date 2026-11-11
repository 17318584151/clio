import Foundation
import CryptoKit

/// The second source of quota state: what Claude Code hands its status line.
///
/// Running this binary as that command (or in front of an existing one) writes
/// the `rate_limits` payload where the panel can read it, and forwards stdin to
/// the wrapped command untouched so an existing status line keeps rendering.
/// It arrives on every status-line render, which is far more often than the
/// panel would poll on its own — but it has never carried the model-scoped
/// window, so it complements the CLI rather than replacing it.
enum RateLimitBridge {
    private static func snapshotPath(for accountID: String, support: URL) -> URL {
        let digest = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return support.appending(path: "rate-limits-\(digest).json")
    }

    /// `--statusline [legacyAccountID] [-- command args...]`
    static func run(accountID: String?, passthrough: [String]) -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let configDirectory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        capture(input, accountID: accountID, configDirectory: configDirectory)
        guard let command = passthrough.first else { return 0 }
        return forward(input, to: command, arguments: Array(passthrough.dropFirst()))
    }

    static func capture(_ data: Data, accountID: String? = nil, configDirectory: String?,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser, support: URL = AppPaths.support) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any]
        else { return }
        let directory = (configDirectory.map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".claude"))
            .standardizedFileURL.resolvingSymlinksInPath()
        // Orca synchronizes statusLine settings between profiles. Resolve the
        // login from the running session's directory, not an installation ID.
        // Legacy commands with a bound ID remain checked until reinstalled.
        let profile = ClaudeConfigReader.profile(in: directory, home: home)
        guard let data = try? Data(contentsOf: profile),
              let login = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = login["oauthAccount"] as? [String: Any],
              let currentID = ClaudeConfigReader.accountID(account),
              accountID == nil || currentID == accountID else { return }
        let accountID = currentID
        var reading = snapshot(from: limits)
        guard reading.fiveHour?.usedPercentage != nil || reading.sevenDay?.usedPercentage != nil else { return }
        if let previous = load(accountID: accountID, support: support) {
            reading = reading.stabilized(against: previous, now: reading.updatedAt)
            if reading.fiveHour == previous.fiveHour && reading.sevenDay == previous.sevenDay
                && reading.modelScoped == previous.modelScoped { return }
        }
        guard let encoded = try? JSONEncoder().encode(reading) else { return }
        try? encoded.write(to: snapshotPath(for: accountID, support: support), options: .atomic)
    }

    static func load(accountID: String, support: URL = AppPaths.support) -> RateLimitSnapshot? {
        guard let data = try? Data(contentsOf: snapshotPath(for: accountID, support: support)) else { return nil }
        return try? JSONDecoder().decode(RateLimitSnapshot.self, from: data)
    }

    /// Shared with `ClaudeConfigReader`: the sources report the same windows, under
    /// slightly different key names and time formats.
    static func snapshot(from limits: [String: Any]) -> RateLimitSnapshot {
        RateLimitSnapshot(updatedAt: Date(),
                          fiveHour: window(limits["five_hour"]),
                          sevenDay: window(limits["seven_day"]),
                          modelScoped: scoped(limits["model_scoped"]))
    }

    private static func window(_ value: Any?) -> RateLimitWindow? {
        guard let object = value as? [String: Any] else { return nil }
        // The status line calls it `used_percentage`; the CLI's quota cache
        // calls the same number `utilization`.
        return RateLimitWindow(usedPercentage: number(object["used_percentage"]) ?? number(object["utilization"]),
                               resetsAt: date(object["resets_at"]))
    }

    private static func scoped(_ value: Any?) -> [ScopedRateLimitWindow] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let name = entry["display_name"] as? String, !name.isEmpty else { return nil }
            return ScopedRateLimitWindow(displayName: name,
                                         utilization: number(entry["utilization"]),
                                         resetsAt: date(entry["resets_at"]))
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    /// The status line sends Unix seconds, the CLI an ISO string.
    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String { return ISO8601.date(from: text) }
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: Double(seconds)) }
        return nil
    }

    /// Run the wrapped status-line command with the same stdin and hand its
    /// output straight through, so wrapping is invisible to the terminal.
    private static func forward(_ input: Data, to command: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        let stdin = Pipe()
        process.standardInput = stdin
        do {
            try process.run()
        } catch {
            return 0
        }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
