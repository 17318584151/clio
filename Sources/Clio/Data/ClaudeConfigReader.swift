import Foundation

/// Reads the quota state Claude Code caches in `~/.claude.json`.
///
/// `cachedUsageUtilization` holds the quota payload and its fetch time.
/// Claude Code refreshes it during normal use and when `/usage` runs.
/// Reading the file costs nothing, so it is the
/// first source tried; the CLI is asked only when the cache is missing or stale.
enum ClaudeConfigReader {
    static func accountID(_ account: [String: Any]) -> String? {
        guard let uuid = account["accountUuid"] as? String, !uuid.isEmpty else { return nil }
        return "claude:\(uuid):\(account["organizationUuid"] as? String ?? "")"
    }

    static func profile(in directory: URL, home: URL) -> URL {
        let defaultDirectory = home.appending(path: ".claude").standardizedFileURL.resolvingSymlinksInPath()
        return (directory == defaultDirectory ? home : directory).appending(path: ".claude.json")
    }

    static func read(path: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")) -> RateLimitSnapshot? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return parse(data)
    }

    static func isFresh(_ quota: RateLimitSnapshot?, maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let quota else { return false }
        let age = now.timeIntervalSince(quota.updatedAt)
        let windows = [quota.fiveHour, quota.sevenDay].compactMap { $0 }
        return age >= 0 && age < maxAge && !windows.isEmpty
            && windows.allSatisfy { $0.usedPercentage != nil && $0.isCurrent(at: now) }
    }

    /// Split from the file read so a payload can be checked on its own.
    static func parse(_ data: Data) -> RateLimitSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any],
              let fetched = cached["fetchedAtMs"] as? Double
        else { return nil }

        if let account = root["oauthAccount"] as? [String: Any],
           let current = account["accountUuid"] as? String,
           cached["accountUuid"] as? String != current { return nil }

        var snapshot = RateLimitBridge.snapshot(from: utilization)
        snapshot.updatedAt = Date(timeIntervalSince1970: fetched / 1000)
        // The scoped window is reported through `limits` here rather than
        // `model_scoped`, which this payload leaves null.
        if snapshot.modelScoped.isEmpty {
            snapshot.modelScoped = scopedFromLimits(utilization["limits"])
        }
        return snapshot
    }

    private static func scopedFromLimits(_ value: Any?) -> [ScopedRateLimitWindow] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard entry["kind"] as? String == "weekly_scoped",
                  let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty
            else { return nil }
            return ScopedRateLimitWindow(displayName: name,
                                         utilization: entry["percent"] as? Double
                                             ?? (entry["percent"] as? Int).map(Double.init),
                                         resetsAt: (entry["resets_at"] as? String).flatMap(ISO8601.date(from:)))
        }
    }
}
