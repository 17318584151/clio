import Foundation
import Darwin

/// Uses the local Codex client's stored login for read-only account queries.
enum CodexUsageProbe {
    struct Reading {
        var quota: RateLimitSnapshot?
        var plan: String?
        var remainingResets: Int?
    }

    static var executable: URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/codex" }
        let candidates = paths + [
            "\(NSHomeDirectory())/.local/bin/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(NSHomeDirectory())/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func fetch(executable: URL? = CodexUsageProbe.executable,
                      timeout: TimeInterval = 20) -> Reading? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = NSHomeDirectory()
        environment["USER"] = NSUserName()
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment.merge(UsageProbe.systemProxyEnvironment()) { current, _ in current }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
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
        defer {
            expiry.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        do {
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": [
                "name": "clio", "title": "Clio",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1",
            ]]])
            var expected = 1
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { return nil }
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    guard let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          response["id"] as? Int == expected else { continue }
                    guard response["error"] == nil,
                          let result = response["result"] as? [String: Any] else { return nil }
                    switch expected {
                    case 1:
                        try send(["method": "initialized", "params": [:]])
                        try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                        expected = 2
                    case 2:
                        guard let account = result["account"] as? [String: Any],
                              account["type"] as? String == "chatgpt" else { return nil }
                        try send(["id": 3, "method": "account/rateLimits/read"])
                        expected = 3
                    default:
                        return parse(try JSONSerialization.data(withJSONObject: result))
                    }
                }
            }
        } catch {
            return nil
        }
    }

    private struct Response: Decodable {
        struct Window: Decodable {
            var usedPercent: Double
            var windowDurationMins: Int
            var resetsAt: Int?
        }
        struct Limits: Decodable {
            var primary: Window?
            var secondary: Window?
            var planType: String?
        }
        struct ResetCredits: Decodable {
            var availableCount: Int?
        }
        var rateLimits: Limits?
        var rateLimitsByLimitId: [String: Limits]?
        var rateLimitResetCredits: ResetCredits?
    }

    static func parse(_ data: Data, at now: Date = Date()) -> Reading? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let limits = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
        var fiveHour: RateLimitWindow?
        var week: RateLimitWindow?
        for entry in [limits?.primary, limits?.secondary].compactMap({ $0 }) {
            let window = RateLimitWindow(usedPercentage: entry.usedPercent,
                                        resetsAt: entry.resetsAt.map { Date(timeIntervalSince1970: Double($0)) })
            guard window.isCurrent(at: now) else { continue }
            if entry.windowDurationMins >= 24 * 60 { week = window }
            else if entry.windowDurationMins > 0 { fiveHour = window }
        }
        let quota = fiveHour != nil || week != nil
            ? RateLimitSnapshot(updatedAt: now, fiveHour: fiveHour, sevenDay: week, modelScoped: []) : nil
        let count = response.rateLimitResetCredits?.availableCount.flatMap { $0 >= 0 ? $0 : nil }
        return Reading(quota: quota, plan: limits?.planType.flatMap(PlanReader.codexDisplayName),
                       remainingResets: count)
    }
}
