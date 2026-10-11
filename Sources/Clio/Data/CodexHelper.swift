import Foundation
import Combine
import CFNetwork
import Darwin

@MainActor
final class CodexHelper: ObservableObject {
    static let shared = CodexHelper()
    @Published private(set) var installed = false
    @Published private(set) var busy = false
    @Published private(set) var status = "尚未检测"
    @Published private(set) var result: String
    @Published var http = ""
    @Published var socks = ""

    private let resultFile = AppPaths.support.appending(path: "codex-helper-result.txt")

    private init() {
        result = (try? String(contentsOf: resultFile, encoding: .utf8)) ?? ""
    }

    private func detectProxy(_ response: Response) {
        http = response.http ?? ""
        socks = response.socks ?? ""
        if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] {
            func endpoint(_ enabled: CFString, _ host: CFString, _ port: CFString, scheme: String) -> String? {
                guard settings[enabled as String] as? Int == 1,
                      let address = settings[host as String] as? String,
                      ["localhost", "127.0.0.1", "::1"].contains(address),
                      let number = settings[port as String] as? Int,
                      (1...65535).contains(number) else { return nil }
                return "\(scheme)://\(address.contains(":") ? "[\(address)]" : address):\(number)"
            }
            http = endpoint(kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPProxy,
                            kCFNetworkProxiesHTTPPort, scheme: "http")
                ?? endpoint(kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesHTTPSProxy,
                            kCFNetworkProxiesHTTPSPort, scheme: "http") ?? http
            socks = endpoint(kCFNetworkProxiesSOCKSEnable, kCFNetworkProxiesSOCKSProxy,
                             kCFNetworkProxiesSOCKSPort, scheme: "socks5h") ?? socks
        }
    }

    private static var installer: URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "install", withExtension: "py", subdirectory: "CodexHelper")
        #else
        return Bundle.main.url(forResource: "install", withExtension: "py", subdirectory: "CodexHelper")
        #endif
    }

    private static var nativeExecutable: URL {
        Bundle.main.url(forResource: "CodexHelper", withExtension: nil, subdirectory: "CodexHelper")
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "CodexHelper")
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        status = "正在检测辅助服务…"
        result = ""
        guard let script = Self.installer else {
            status = "安装资源缺失，请重新安装 Clio。"
            return
        }
        let uid = getuid()
        let helperPath = Self.nativeExecutable.path
        let response = await Task.detached {
            Self.run("/usr/bin/python3", ["-I", "-B", script.path, "status", "--uid", String(uid), "--helper-binary", helperPath])
        }.value
        detectProxy(response)
        apply(response, savingResult: false)
    }

    func install() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        save("正在检查已有安装…")
        guard let script = Self.installer else {
            save("安装资源缺失，请重新安装 Clio。")
            return
        }
        let uid = getuid()
        let helperPath = Self.nativeExecutable.path
        // A read-only recheck prevents authorisation for an already installed service.
        let current = await Task.detached {
            Self.run("/usr/bin/python3", ["-I", "-B", script.path, "status", "--uid", String(uid), "--helper-binary", helperPath])
        }.value
        if current.installed {
            apply(current, savingResult: true)
            return
        }
        if current.failed {
            apply(current, savingResult: true)
            return
        }
        detectProxy(current)
        let httpValue = http.trimmingCharacters(in: .whitespacesAndNewlines)
        let socksValue = socks.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.valid(httpValue, scheme: "http"), Self.valid(socksValue, scheme: "socks5h") else {
            save("未检测到可用的本机代理，请启用 HTTP 和 SOCKS5 系统代理后重试。")
            return
        }
        let response = await privileged(["/usr/bin/python3", "-I", "-B", script.path, "install", "--uid", String(uid),
                       "--http", httpValue, "--socks", socksValue, "--helper-binary", helperPath])
        apply(response, savingResult: true)
    }

    func remove() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        save("正在移除 CodexHelper…")
        guard let script = Self.installer else {
            save("安装资源缺失，请重新安装 Clio。")
            return
        }
        let uid = getuid()
        let helperPath = Self.nativeExecutable.path
        let current = await Task.detached {
            Self.run("/usr/bin/python3", ["-I", "-B", script.path, "status", "--uid", String(uid), "--helper-binary", helperPath])
        }.value
        if !current.installed || current.failed {
            apply(current, savingResult: true)
            return
        }
        let response = await privileged(["/usr/bin/python3", "-I", "-B", script.path, "remove", "--uid", String(uid), "--helper-binary", helperPath])
        apply(response, savingResult: true)
    }

    private func privileged(_ arguments: [String]) async -> Response {
        let command = arguments.map(Self.shellQuote).joined(separator: " ")
        let appleScript = "do shell script \(Self.appleQuote(command)) with administrator privileges"
        save("正在等待管理员授权…")
        return await Task.detached {
            Self.run("/usr/bin/osascript", ["-e", appleScript])
        }.value
    }

    private func apply(_ response: Response, savingResult: Bool) {
        if !response.failed { installed = response.installed }
        status = response.installed ? "辅助服务运行中" : "辅助服务未就绪"
        if savingResult { save(response.message) }
        else { status = response.message }
    }

    private func save(_ message: String) {
        result = message
        try? message.write(to: resultFile, atomically: true, encoding: .utf8)
    }

    private static func valid(_ value: String, scheme: String) -> Bool {
        guard let url = URLComponents(string: value), url.scheme == scheme,
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? ""),
              let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil else { return false }
        return true
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private struct Response: Decodable, Sendable {
        var installed: Bool
        var message: String
        var http: String?
        var socks: String?
        var ready: Bool?
        var failed: Bool = false

        enum CodingKeys: String, CodingKey { case installed, message, http, socks, ready }
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) -> Response {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let response = try? JSONDecoder().decode(Response.self, from: data) { return response }
            // Privileged shell failures include the structured install result in stderr.
            let errorText = String(decoding: errorData, as: UTF8.self)
            for line in errorText.split(separator: "\n") {
                if let start = line.firstIndex(of: "{"), let end = line.lastIndex(of: "}"),
                   let response = try? JSONDecoder().decode(Response.self, from: Data(line[start...end].utf8)) {
                    return response
                }
            }
            return Response(installed: false, message: errorText.contains("-128")
                            ? "管理员授权已取消。"
                            : "无法执行检测或安装；请确认系统 /usr/bin/python3 可用及管理员授权完成。", failed: true)
        } catch {
            return Response(installed: false, message: "无法启动系统安装工具。", failed: true)
        }
    }
}
