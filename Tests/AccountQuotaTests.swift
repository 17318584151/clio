import Foundation

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
        let fetched = AccountQuota.fetch(second)
        precondition(fetched.quota?.sevenDay?.usedPercentage == 4 && fetched.status == "本地缓存",
                     "Claude accounts are never queried; fetching returns the local reading")
        let primary = accounts.first { $0.name == "default@example.com" }!
        precondition(AccountQuota.cached(primary).quota?.sevenDay?.usedPercentage == 100)
        precondition(AccountQuota.cached(accounts.first { $0.tool == .codex }!).quota == nil)
        let zero = home.appending(path: "zero")
        try write(zero.appending(path: ".claude.json"), claude("zero", 0))
        precondition(AccountQuota.cached(QuotaAccount.read(directory: zero, home: home)!).quota?.sevenDay?.usedPercentage == 0)

        func push(_ percent: Int, accountID: String, directory: URL?) throws {
            let payload = try JSONSerialization.data(withJSONObject: [
                "rate_limits": [
                    "five_hour": ["used_percentage": 0],
                    "seven_day": ["used_percentage": percent]
                ]
            ])
            RateLimitBridge.capture(payload, accountID: accountID, configDirectory: directory?.path,
                                    home: home, support: home)
        }
        try push(29, accountID: second.id, directory: managed)
        try push(36, accountID: primary.id, directory: nil)
        let pushed = AccountQuota.cached(second, support: home)
        precondition(pushed.quota?.fiveHour?.usedPercentage == 0 && pushed.quota?.sevenDay?.usedPercentage == 29)
        precondition(AccountQuota.cached(primary, support: home).quota?.sevenDay?.usedPercentage == 36)
        try push(88, accountID: second.id, directory: nil)
        precondition(RateLimitBridge.load(accountID: second.id, support: home) == pushed.quota,
                     "a default session cannot publish to a different account")
        try write(second.profile, claude("new-login", 4))
        try push(88, accountID: second.id, directory: managed)
        let newLogin = QuotaAccount.read(directory: managed, home: home)!
        precondition(RateLimitBridge.load(accountID: second.id, support: home) == pushed.quota
            && RateLimitBridge.load(accountID: newLogin.id, support: home) == nil,
            "a wrapper installed before switching accounts cannot publish for either login")

        let settings = managed.appending(path: "settings.json")
        let original = "cat | sed 's/foo/bar/'"
        try write(settings, ["statusLine": ["type": "command", "command": "\"/Applications/Clio.app/Contents/MacOS/Clio\" --statusline -- \(original)"]])
        try StatusLineInstaller.install(at: settings)
        precondition(StatusLineInstaller.state(at: settings) == .installed)
        let installed = try Data(contentsOf: settings)
        try StatusLineInstaller.install(at: settings)
        let reinstalled = try Data(contentsOf: settings)
        precondition(reinstalled == installed, "installing twice does not nest wrappers")
        try StatusLineInstaller.remove(at: settings)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        precondition((restored?["statusLine"] as? [String: String])?["command"] == original,
                     "upgrading and removing the wrapper restores the original shell command")

        // Orca copies the host statusLine setting into profile directories.
        // The same command must route each invocation using CLAUDE_CONFIG_DIR.
        let dynamicPayload = try JSONSerialization.data(withJSONObject: [
            "rate_limits": ["five_hour": ["used_percentage": 2], "seven_day": ["used_percentage": 44]]
        ])
        RateLimitBridge.capture(dynamicPayload, configDirectory: managed.path, home: home, support: home)
        precondition(RateLimitBridge.load(accountID: newLogin.id, support: home)?.fiveHour?.usedPercentage == 2)
        precondition(RateLimitBridge.load(accountID: second.id, support: home) == pushed.quota,
                     "switching accounts leaves the old account's snapshot untouched")
        try write(managed.appending(path: ".claude.json"), claude("switched-again", 9))
        let switched = QuotaAccount.read(directory: managed, home: home)!
        RateLimitBridge.capture(dynamicPayload, configDirectory: managed.path, home: home, support: home)
        precondition(RateLimitBridge.load(accountID: switched.id, support: home)?.sevenDay?.usedPercentage == 44,
                     "a directory's new login works without reinstalling the wrapper")
        RateLimitBridge.capture(dynamicPayload, configDirectory: nil, home: home, support: home)
        precondition(RateLimitBridge.load(accountID: primary.id, support: home)?.fiveHour?.usedPercentage == 2,
                     "the same command also routes the default login")
        let weeklyOnly = try JSONSerialization.data(withJSONObject: ["rate_limits": ["seven_day": ["used_percentage": 45]]])
        RateLimitBridge.capture(weeklyOnly, configDirectory: nil, home: home, support: home)
        let partial = RateLimitBridge.load(accountID: primary.id, support: home)
        precondition(partial?.fiveHour?.usedPercentage == 2 && partial?.sevenDay?.usedPercentage == 45,
                     "a session that has not seen the 5-hour window cannot erase it")

        // agy names its login in each run's log and pushes quota buckets under that email.
        let agyLogs = home.appending(path: ".gemini/antigravity-cli/log")
        try FileManager.default.createDirectory(at: agyLogs, withIntermediateDirectories: true)
        try "I1126 applyAuthResult: email=Agy@example.com, authMethod=consumer"
            .write(to: agyLogs.appending(path: "cli-20261126_100000.log"), atomically: true, encoding: .utf8)
        try "I1127 started before signing in"
            .write(to: agyLogs.appending(path: "cli-20261127_100000.log"), atomically: true, encoding: .utf8)
        try "I1128 applyAuthResult: email=server@example.com, authMethod=consumer"
            .write(to: agyLogs.appending(path: "acp-server-20261128_100000.log"), atomically: true, encoding: .utf8)
        let agy = QuotaAccount.antigravity(home: home)!
        precondition(agy.name == "Agy@example.com" && agy.id == RateLimitBridge.antigravityID("agy@example.com"),
                     "the newest CLI log naming a login identifies the account")
        precondition(QuotaAccount.discover(home: home).last == agy, "Antigravity is listed after Claude Code and Codex")
        precondition(AccountQuota.cached(agy, support: home).status == "尚未推送")
        let agyReset = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 3600).rounded())
        let agyPayload = try JSONSerialization.data(withJSONObject: [
            "product": "antigravity", "email": "agy@example.com",
            "quota": [
                "gemini-5h": ["remaining_fraction": 0.75, "reset_time": ISO8601DateFormatter().string(from: agyReset)],
                "gemini-weekly": ["remaining_fraction": 1, "reset_time": "1970-01-01T00:00:00Z"],
                "3p-5h": ["remaining_fraction": 0.1, "reset_time": "1970-01-01T00:00:00Z"],
            ],
        ])
        RateLimitBridge.capture(agyPayload, configDirectory: nil, home: home, support: home)
        let agyQuota = AccountQuota.cached(agy, support: home)
        precondition(agyQuota.status == "状态栏推送" && agyQuota.quota?.fiveHour == RateLimitWindow(usedPercentage: 25, resetsAt: agyReset)
                     && agyQuota.quota?.sevenDay == RateLimitWindow(usedPercentage: 0, resetsAt: nil),
                     "the Gemini buckets become the windows; an unused bucket has no reset time")
        precondition(RateLimitBridge.load(accountID: primary.id, support: home)?.fiveHour?.usedPercentage == 2,
                     "an agy payload never lands on a Claude account")
        // Orca's account list maps onto Clio's rows by login identity and email.
        try write(managed.appending(path: ".claude.json"), claude("second", 4))
        func orcaList(claudeActive: String?, extra: [[String: Any]] = []) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
                "claude": ["systemDefaultHome": home.appending(path: ".claude").path,
                           "activeAccountId": claudeActive.map { $0 as Any } ?? NSNull(),
                           "accounts": [["id": "managed-id", "home": managed.path],
                                        ["id": "copy-id", "home": custom.path],
                                        ["id": "gone-id", "home": home.appending(path: "gone").path]] + extra],
                "antigravity": ["activeAccountId": "agy-id",
                                "accounts": [["id": "agy-id", "email": "AGY@example.com"],
                                             ["id": "other-id", "email": "other@example.com"]]],
            ]])
        }
        let rows = accounts + [agy]
        let identify = { (directory: URL) in QuotaAccount.read(directory: directory, home: home)?.id }
        let orca = OrcaAccounts.parse(try orcaList(claudeActive: "managed-id"), accounts: rows, identify: identify)!
        precondition(orca.targets == [primary.id: .init(agent: "claude", account: "system"),
                                      second.id: .init(agent: "claude", account: "managed-id"),
                                      agy.id: .init(agent: "antigravity", account: "agy-id")],
                     "each shown login maps to the first Orca account for it; unknown logins are left out")
        precondition(orca.active == [second.id, agy.id], "Orca's active Claude and agy accounts are marked")
        let systemActive = OrcaAccounts.parse(try orcaList(claudeActive: nil), accounts: rows, identify: identify)
        precondition(systemActive?.active == [primary.id, agy.id], "no active managed account means the system login")
        let copyActive = OrcaAccounts.parse(try orcaList(claudeActive: "copy-id"), accounts: rows, identify: identify)
        precondition(copyActive?.active == [second.id, agy.id], "a folder repeating a shown login marks that row")
        precondition(OrcaAccounts.parse(Data(#"{"ok":false,"error":{"message":"down"}}"#.utf8), accounts: rows) == nil,
                     "a failed listing yields no Orca state")

        var staleAgy = agyQuota
        staleAgy.quota?.updatedAt = .distantPast
        precondition(staleAgy.displayedFraction(staleAgy.quota!.fiveHour!, codexQueryInterval: 900) == 0.25,
                     "pushed agy quota holds until its window resets")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldQuota = AccountQuota(account: second,
            quota: RateLimitSnapshot(updatedAt: now.addingTimeInterval(-86400),
                fiveHour: RateLimitWindow(usedPercentage: 25, resetsAt: now.addingTimeInterval(-3600)),
                sevenDay: RateLimitWindow(usedPercentage: 40, resetsAt: now.addingTimeInterval(86400)),
                modelScoped: []), status: "本地缓存")
        precondition(oldQuota.displayedFraction(oldQuota.quota!.sevenDay!, now: now, codexQueryInterval: 900) == 0.4,
                     "Claude keeps old percentages until the window resets")
        precondition(oldQuota.displayedFraction(oldQuota.quota!.fiveHour!, now: now, codexQueryInterval: 900) == nil,
                     "an expired window is cleared without requesting an update")
        let week: TimeInterval = 7 * 86400
        var lapsed = oldQuota
        lapsed.quota?.sevenDay?.resetsAt = now.addingTimeInterval(-2 * week - 3600)
        precondition(lapsed.resetDate(\.sevenDay, now: now) == now.addingTimeInterval(week - 3600),
                     "a passed Claude weekly reset rolls forward to the next week")
        precondition(lapsed.resetDate(\.fiveHour, now: now) == now.addingTimeInterval(-3600),
                     "the 5-hour window starts with use, so its passed reset is not projected")
        var codexQuota = oldQuota
        codexQuota.account = accounts.first { $0.tool == .codex }!
        precondition(codexQuota.displayedFraction(oldQuota.quota!.sevenDay!, now: now, codexQueryInterval: 900) == nil,
                     "Codex readings still lapse after two query intervals")
        codexQuota.quota = lapsed.quota
        precondition(codexQuota.resetDate(\.sevenDay, now: now) == lapsed.quota?.sevenDay?.resetsAt,
                     "Codex weekly windows are not projected")
        precondition(oldQuota.displayedFraction(RateLimitWindow(), now: now, codexQueryInterval: 900) == nil,
                     "a genuinely missing percentage remains unknown")
        var missing = claude("second", 4)
        missing.removeValue(forKey: "cachedUsageUtilization")
        try write(second.profile, missing)
        let unreported = QuotaAccount.read(directory: managed, home: home)!
        precondition(AccountQuota.cached(unreported, support: home.appending(path: "empty")).status == "尚未推送",
                     "a Claude account with neither cache nor push waits for its status line")
        print("Account quota checks passed: discovery, grouping, ownership, status-line pushes and window expiry")
    }
}
