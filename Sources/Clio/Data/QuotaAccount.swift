import Foundation

/// A login directory is a query context; identity deduplicates the same account.
struct QuotaAccount: Identifiable, Equatable {
    let id: String
    let tool: Tool
    let name: String
    let directory: URL
    let profile: URL
    let isDefault: Bool

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         extraDirectories: [String] = []) -> [QuotaAccount] {
        let orca = home.appending(path: "Library/Application Support/orca")
        var candidates = [home.appending(path: ".claude"), home.appending(path: ".codex")]
        for folder in ["claude-profiles", "codex-profiles"] {
            let root = orca.appending(path: folder)
            let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            candidates += children.sorted { $0.path < $1.path }.map { $0.appending(path: "home") }
        }
        candidates.append(orca.appending(path: "codex-runtime-home/home"))
        candidates += extraDirectories.map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        var accounts: [QuotaAccount] = candidates.compactMap { directory in
            guard let account = read(directory: directory, home: home), seen.insert(account.id).inserted else { return nil }
            return account
        }
        if let antigravity = antigravity(home: home) { accounts.append(antigravity) }
        return Tool.allCases.flatMap { tool in accounts.filter { $0.tool == tool } }
    }

    /// agy keeps no readable credentials, but each run logs the signed-in
    /// account early on. The newest log that names one is the current login.
    static func antigravity(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> QuotaAccount? {
        let directory = home.appending(path: ".gemini/antigravity-cli")
        let logs = (try? FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "log").path)) ?? []
        for name in logs.filter({ $0.hasPrefix("cli-") }).sorted(by: >) {
            guard let handle = FileHandle(forReadingAtPath: directory.appending(path: "log/\(name)").path) else { continue }
            let head = String(decoding: handle.readData(ofLength: 64 * 1024), as: UTF8.self)
            try? handle.close()
            guard let email = head.matches(of: #/applyAuthResult: email=([^,\s]+)/#).last?.1 else { continue }
            return QuotaAccount(id: RateLimitBridge.antigravityID(String(email)), tool: .antigravity, name: String(email),
                                directory: directory, profile: directory.appending(path: "settings.json"), isDefault: true)
        }
        return nil
    }

    static func read(directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> QuotaAccount? {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let defaultClaude = home.appending(path: ".claude").standardizedFileURL.resolvingSymlinksInPath()
        let profile = ClaudeConfigReader.profile(in: directory, home: home)
        if let root = object(profile), let account = root["oauthAccount"] as? [String: Any],
           let id = ClaudeConfigReader.accountID(account) {
            return QuotaAccount(id: id, tool: .claudeCode,
                name: account["emailAddress"] as? String ?? "Claude · \(id.dropFirst("claude:".count).prefix(8))",
                directory: directory, profile: profile, isDefault: directory == defaultClaude)
        }
        let auth = directory.appending(path: "auth.json")
        if let root = object(auth), let tokens = root["tokens"] as? [String: Any],
           let account = tokens["account_id"] as? String, !account.isEmpty {
            let claims = (tokens["id_token"] as? String).flatMap(jwtClaims)
            return QuotaAccount(id: "codex:\(account)", tool: .codex,
                name: claims?["email"] as? String ?? "Codex · \(account.prefix(8))",
                directory: directory, profile: auth,
                isDefault: directory == home.appending(path: ".codex").standardizedFileURL.resolvingSymlinksInPath())
        }
        return nil
    }

    private static func object(_ path: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Only display metadata is decoded; the CLI handles authentication.
    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

struct AccountQuota: Identifiable {
    var account: QuotaAccount
    var quota: RateLimitSnapshot?
    var plan: String?
    var remainingResets: Int?
    var status: String
    var id: String { account.id }

    /// Pushed and cached quotas arrive only while the tool runs, so they hold until
    /// their window resets. Codex readings also lapse after two query intervals.
    func displayedFraction(_ window: RateLimitWindow, now: Date = Date(), codexQueryInterval: TimeInterval) -> Double? {
        guard window.isCurrent(at: now) else { return nil }
        guard account.tool == .codex else { return window.fraction }
        let valid = quota.map { now.timeIntervalSince($0.updatedAt) < codexQueryInterval * 2 } ?? false
        return valid ? window.fraction : nil
    }

    static func cached(_ account: QuotaAccount, support: URL = AppPaths.support) -> AccountQuota {
        let data = try? Data(contentsOf: account.profile)
        let cache = account.tool == .claudeCode ? data.flatMap(ClaudeConfigReader.parse) : nil
        let feed = account.tool == .codex ? nil : RateLimitBridge.load(accountID: account.id, support: support)
        // Choose a snapshot as a unit so both windows share the shown timestamp.
        let pushed = feed.map { $0.updatedAt > (cache?.updatedAt ?? .distantPast) } ?? false
        let quota = pushed ? feed?.stabilized(against: cache, now: Date()) : cache
        return AccountQuota(account: account,
            quota: quota,
            plan: account.tool == .claudeCode ? data.flatMap(PlanReader.parse) : nil,
            status: pushed ? "状态栏推送" : quota != nil ? "本地缓存"
                : account.tool == .codex ? "尚未查询" : "尚未推送")
    }

    /// Only Codex is queried; the other tools report through their status line.
    static func fetch(_ account: QuotaAccount) -> AccountQuota {
        guard account.tool == .codex else { return cached(account) }
        let result = CodexUsageProbe.fetch(configDirectory: account.directory)
        return AccountQuota(account: account, quota: result?.quota, plan: result?.plan,
                            remainingResets: result?.remainingResets,
                            status: result == nil ? "查询失败" : "已查询")
    }
}
