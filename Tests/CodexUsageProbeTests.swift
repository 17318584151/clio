import Foundation

@main
enum CodexUsageProbeTests {
    static func parse(_ json: String) -> CodexUsageProbe.Reading? {
        CodexUsageProbe.parse(Data(json.utf8), at: Date(timeIntervalSince1970: 1000))
    }

    static func main() throws {
        let zero = parse(#"{"rateLimits":{"planType":"prolite","primary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":2000}},"rateLimitResetCredits":{"availableCount":0}}"#)!
        precondition(zero.remainingResets == 0 && zero.plan == "Pro 5×")
        precondition(zero.quota?.sevenDay?.usedPercentage == 30 && zero.quota?.fiveHour == nil)
        precondition(zero.quota?.sevenDay?.resetsAt == Date(timeIntervalSince1970: 2000))
        let mapped = parse(#"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":10080}},"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":42,"windowDurationMins":300},"secondary":{"usedPercent":16,"windowDurationMins":10080}}},"rateLimitResetCredits":{"availableCount":7,"credits":[]}}"#)!
        precondition(mapped.remainingResets == 7 && mapped.plan == "Pro 20×")
        precondition(mapped.quota?.fiveHour?.usedPercentage == 42 && mapped.quota?.sevenDay?.usedPercentage == 16)
        for json in ["{}", #"{"rateLimitResetCredits":null}"#,
                     #"{"rateLimitResetCredits":{"availableCount":null}}"#,
                     #"{"rateLimitResetCredits":{"availableCount":-1}}"#] {
            precondition(parse(json)?.remainingResets == nil)
        }
        precondition(parse(#"{"rateLimitResetCredits":{"availableCount":false}}"#) == nil)
        precondition(parse("not json") == nil)
        let expired = parse(#"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":500}},"rateLimitResetCredits":{"availableCount":2}}"#)!
        precondition(expired.quota == nil && expired.remainingResets == 2)
        let missingShort = parse(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":10080},"secondary":null}}"#)!
        precondition(missingShort.quota?.fiveHour == nil && missingShort.quota?.sevenDay?.usedPercentage == 25)
        let snapshot = DashboardBuilder.snapshot(tool: .codex, events: [], rejections: [],
            prices: PriceTable(prices: [:]), quota: .init(planName: mapped.plan, rateLimits: mapped.quota,
                                                       remainingResets: mapped.remainingResets))
        precondition(snapshot.remainingResets == 7 && snapshot.menuBarQuota.fraction == 0.42)
        precondition(CodexUsageProbe.fetch(executable: nil) == nil)
        precondition(CodexUsageProbe.fetch(executable: URL(fileURLWithPath: "/does-not-exist/codex")) == nil)

        let root = FileManager.default.temporaryDirectory.appending(path: "clio-codex-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for scenario in ["success", "logged-out", "api-key", "error", "eof", "timeout"] {
            let script = root.appending(path: scenario)
            let audit = root.appending(path: "\(scenario).jsonl")
            let code = """
            #!/usr/bin/python3
            import json, signal, sys, time
            scenario = '\(scenario)'
            audit = '\(audit.path)'
            if scenario == 'eof':
                sys.exit(0)
            if scenario == 'timeout':
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                time.sleep(60)
            for line in sys.stdin:
                request = json.loads(line)
                with open(audit, 'a') as stream:
                    stream.write(json.dumps(request) + '\\n')
                method = request['method']
                if method == 'initialized':
                    continue
                if method == 'initialize':
                    result = {}
                elif method == 'account/read':
                    result = {'account': None if scenario == 'logged-out' else {'type': 'apiKey' if scenario == 'api-key' else 'chatgpt'}}
                elif method == 'account/rateLimits/read':
                    if scenario == 'error':
                        print(json.dumps({'id': request['id'], 'error': {'code': -1, 'message': 'unavailable'}}), flush=True)
                        continue
                    result = {'rateLimits': {'planType': 'prolite', 'primary': {'usedPercent': 30, 'windowDurationMins': 10080}}, 'rateLimitResetCredits': {'availableCount': 0}}
                else:
                    raise AssertionError(method)
                print(json.dumps({'method': 'account/updated', 'params': {}}), flush=True)
                response = json.dumps({'id': request['id'], 'result': result})
                sys.stdout.write(response[:5])
                sys.stdout.flush()
                time.sleep(.01)
                sys.stdout.write(response[5:] + '\\n')
                sys.stdout.flush()
            """
            try code.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let started = Date()
            let result = CodexUsageProbe.fetch(executable: script, timeout: scenario == "timeout" ? 0.3 : 3)
            precondition(Date().timeIntervalSince(started) < 4)
            if scenario == "success" {
                precondition(result?.remainingResets == 0 && result?.quota?.sevenDay?.usedPercentage == 30)
            } else {
                precondition(result == nil, "\(scenario) must not appear as zero resets")
            }
            if ["success", "logged-out", "api-key", "error"].contains(scenario) {
                let requests = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map {
                    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
                }
                let methods = requests.map { $0["method"] as! String }
                let expected = ["initialize", "initialized", "account/read"]
                    + (["success", "error"].contains(scenario) ? ["account/rateLimits/read"] : [])
                precondition(methods == expected, "Only read-only account requests are permitted")
                let client = ((requests[0]["params"] as! [String: Any])["clientInfo"] as! [String: Any])
                precondition(client["name"] as? String == "clio")
            }
        }
        print("Codex account query checks passed: parsing, local login, read-only protocol, errors and bounded timeout")
        if CommandLine.arguments.contains("--live") {
            guard let live = CodexUsageProbe.fetch() else { fatalError("Local Codex account query failed") }
            print("Live Codex: \(live.plan ?? "unknown plan"), resets \(live.remainingResets.map { String($0) } ?? "unknown"), weekly usage \(live.quota?.sevenDay?.usedPercentage.map { String($0) } ?? "unknown")")
        }
    }
}
