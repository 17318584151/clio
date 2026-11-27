import Foundation

/// Orca's account selection, read and changed through its CLI the way its
/// status-bar account switcher does. A selection applies to agents Orca
/// launches afterwards; running sessions keep their account.
struct OrcaAccounts: Equatable {
    /// What `orca account select` takes for one account.
    struct Target: Equatable, Sendable {
        let agent: String
        let account: String
    }

    /// Keyed by Clio account id.
    var targets: [String: Target] = [:]
    /// Clio accounts Orca currently launches with.
    var active: Set<String> = []

    static var executable: URL? {
        ["/Applications/Orca.app", "\(NSHomeDirectory())/Applications/Orca.app"]
            .map { URL(fileURLWithPath: "\($0)/Contents/Resources/bin/orca") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func load(accounts: [QuotaAccount]) -> OrcaAccounts? {
        run(["account", "list", "--json"]).flatMap { parse($0, accounts: accounts) }
    }

    /// Returns why the switch failed, or nil once Orca has applied it.
    static func select(_ target: Target) -> String? {
        guard let output = run(["account", "select", "--agent", target.agent, "--account", target.account, "--json"])
        else { return "无法运行 Orca CLI，请确认 Orca 已启动" }
        let root = try? JSONSerialization.jsonObject(with: output) as? [String: Any]
        if root?["ok"] as? Bool == true { return nil }
        let error = root?["error"] as? [String: Any]
        return error?["message"] as? String ?? root?["error"] as? String ?? "Orca 未能切换账号"
    }

    /// Claude logins are matched by the identity in their configuration directory,
    /// so a managed folder that repeats the system login maps to the same row.
    /// Antigravity accounts are matched by email.
    static func parse(_ data: Data, accounts: [QuotaAccount],
                      identify: (URL) -> String? = { QuotaAccount.read(directory: $0)?.id }) -> OrcaAccounts? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true, let result = root["result"] as? [String: Any] else { return nil }
        let known = Set(accounts.map(\.id))
        var state = OrcaAccounts()
        if let claude = result["claude"] as? [String: Any] {
            let activeID = claude["activeAccountId"] as? String ?? "system"
            var homes = (claude["systemDefaultHome"] as? String).map { [("system", $0)] } ?? []
            homes += (claude["accounts"] as? [[String: Any]] ?? []).compactMap { account in
                guard let id = account["id"] as? String, let home = account["home"] as? String else { return nil }
                return (id, home)
            }
            for (id, home) in homes {
                guard let clioID = identify(URL(fileURLWithPath: home)), known.contains(clioID) else { continue }
                if state.targets[clioID] == nil { state.targets[clioID] = Target(agent: "claude", account: id) }
                if id == activeID { state.active.insert(clioID) }
            }
        }
        if let antigravity = result["antigravity"] as? [String: Any] {
            let activeID = antigravity["activeAccountId"] as? String
            for account in antigravity["accounts"] as? [[String: Any]] ?? [] {
                guard let id = account["id"] as? String, let email = account["email"] as? String else { continue }
                let clioID = RateLimitBridge.antigravityID(email)
                guard known.contains(clioID) else { continue }
                state.targets[clioID] = Target(agent: "antigravity", account: id)
                if id == activeID { state.active.insert(clioID) }
            }
        }
        return state
    }

    private static func run(_ arguments: [String], timeout: TimeInterval = 20) -> Data? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let expiry = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
        defer { expiry.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationReason == .exit ? data : nil
    }
}
