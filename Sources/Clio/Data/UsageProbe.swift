import Foundation
import CFNetwork
import Darwin

/// Has Claude Code refresh the plan's quota state.
///
/// Runs `/usage` in the account's configuration directory, then reads the
/// quota cache Claude Code writes there. Login and token renewal stay with
/// Claude Code; the cache retains its original fetch timestamp.
enum UsageProbe {
    private static let candidates = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    static var executable: URL? {
        candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// A successful process exit alone is not enough: missing, stale or
    /// mismatched cache data still means the quota could not be refreshed.
    static func fetch(executable: URL? = UsageProbe.executable,
                      timeout: TimeInterval = 20, configDirectory: URL? = nil,
                      maxAge: TimeInterval = 1800) -> RateLimitSnapshot? {
        guard let executable else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "/usage", "--output-format", "json",
                             "--tools", "", "--strict-mcp-config",
                             "--setting-sources", "", "--no-session-persistence"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        // Finder-launched processes need explicit identity and system proxy
        // settings so the CLI can resolve its login and reach the quota API.
        var environment = [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            // Node trusts the system store, so a proxy signing with a locally
            // installed CA still validates.
            "NODE_USE_SYSTEM_CA": "1",
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
            "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1",
            "DISABLE_AUTOUPDATER": "1",
        ]
        environment.merge(systemProxyEnvironment()) { current, _ in current }
        if let configDirectory { environment["CLAUDE_CONFIG_DIR"] = configDirectory.path }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let expiry = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
        defer { expiry.cancel() }

        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        let profile = configDirectory?.appending(path: ".claude.json")
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
        let quota = ClaudeConfigReader.read(path: profile)
        return ClaudeConfigReader.isFresh(quota, maxAge: maxAge) ? quota : nil
    }

    /// The system's own proxy configuration, in the form command-line tools read.
    static func systemProxyEnvironment() -> [String: String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return [:]
        }
        var environment: [String: String] = [:]
        func proxy(_ enable: CFString, _ host: CFString, _ port: CFString) -> String? {
            guard settings[enable as String] as? Int == 1,
                  let host = settings[host as String] as? String,
                  let port = settings[port as String] as? Int
            else { return nil }
            return "http://\(host):\(port)"
        }
        if let https = proxy(kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesHTTPSProxy, kCFNetworkProxiesHTTPSPort) {
            environment["HTTPS_PROXY"] = https
        }
        if let http = proxy(kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPProxy, kCFNetworkProxiesHTTPPort) {
            environment["HTTP_PROXY"] = http
        }
        if let exceptions = settings[kCFNetworkProxiesExceptionsList as String] as? [String], !exceptions.isEmpty {
            environment["NO_PROXY"] = exceptions.joined(separator: ",")
        }
        return environment
    }
}
