import SwiftUI

struct AccountQuotaCard: View {
    let accounts: [AccountQuota]
    let queryingAccountIDs: Set<String>
    let orca: OrcaAccounts?
    var switchingAccountID: String? = nil
    var switchErrors: [String: String] = [:]
    var onSwitch: (QuotaAccount) -> Void = { _ in }

    var body: some View {
        Card(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, reading in
                        if index > 0 {
                            Divider().padding(.vertical, 8)
                        }
                        let isActive = orca?.active.contains(reading.id) == true
                        AccountQuotaRow(reading: reading, isQuerying: queryingAccountIDs.contains(reading.id),
                                        isOrca: isActive,
                                        canSwitch: !isActive && orca?.targets[reading.id] != nil,
                                        isSwitching: switchingAccountID == reading.id,
                                        switchError: switchErrors[reading.id]) { onSwitch(reading.account) }
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
    let canSwitch: Bool
    let isSwitching: Bool
    let switchError: String?
    let onSwitch: () -> Void
    @State private var isHovering = false
    @Environment(\.theme) private var theme

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
                window("5 小时已用", \.fiveHour)
                window("本周已用", \.sevenDay)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(details)
        .contextMenu {
            if canSwitch { Button("在 Orca 中使用此账号", action: onSwitch) }
        }
    }

    /// The switch button takes the update time's place on hover, so nothing shifts.
    private var trailing: some View {
        let showsSwitch = canSwitch && isHovering && !isSwitching
        return ZStack(alignment: .trailing) {
            Text(switchError != nil ? "切换失败"
                 : reading.quota.map { "更新 \(Format.quotaTime($0.updatedAt))" } ?? reading.status)
                .font(.system(size: 9)).monospacedDigit()
                .foregroundStyle(switchError != nil ? theme.danger : theme.textSecondary)
                .lineLimit(1).fixedSize()
                .opacity(showsSwitch || isQuerying || isSwitching ? 0 : 1)
            if isQuerying || isSwitching {
                ProgressView().controlSize(.mini)
            } else if canSwitch {
                Button(action: onSwitch) {
                    Text("切换")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(theme.segmentedFill, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(showsSwitch ? 1 : 0)
                .allowsHitTesting(showsSwitch)
                .help("让 Orca 之后启动的 \(reading.account.tool.displayName) 使用此账号，已运行的会话不受影响")
                .accessibilityLabel("在 Orca 中使用 \(reading.account.name)")
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
        if isOrca { lines.append("Orca 当前使用此账号启动 \(reading.account.tool.displayName)") }
        if let switchError { lines.append("切换失败：\(switchError)") }
        if let quota = reading.quota { lines.append("数据获取于 \(Format.stamp(quota.updatedAt))") }
        else if reading.account.tool != .codex {
            lines.append("在设置中接入状态栏后，运行 \(reading.account.tool == .antigravity ? "agy" : "Claude Code") 即可更新")
        }
        for (title, window) in [("5 小时", \RateLimitSnapshot.fiveHour), ("本周", \.sevenDay)] {
            if let reset = reading.resetDate(window) { lines.append("\(title)重置于 \(Format.stamp(reset))") }
        }
        if let count = reading.remainingResets { lines.append("剩余重置次数 \(count) 次") }
        lines.append(reading.account.directory.path)
        return lines.joined(separator: "\n")
    }

    private func window(_ title: String, _ window: KeyPath<RateLimitSnapshot, RateLimitWindow?>) -> some View {
        let reset = reading.resetDate(window)
        let used = reading.fraction(window)
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
            Text(reset.map { $0 > Date() ? "\(Format.reset($0))重置" : "已重置，待更新" } ?? "重置时间未知")
                .font(.system(size: 9)).monospacedDigit()
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}

@MainActor
extension AccountQuota {
    /// The used share of one window as shown in the card and the menu bar.
    func fraction(_ window: KeyPath<RateLimitSnapshot, RateLimitWindow?>) -> Double? {
        quota?[keyPath: window].flatMap {
            displayedFraction($0, codexQueryInterval: Preferences.shared.codexQuotaInterval)
        }
    }
}
