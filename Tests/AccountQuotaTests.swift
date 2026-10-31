import Foundation

/// Account refresh tests must never launch a real CLI or touch real logins.
enum UsageProbe {
    static var calls: [URL?] = []
    static var response: ((URL?) -> RateLimitSnapshot?)?

    static func systemProxyEnvironment() -> [String: String] { [:] }

    static func fetch(configDirectory: URL? = nil, maxAge: TimeInterval = 1800) -> RateLimitSnapshot? {
        calls.append(configDirectory)
        return response?(configDirectory)
    }
}

@main
enum AccountQuotaTests {
    static func main() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "clio-accounts-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ path: URL, _ value: [String: Any]) throws {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value).write(to: path)
        }
        func claude(_ id: String, _ percent: Int) -> [String: Any] {
            ["oauthAccount": ["accountUuid": id, "organizationUuid": "org", "emailAddress": "\(id)@example.com"],
             "cachedUsageUtilization": ["accountUuid": id, "fetchedAtMs": Date().timeIntervalSince1970 * 1000,
                "utilization": ["seven_day": ["utilization": percent]]]]
        }
        try write(home.appending(path: ".claude.json"), claude("default", 100))
        let managed = home.appending(path: "Library/Application Support/orca/claude-profiles/second/home")
        try write(managed.appending(path: ".claude.json"), claude("second", 4))
        let custom = home.appending(path: "custom")
        try write(custom.appending(path: ".claude.json"), claude("second", 4))
        try write(home.appending(path: ".codex/auth.json"), ["tokens": ["account_id": "codex-one"]])
        let accounts = QuotaAccount.discover(home: home, extraDirectories: [custom.path, home.appending(path: "absent").path])
        precondition(accounts.count == 3, "same identity is shown once; missing directories are ignored")
        precondition(accounts.map(\.tool) == [.claudeCode, .claudeCode, .codex],
                     "Claude Code accounts appear together before Codex")
        precondition(accounts.filter(\.isDefault).count == 2)
        let second = accounts.first { $0.name == "second@example.com" }!
        precondition(second.directory == managed.standardizedFileURL.resolvingSymlinksInPath())
        precondition(AccountQuota.cached(second).quota?.sevenDay?.usedPercentage == 4)
        let fresh = AccountQuota.fetch(second)
        precondition(UsageProbe.calls.isEmpty, "fresh local quota must not launch Claude CLI")
        precondition(fresh.quota?.sevenDay?.usedPercentage == 4, "fresh local quota remains visible")
        let primary = accounts.first { $0.name == "default@example.com" }!
        precondition(AccountQuota.cached(primary).quota?.sevenDay?.usedPercentage == 100)
        precondition(AccountQuota.cached(accounts.first { $0.tool == .codex }!).quota == nil)
        let zero = home.appending(path: "zero")
        try write(zero.appending(path: ".claude.json"), claude("zero", 0))
        precondition(AccountQuota.cached(QuotaAccount.read(directory: zero, home: home)!).quota?.sevenDay?.usedPercentage == 0)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func checkCache(_ value: [String: Any], queries: Int, _ message: String) throws {
            try write(second.profile, value)
            UsageProbe.calls = []
            UsageProbe.response = { directory in
                precondition(directory == second.directory, "CLI queries use the account's own directory")
                let data = try! JSONSerialization.data(withJSONObject: claude("second", 12))
                try! data.write(to: second.profile)
                return ClaudeConfigReader.parse(data)
            }
            let reading = AccountQuota.fetch(second, maxAge: 1800, now: now)
            precondition(UsageProbe.calls.count == queries, message)
            if queries > 0 {
                precondition(reading.quota?.sevenDay?.usedPercentage == 12, "CLI refresh reads the updated local cache")
            }
        }
        func cache(age: TimeInterval, utilization: [String: Any] = ["seven_day": ["utilization": 4]]) -> [String: Any] {
            var value = claude("second", 4)
            value["cachedUsageUtilization"] = ["accountUuid": "second",
                "fetchedAtMs": now.addingTimeInterval(-age).timeIntervalSince1970 * 1000,
                "utilization": utilization]
            return value
        }
        try checkCache(cache(age: 1799), queries: 0, "cache is reused until the configured expiry")
        UsageProbe.response = { _ in
            let data = try! JSONSerialization.data(withJSONObject: claude("second", 12))
            try! data.write(to: second.profile)
            return ClaudeConfigReader.parse(data)
        }
        _ = AccountQuota.fetch(second, maxAge: 1800, now: now, force: true)
        precondition(UsageProbe.calls.count == 1, "explicit manual queries refresh even a fresh cache")
        try checkCache(cache(age: 1800), queries: 1, "cache expires at the configured boundary")
        try checkCache(cache(age: -60), queries: 1, "future-dated caches cannot suppress queries")
        try checkCache(cache(age: 60, utilization: ["seven_day": ["utilization": 100]]), queries: 0,
                       "fully consumed quota is still a valid cached reading")
        try checkCache(cache(age: 60, utilization: ["seven_day": ["utilization": 0]]), queries: 0,
                       "zero utilization is a known cached value")
        try checkCache(cache(age: 60, utilization: [
            "five_hour": ["utilization": 100, "resets_at": now.addingTimeInterval(-1).timeIntervalSince1970],
            "seven_day": ["utilization": 4]]), queries: 1, "a reset window requires fresh quota")
        try checkCache(cache(age: 60, utilization: [:]), queries: 1, "empty caches require a CLI query")
        var missing = claude("second", 4)
        missing.removeValue(forKey: "cachedUsageUtilization")
        try checkCache(missing, queries: 1, "missing caches require a CLI query")
        var wrongOwner = cache(age: 60)
        var payload = wrongOwner["cachedUsageUtilization"] as! [String: Any]
        payload["accountUuid"] = "another-account"
        wrongOwner["cachedUsageUtilization"] = payload
        try checkCache(wrongOwner, queries: 1, "another account's cache must not suppress a query")
        payload.removeValue(forKey: "accountUuid")
        wrongOwner["cachedUsageUtilization"] = payload
        try checkCache(wrongOwner, queries: 1, "cache ownership must be present for a known account")
        try write(second.profile, cache(age: 1801))
        UsageProbe.calls = []
        UsageProbe.response = nil
        let failed = AccountQuota.fetch(second, maxAge: 1800, now: now)
        precondition(UsageProbe.calls.count == 1 && failed.quota == nil && failed.status == "查询失败",
                     "failed refreshes never turn expired data into current quota")
        let longerInterval = AccountQuota.fetch(second, maxAge: 3600, now: now)
        precondition(UsageProbe.calls.count == 1 && longerInterval.quota != nil,
                     "freshness follows the configured interval instead of a fixed duration")
        print("Account quota checks passed: discovery, grouping, ownership, cache expiry and CLI fallback")
    }
}
