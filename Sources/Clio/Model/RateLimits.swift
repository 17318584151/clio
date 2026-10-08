import Foundation

/// One quota window as Claude Code reports it.
struct RateLimitWindow: Codable, Equatable {
    /// 0–100 as reported upstream.
    var usedPercentage: Double?
    var resetsAt: Date?

    var fraction: Double? {
        usedPercentage.map { min(1, max(0, $0 / 100)) }
    }

    /// False once the reset time has passed: the figure then belongs to the
    /// window that ended. A reading without a reset time can't be judged.
    func isCurrent(at now: Date) -> Bool {
        resetsAt.map { $0 > now } ?? true
    }
}

/// A model-scoped weekly allowance, e.g. the Fable window.
struct ScopedRateLimitWindow: Codable, Equatable {
    var displayName: String
    var utilization: Double?
    var resetsAt: Date?

    var fraction: Double? {
        utilization.map { min(1, max(0, $0 / 100)) }
    }

    func isCurrent(at now: Date) -> Bool {
        resetsAt.map { $0 > now } ?? true
    }
}

/// The real quota state, as Claude Code reports it.
struct RateLimitSnapshot: Codable, Equatable {
    var updatedAt: Date
    var fiveHour: RateLimitWindow?
    var sevenDay: RateLimitWindow?
    var modelScoped: [ScopedRateLimitWindow]

    /// The quota state to show, from every source at hand. A reading older
    /// than `maxAge` is left out. An expired 5-hour window is retained only
    /// as a reset boundary, so the dashboard can start its usage at zero.
    /// Of the rest, the newest reading wins window by window, so a source
    /// lacking a window doesn't erase what another still reports.
    static func merged(_ sources: [RateLimitSnapshot], now: Date, maxAge: TimeInterval) -> RateLimitSnapshot? {
        let ordered = sources.sorted { $0.updatedAt > $1.updatedAt }
        let usable = ordered
            .filter { now.timeIntervalSince($0.updatedAt) < maxAge }
        guard var result = usable.first ?? ordered.first(where: { $0.fiveHour?.isCurrent(at: now) == false })
        else { return nil }
        result.fiveHour = usable.lazy.compactMap(\.fiveHour).first { $0.isCurrent(at: now) }
            ?? ordered.lazy.compactMap(\.fiveHour).first { !$0.isCurrent(at: now) }
        result.sevenDay = usable.lazy.compactMap(\.sevenDay).first { $0.isCurrent(at: now) }
        result.modelScoped = usable.lazy
            .map { $0.modelScoped.filter { $0.isCurrent(at: now) } }
            .first { !$0.isEmpty } ?? []
        return result
    }
}
