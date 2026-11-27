import SwiftUI

struct AccountQuotaCard: View {
    let accounts: [AccountQuota]
    let queryingAccountIDs: Set<String>
    let orcaAccountID: String?
    let onRefresh: (QuotaAccount) -> Void

    var body: some View {
        Card(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, reading in
                        if index > 0 {
                            Divider().padding(.vertical, 8)
                        }
                        AccountQuotaRow(reading: reading, isQuerying: queryingAccountIDs.contains(reading.id),
                                        isOrca: reading.id == orcaAccountID) { onRefresh(reading.account) }
                    }
                }
            }
            // Five accounts fit without scrolling.
            .frame(height: min(CGFloat(accounts.count) * 62 + CGFloat(max(0, accounts.count - 1)) * 17, 380))
        }
        .font(.system(size: 11))
    }
}

/// Every account keeps the same shape, known or not, so the rows line up.
private struct AccountQuotaRow: View {
    let reading: AccountQuota
    let isQuerying: Bool
    let isOrca: Bool
    let onRefresh: () -> Void
    @State private var isHovering = false
    @Environment(\.theme) private var theme

    /// agy only reports quota through its status line; there is nothing to query.
    private var canRefresh: Bool { reading.account.tool != .antigravity }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                BrandIcon(tool: reading.account.tool, size: 14,
                          color: reading.account.tool.brandColor ?? theme.textPrimary)
                Text(reading.account.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                if isOrca { tag("Orca", color: theme.accent) }
                if let plan = reading.plan { tag(plan, color: theme.badgeText) }
                Spacer(minLength: 6)
                trailing
            }
            .frame(height: 20)
            HStack(spacing: 12) {
                window("5 小时已用", reading.quota?.fiveHour)
                window("本周已用", reading.quota?.sevenDay)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(details)
    }

    /// The update time gives way to the refresh button on hover, in the same space.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            Text(reading.quota.map { "更新 \(Format.quotaTime($0.updatedAt))" } ?? reading.status)
                .font(.system(size: 9)).monospacedDigit()
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1).fixedSize()
                .opacity(isQuerying || (isHovering && canRefresh) ? 0 : 1)
            if isQuerying {
                ProgressView().controlSize(.mini).frame(width: 20, height: 20)
            } else if canRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .frame(width: 20, height: 20)
                        .background(theme.segmentedFill, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .help("手动刷新 \(reading.account.name) 的额度（会联网查询）")
                .accessibilityLabel("\(reading.account.name)：手动刷新额度")
            }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
    }

    private var details: String {
        var lines = [reading.account.tool.displayName, reading.account.name, reading.status]
        if isOrca { lines.append("Orca 当前使用此账号") }
        if let quota = reading.quota { lines.append("数据获取于 \(Format.stamp(quota.updatedAt))") }
        else if !canRefresh { lines.append("在设置中接入状态栏后，运行 agy 即可更新") }
        for (title, window) in [("5 小时", reading.quota?.fiveHour), ("本周", reading.quota?.sevenDay)] {
            if let reset = window?.resetsAt { lines.append("\(title)重置于 \(Format.stamp(reset))") }
        }
        if let count = reading.remainingResets { lines.append("剩余重置次数 \(count) 次") }
        lines.append(reading.account.directory.path)
        return lines.joined(separator: "\n")
    }

    private func window(_ title: String, _ value: RateLimitWindow?) -> some View {
        let used = value.flatMap { reading.displayedFraction($0,
            automaticClaudeQueries: Preferences.shared.automaticClaudeQuotaQueries,
            queryInterval: Preferences.shared.queryInterval(for: reading.account.tool)) }
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(theme.textSecondary)
                Spacer()
                Text(used.map(Format.percent) ?? "未知").monospacedDigit()
                    .foregroundStyle(used == nil ? theme.textSecondary : theme.textPrimary)
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
            Text(value?.resetsAt.map { $0 > Date() ? "\(Format.reset($0))重置" : "已重置，待更新" } ?? "重置时间未知")
                .font(.system(size: 9)).monospacedDigit()
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}
