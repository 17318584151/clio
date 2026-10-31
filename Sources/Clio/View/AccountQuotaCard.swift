import SwiftUI

struct AccountQuotaCard: View {
    let accounts: [AccountQuota]
    @Environment(\.theme) private var theme

    var body: some View {
        Card(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, reading in
                        if index > 0 {
                            Divider().padding(.vertical, 8)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                BrandIcon(tool: reading.account.tool, size: 14,
                                          color: reading.account.tool.brandColor ?? theme.textPrimary)
                                Text(reading.account.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1).truncationMode(.middle)
                                    .help(details(reading))
                                Spacer()
                                if let plan = reading.plan { PlanBadge(text: plan) }
                            }
                            HStack(spacing: 12) {
                                if let fiveHour = reading.quota?.fiveHour {
                                    window("5 小时已用", fiveHour, at: reading.quota?.updatedAt, tool: reading.account.tool)
                                }
                                if let week = reading.quota?.sevenDay {
                                    window("本周已用", week, at: reading.quota?.updatedAt, tool: reading.account.tool)
                                }
                            }
                            .help(details(reading))
                            if reading.quota?.fiveHour == nil && reading.quota?.sevenDay == nil {
                                Text(reading.status == "尚未查询" ? "额度查询中…" : "额度未知")
                                    .foregroundStyle(theme.textSecondary)
                                    .help(details(reading))
                            }
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(accounts.count) * 62 + CGFloat(max(0, accounts.count - 1)) * 17, 360))
        }
        .font(.system(size: 11))
    }

    private func details(_ reading: AccountQuota) -> String {
        var lines = [reading.account.tool.displayName, reading.account.name, reading.status]
        if let quota = reading.quota { lines.append("数据获取于 \(Format.stamp(quota.updatedAt))") }
        if let count = reading.remainingResets { lines.append("剩余重置次数 \(count) 次") }
        lines.append(reading.account.directory.path)
        return lines.joined(separator: "\n")
    }

    private func window(_ title: String, _ value: RateLimitWindow?, at updatedAt: Date?, tool: Tool) -> some View {
        let valid = updatedAt.map { Date().timeIntervalSince($0) < Preferences.shared.queryInterval(for: tool) * 2 } ?? false
        let used = valid && value?.isCurrent(at: Date()) == true ? value?.fraction : nil
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(theme.textSecondary)
                Spacer()
                Text(used.map(Format.percent) ?? "未知").monospacedDigit()
            }
            GeometryReader { geometry in
                Capsule().fill(theme.track)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(theme.quotaColor(used))
                            .frame(width: geometry.size.width * (used ?? 0))
                    }
            }
            .frame(height: 3)
            HStack(spacing: 4) {
                Text(updatedAt.map { "更新 \(Format.quotaTime($0))" } ?? "更新时间未知")
                Spacer(minLength: 0)
                Text(value?.resetsAt.map { $0 > Date() ? "\(Format.reset($0))重置" : "已重置，待更新" } ?? "重置时间未知")
            }
            .font(.system(size: 9)).monospacedDigit()
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .help([title,
               updatedAt.map { "数据获取于 \(Format.stamp($0))" } ?? "更新时间未知",
               value?.resetsAt.map { "重置于 \(Format.stamp($0))" } ?? "重置时间未知"].joined(separator: "\n"))
    }
}
