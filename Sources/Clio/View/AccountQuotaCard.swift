import SwiftUI

struct AccountQuotaCard: View {
    let accounts: [AccountQuota]
    let queryingAccountIDs: Set<String>
    let orcaAccountID: String?
    let onRefresh: (QuotaAccount) -> Void
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
                                if reading.id == orcaAccountID { orcaBadge }
                                Spacer(minLength: 4)
                                if let quota = reading.quota {
                                    Text("更新 \(Format.quotaTime(quota.updatedAt))")
                                        .font(.system(size: 9)).monospacedDigit()
                                        .foregroundStyle(theme.textSecondary)
                                        .lineLimit(1).fixedSize()
                                }
                                if let plan = reading.plan { PlanBadge(text: plan) }
                                // agy only reports quota through its status line; there is nothing to query.
                                if reading.account.tool != .antigravity { refreshButton(reading.account) }
                            }
                            if reading.quota?.fiveHour != nil || reading.quota?.sevenDay != nil {
                                HStack(spacing: 12) {
                                    window("5 小时已用", reading.quota?.fiveHour, reading: reading)
                                    window("本周已用", reading.quota?.sevenDay, reading: reading)
                                }
                                .help(details(reading))
                            } else {
                                Text(queryingAccountIDs.contains(reading.id) ? "额度查询中…"
                                     : reading.account.tool == .antigravity ? "额度未知，接入状态栏后运行 agy 更新" : "额度未知")
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

    private var orcaBadge: some View {
        Text("Orca")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
            .help("Orca 当前使用此账号启动 Claude Code")
            .accessibilityLabel("Orca 当前使用此账号")
    }

    private func refreshButton(_ account: QuotaAccount) -> some View {
        let isQuerying = queryingAccountIDs.contains(account.id)
        return Button { onRefresh(account) } label: {
            Group {
                if isQuerying {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.accent)
                }
            }
            .frame(width: 20, height: 20)
            .background(theme.segmentedFill, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isQuerying)
        .help("手动刷新 \(account.name) 的额度（会联网查询）")
        .accessibilityLabel("\(account.name)：\(isQuerying ? "额度查询中" : "手动刷新额度")")
    }

    private func details(_ reading: AccountQuota) -> String {
        var lines = [reading.account.tool.displayName, reading.account.name, reading.status]
        if reading.id == orcaAccountID { lines.append("Orca 当前使用此账号") }
        if let quota = reading.quota { lines.append("数据获取于 \(Format.stamp(quota.updatedAt))") }
        if let count = reading.remainingResets { lines.append("剩余重置次数 \(count) 次") }
        lines.append(reading.account.directory.path)
        return lines.joined(separator: "\n")
    }

    private func window(_ title: String, _ value: RateLimitWindow?, reading: AccountQuota) -> some View {
        let used = value.flatMap { reading.displayedFraction($0,
            automaticClaudeQueries: Preferences.shared.automaticClaudeQuotaQueries,
            queryInterval: Preferences.shared.queryInterval(for: reading.account.tool)) }
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
            Text(value?.resetsAt.map { $0 > Date() ? "\(Format.reset($0))重置" : "已重置，待更新" } ?? "重置时间未知")
                .font(.system(size: 9)).monospacedDigit()
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .help([title,
               value?.resetsAt.map { "重置于 \(Format.stamp($0))" } ?? "重置时间未知"].joined(separator: "\n"))
    }
}
