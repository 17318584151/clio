import Foundation

@main
enum UsageProbeTests {
    static func main() throws {
        precondition(UsageProbe.fetch(executable: nil) == nil)
        precondition(UsageProbe.fetch(executable: URL(fileURLWithPath: "/does-not-exist/claude")) == nil)
        let root = FileManager.default.temporaryDirectory.appending(path: "clio-claude-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for scenario in ["success", "missing-cache", "stale-cache", "wrong-account", "error", "timeout"] {
            let directory = root.appending(path: scenario)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let profile = directory.appending(path: ".claude.json")
            try Data(#"{"oauthAccount":{"accountUuid":"fixture"}}"#.utf8).write(to: profile)
            let script = directory.appending(path: "claude")
            let code = """
            #!/usr/bin/python3
            import json, os, signal, sys, time
            assert sys.argv[1:] == ['-p', '/usage', '--output-format', 'json', '--tools', '',
                                    '--strict-mcp-config', '--setting-sources', '', '--no-session-persistence']
            assert os.environ['CLAUDE_CONFIG_DIR'] == '\(directory.path)'
            assert os.environ['USER'] and os.environ['HOME']
            assert not os.environ.get('ANTHROPIC_API_KEY')
            assert not os.environ.get('CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC')
            assert os.environ['CLAUDE_CODE_DISABLE_AUTO_MEMORY'] == '1'
            assert sys.stdin.read() == ''
            scenario = '\(scenario)'
            if scenario == 'timeout':
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                time.sleep(60)
            if scenario != 'missing-cache':
                with open('\(profile.path)') as stream:
                    doc = json.load(stream)
                doc['cachedUsageUtilization'] = {
                    'accountUuid': 'other' if scenario == 'wrong-account' else 'fixture',
                    'fetchedAtMs': (time.time() - (7200 if scenario == 'stale-cache' else 60)) * 1000,
                    'utilization': {'seven_day': {'utilization': 24, 'resets_at': time.time() + 3600}}
                }
                with open('\(profile.path)', 'w') as stream:
                    json.dump(doc, stream)
            # Output is not the data source, and must not block the child.
            sys.stdout.write('x' * 200000)
            sys.exit(1 if scenario == 'error' else 0)
            """
            try code.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let started = Date()
            let quota = UsageProbe.fetch(executable: script, timeout: scenario == "timeout" ? 0.3 : 3,
                                         configDirectory: directory)
            precondition(Date().timeIntervalSince(started) < 4, "CLI timeout must be bounded even if SIGTERM is ignored")
            if scenario == "success" {
                precondition(quota?.sevenDay?.usedPercentage == 24, "query runs /usage and reads the account cache")
                precondition((55...65).contains(Date().timeIntervalSince(quota!.updatedAt)),
                             "cache timestamp must remain the CLI's original fetch time")
            } else {
                precondition(quota == nil, "\(scenario) must not report a successful quota refresh")
            }
        }
        print("Claude CLI checks passed: /usage arguments, account isolation, cache freshness, errors and timeout")
        if CommandLine.arguments.contains("--live") {
            let quota = UsageProbe.fetch()
            precondition(quota != nil, "installed Claude CLI must refresh and expose valid quota cache")
            print("Installed Claude CLI /usage check passed")
        }
    }
}
