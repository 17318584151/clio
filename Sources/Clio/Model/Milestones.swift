import Foundation

/// The last observed 100M floor for each period, persisted so a crossing is
/// celebrated once and never replayed after a restart.
struct MilestoneState: Codable, Equatable {
    var tools: [String: ToolState]

    struct ToolState: Codable, Equatable {
        var dayID: String
        var dayFloor: Int
        var weekID: String
        var weekFloor: Int
        var monthID: String
        var monthFloor: Int
    }
}

enum Milestones {
    static let step = 100_000_000

    static func periodIDs(_ date: Date, calendar: Calendar = .current) -> (day: String, week: String, month: String) {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear, .year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let week = String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
        let month = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        return (day, week, month)
    }

    static func state(snapshots: [ToolSnapshot], at date: Date) -> MilestoneState {
        let ids = periodIDs(date)
        var tools: [String: MilestoneState.ToolState] = [:]
        for snapshot in snapshots {
            tools[snapshot.tool.rawValue] = .init(
                dayID: ids.day,
                dayFloor: (snapshot.totals[.day]?.total ?? 0) / step,
                weekID: ids.week,
                weekFloor: (snapshot.totals[.week]?.total ?? 0) / step,
                monthID: ids.month,
                monthFloor: (snapshot.totals[.month]?.total ?? 0) / step)
        }
        return MilestoneState(tools: tools)
    }

    /// Fire when any period reached a higher 100M floor *within the same
    /// period* for the same tool. Each tool's first observation establishes a
    /// baseline without celebrating its existing usage.
    static func shouldCelebrate(previous: MilestoneState?, current: MilestoneState) -> Bool {
        guard let previous else { return false }
        return current.tools.contains { tool, state in
            guard let old = previous.tools[tool] else { return false }
            let dayCrossed = old.dayID == state.dayID && state.dayFloor > old.dayFloor
            let weekCrossed = old.weekID == state.weekID && state.weekFloor > old.weekFloor
            let monthCrossed = old.monthID == state.monthID && state.monthFloor > old.monthFloor
            return dayCrossed || weekCrossed || monthCrossed
        }
    }

    /// Keep the stored floors monotonic inside a period so a partial read can't
    /// regress the snapshot and re-fire the same milestone later.
    static func merged(previous: MilestoneState?, current: MilestoneState) -> MilestoneState {
        guard let previous else { return current }
        var next = previous
        for (tool, state) in current.tools {
            var merged = state
            if let old = previous.tools[tool] {
                if old.dayID == state.dayID { merged.dayFloor = max(state.dayFloor, old.dayFloor) }
                if old.weekID == state.weekID { merged.weekFloor = max(state.weekFloor, old.weekFloor) }
                if old.monthID == state.monthID { merged.monthFloor = max(state.monthFloor, old.monthFloor) }
            }
            next.tools[tool] = merged
        }
        return next
    }
}
