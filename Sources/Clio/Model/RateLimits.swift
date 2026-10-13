import Foundation

/// One quota window reported by a tool.
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

/// The quota state reported by a tool.
struct RateLimitSnapshot: Codable, Equatable {
    var updatedAt: Date
    var fiveHour: RateLimitWindow?
    var sevenDay: RateLimitWindow?
    var modelScoped: [ScopedRateLimitWindow]

    /// Within one reset window, delayed reports cannot lower utilisation.
    func stabilized(against previous: RateLimitSnapshot?, now: Date, allowsDecrease: Bool = false) -> RateLimitSnapshot {
        guard let previous, !allowsDecrease else { return self }
        func window(_ current: RateLimitWindow?, _ old: RateLimitWindow?) -> RateLimitWindow? {
            guard var current, let old, let oldReset = old.resetsAt,
                  old.isCurrent(at: now) else { return current }
            guard let reset = current.resetsAt else { return old }
            if reset < oldReset.addingTimeInterval(-1) { return old }
            if abs(reset.timeIntervalSince(oldReset)) <= 1 {
                current.usedPercentage = [current.usedPercentage, old.usedPercentage].compactMap { $0 }.max()
            }
            return current
        }
        var result = self
        result.fiveHour = window(fiveHour, previous.fiveHour)
        result.sevenDay = window(sevenDay, previous.sevenDay)
        result.modelScoped = modelScoped.map { current in
            guard let old = previous.modelScoped.first(where: { $0.displayName == current.displayName }),
                  let resolved = window(.init(usedPercentage: current.utilization, resetsAt: current.resetsAt),
                                        .init(usedPercentage: old.utilization, resetsAt: old.resetsAt)) else { return current }
            return ScopedRateLimitWindow(displayName: current.displayName,
                                         utilization: resolved.usedPercentage, resetsAt: resolved.resetsAt)
        }
        return result
    }

    /// Selects a complete snapshot; windows absent from it stay absent.
    static func latest(_ sources: [RateLimitSnapshot], now: Date, maxAge: TimeInterval) -> RateLimitSnapshot? {
        guard var result = sources.filter({ now.timeIntervalSince($0.updatedAt) < maxAge })
            .max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        if result.fiveHour?.isCurrent(at: now) == false { result.fiveHour = nil }
        if result.sevenDay?.isCurrent(at: now) == false { result.sevenDay = nil }
        result.modelScoped = result.modelScoped.filter { $0.isCurrent(at: now) }
        guard result.fiveHour != nil || result.sevenDay != nil || !result.modelScoped.isEmpty else { return nil }
        return result
    }

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
