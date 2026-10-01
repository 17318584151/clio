import Foundation

/// Reads `~/.codex/sessions/**/*.jsonl`.
///
/// Codex records a `token_count` event per turn; `last_token_usage` is that
/// turn's delta while `total_token_usage` is the session running total, so only
/// the delta is accumulated. `input_tokens` there already includes the cached
/// portion reported separately as `cached_input_tokens`.
///
/// A `token_count` line also carries `rate_limits`: `used_percent` and
/// `resets_at` for each window. A window of a day or longer is the weekly
/// allowance (10080 minutes). Shorter ones, when Codex sends them, are the
/// 5-hour allowance. The newest reading wins; a line with no windows does not
/// erase it. Nothing is asked of the network.
///
/// The shape below is the Codex CLI rollout format. Fields are read defensively
/// and a line that doesn't match is skipped rather than failing the scan.
final class CodexReader {
    struct Reading {
        var events: [UsageEvent]
        var quota: RateLimitSnapshot?
        var plan: String?
    }

    private let scanner = LogScanner(root: Tool.codex.logDirectory)
    private var events: [String: UsageEvent] = [:]
    /// Latest model named in each session file. Subagent sessions log a
    /// different model alongside their parent, so it is not shared across files.
    private var models: [String: String] = [:]
    /// Latest `total_token_usage` seen in each session file.
    private var totals: [String: Int] = [:]
    /// Newest quota snapshot seen in any session file.
    private var quota: RateLimitSnapshot?
    private var planName: String?

    var isAvailable: Bool { scanner.rootExists }

    /// `token_count` lines carry usage but no model; the model is named by the
    /// `turn_context` line that opens each turn.
    private static let usageMarker = Array("token_count".utf8)
    private static let contextMarker = Array("turn_context".utf8)

    func refresh(now: Date = Date()) -> Reading {
        scanner.scan { file, line in
            guard ByteSearch.contains(line, Self.usageMarker)
                    || ByteSearch.contains(line, Self.contextMarker) else { return }
            guard let base = line.baseAddress else { return }
            let data = Data(bytes: base, count: line.count)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            ingest(object, file: file)
        }
        let cutoff = now.addingTimeInterval(-LogScanner.retention)
        events = events.filter { $0.value.timestamp > cutoff }
        return Reading(events: Array(events.values), quota: currentQuota(at: now), plan: planName)
    }

    private func ingest(_ object: [String: Any], file: String) {
        let payload = object["payload"] as? [String: Any] ?? [:]

        // Any line that names a model updates what later turns are attributed to.
        if let model = payload["model"] as? String, !model.isEmpty {
            models[file] = model
        }

        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any]
        else { return }

        let stamp = (object["timestamp"] as? String) ?? ""
        let timestamp = ISO8601.date(from: stamp)
        if let timestamp { noteQuota(payload["rate_limits"], at: timestamp) }

        guard let last = info["last_token_usage"] as? [String: Any] else { return }

        if let model = info["model"] as? String, !model.isEmpty {
            models[file] = model
        }
        let currentModel = models[file] ?? "codex"

        // An event that leaves the session total unchanged is not a request:
        // Codex repeats the last one, and reports the context size after compaction.
        if let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int {
            guard total != totals[file] else { return }
            totals[file] = total
        }

        guard let timestamp else { return }

        let input = last["input_tokens"] as? Int ?? 0
        let cached = last["cached_input_tokens"] as? Int ?? 0
        var counts = TokenCounts()
        counts.input = max(0, input - cached)
        counts.cacheRead = cached
        counts.output = last["output_tokens"] as? Int ?? 0

        guard counts.total > 0 else { return }
        let key = "\(stamp)|\(currentModel)|\(counts.input)|\(counts.output)|\(counts.cacheRead)"
        guard events[key] == nil else { return }
        events[key] = UsageEvent(timestamp: timestamp, model: currentModel, counts: counts, dedupeKey: key)
    }

    /// A day or longer is the weekly allowance. Anything shorter is the 5-hour
    /// one. Codex currently sends only the 7-day window (`10080` minutes) on
    /// `primary` and leaves `secondary` empty.
    private func noteQuota(_ value: Any?, at timestamp: Date) {
        guard let limits = value as? [String: Any] else { return }
        if let existing = quota?.updatedAt, timestamp <= existing { return }

        var fiveHour: RateLimitWindow?
        var week: RateLimitWindow?
        for key in ["primary", "secondary"] {
            guard let entry = limits[key] as? [String: Any],
                  let window = Self.quotaWindow(entry)
            else { continue }
            let minutes = Self.number(entry["window_minutes"]) ?? 0
            if minutes >= 24 * 60 {
                week = window
            } else if minutes > 0 {
                fiveHour = window
            }
        }
        guard fiveHour != nil || week != nil else { return }
        quota = RateLimitSnapshot(updatedAt: timestamp,
                                  fiveHour: fiveHour,
                                  sevenDay: week,
                                  modelScoped: [])
        if let plan = limits["plan_type"] as? String {
            planName = PlanReader.displayName(for: plan)
        }
    }

    /// Drop a window whose reset time has passed. The next `token_count` is
    /// what replaces it; until then the old percentage belongs to a closed week.
    private func currentQuota(at now: Date) -> RateLimitSnapshot? {
        guard var snap = quota else { return nil }
        if let week = snap.sevenDay, !week.isCurrent(at: now) { snap.sevenDay = nil }
        if let five = snap.fiveHour, !five.isCurrent(at: now) { snap.fiveHour = nil }
        guard snap.fiveHour != nil || snap.sevenDay != nil else { return nil }
        return snap
    }

    private static func quotaWindow(_ entry: [String: Any]) -> RateLimitWindow? {
        guard let percent = number(entry["used_percent"]) else { return nil }
        return RateLimitWindow(usedPercentage: percent, resetsAt: date(entry["resets_at"]))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: Double(seconds)) }
        if let text = value as? String { return ISO8601.date(from: text) }
        return nil
    }
}
