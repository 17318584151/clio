import SwiftUI
import AppKit

/// The popover, showing subscription quotas and combined or per-tool usage.
struct PanelView: View {
    var onOpenSettings: () -> Void
    var initialGranularity: Granularity = .day
    /// Reports the height the content needs. The panel window follows it: the
    /// period switch and a refresh both change how many model rows there are.
    var onContentHeight: (CGFloat) -> Void = { _ in }

    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var updater = Updater.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.panelIsOpen) private var panelIsOpen
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var granularity: Granularity = .day
    @State private var isDatePickerPresented = false
    @State private var customRange: UsageDateRange?
    @State private var basis: ShareBasis = .tokens
    @State private var didApplyInitial = false

    private var theme: Theme { Theme.resolve(scheme) }
    /// Off-screen rendering can't draw the material, so snapshots keep the fills.
    private var usesGlass: Bool { LiquidGlass.isAvailable && !isSnapshot }

    var body: some View {
        Group {
            if store.isLoading && store.accountQuotas.isEmpty {
                LoadingView()
            } else if !store.dashboard.isEmpty || !store.accountQuotas.isEmpty {
                content(store.dashboard)
            } else {
                EmptyStateView(onRescan: { Task { await store.refresh() } },
                               onSettings: onOpenSettings)
            }
        }
        .blur(radius: panelIsOpen ? 0 : 10)
        .environment(\.theme, usesGlass ? theme.onGlass : theme)
        .environment(\.liquidGlass, usesGlass)
        .frame(width: Metrics.panelWidth)
        // Translucent fill over the window's blurred backdrop, plus the two
        // hairlines the design gives the glass edge: light inside, dark on it.
        // Liquid Glass draws its own edge and needs neither.
        .background(usesGlass ? .clear : theme.panelFill,
                    in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
        .background {
            Color.clear.liquidGlass(usesGlass,
                                    in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous),
                                    tint: theme.glassTint)
        }
        .overlay {
            if !usesGlass {
                RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                    .inset(by: 0.25)
                    .strokeBorder(theme.panelInnerStroke, lineWidth: 0.5)
            }
        }
        .overlay {
            if !usesGlass {
                RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                    .strokeBorder(theme.panelStroke, lineWidth: 0.5)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                    onContentHeight(height)
                }
            }
        )
        // Exactly the window's height and held to its top, so a new height never
        // shifts the figures above the change while the window catches up.
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .onAppear {
            guard !didApplyInitial else { return }
            didApplyInitial = true
            granularity = initialGranularity
            customRange = prefs.customUsageRange
        }
        .onChange(of: customRange) { _, range in prefs.customUsageRange = range }
        .onChange(of: panelIsOpen) { _, open in if !open { isDatePickerPresented = false } }
        .onExitCommand { isDatePickerPresented = false }
        .overlayPreferenceValue(UsageDateAnchorKey.self) { anchor in
            if isDatePickerPresented, let anchor {
                GeometryReader { proxy in
                    let rect = proxy[anchor]
                    let left = min(max(12, rect.maxX - 248), proxy.size.width - 260)
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { isDatePickerPresented = false }
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 6)
                            UsageDatePopover(savedRange: customRange) { range in
                                customRange = range
                                granularity = .custom
                                isDatePickerPresented = false
                            } onCancel: {
                                isDatePickerPresented = false
                            }
                        }
                        .frame(width: 248)
                        .background {
                            let shape = UsageDatePopoverShape(arrowX: rect.midX - left)
                            datePopoverBackground(shape)
                                .overlay(shape.stroke(theme.cardStroke, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                        }
                        .offset(x: left, y: rect.maxY + 2)
                        .environment(\.theme, theme)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func datePopoverBackground(_ shape: UsageDatePopoverShape) -> some View {
        if reduceTransparency || isSnapshot {
            shape.fill(theme.menuFill)
        } else if #available(macOS 26, *) {
            Color.clear.liquidGlass(true, in: shape)
        } else {
            shape.fill(.regularMaterial)
        }
    }

    @ViewBuilder
    private func content(_ dashboard: Dashboard) -> some View {
        let scope = prefs.usageScope
        let parts = dashboard.usageParts.filter { scope.category == nil || $0.tool == scope.category }
        let usage = scope == .combined ? dashboard.combined : parts.first?.usage ?? .empty
        let selectedParts = granularity == .custom && customRange != nil ? parts.map { part in
            var selected = part
            selected.usage = DashboardBuilder.selecting(part.usage, range: customRange!)
            return selected
        } : parts
        let selectedUsage = granularity == .custom
            ? DashboardBuilder.combined(selectedParts.map(\.usage), events: [], now: dashboard.updatedAt)
            : usage
        let quotaUpdatedAt = store.accountQuotas.compactMap { $0.quota?.updatedAt }.max()
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                VStack(spacing: 6) {
                    HStack {
                        CardTitle(text: "账号额度")
                        Spacer()
                        Text(quotaUpdatedAt.map { "最近数据 \(Format.quotaTime($0))" } ?? "暂无更新时间")
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(theme.textSecondary)
                            .help("最近一份额度数据的实际获取时间；各窗口的更新时间见下方")
                        Button { store.queryQuotasNow() } label: {
                            Group {
                                if store.isQueryingQuota {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(theme.accent)
                                }
                            }
                            .frame(width: 24, height: 24)
                            .background(theme.segmentedFill, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isQueryingQuota)
                        .help("手动刷新所有账号额度（会联网查询）")
                        .accessibilityLabel(store.isQueryingQuota ? "额度查询中" : "手动刷新额度")
                    }
                    .padding(.horizontal, 4)
                    if store.accountQuotas.isEmpty {
                        SubscriptionCard(snapshots: dashboard.snapshots)
                    } else {
                        AccountQuotaCard(accounts: store.accountQuotas)
                    }
                }
                if store.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在后台读取历史用量…")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    UsageCard(usage: selectedUsage, parts: selectedParts, granularity: $granularity,
                              customRange: $customRange, isDatePickerPresented: $isDatePickerPresented)
                    ModelBreakdownCard(usage: selectedUsage, granularity: granularity, basis: $basis)
                    ActivityCards(activity: usage.activity, parts: parts)
                }
            }
            .padding(.horizontal, 12)
            footer(dashboard.updatedAt)
                .padding(.horizontal, 12)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// The log directory, or a submenu with one per tool when there are two.
    private var logItem: IconMenu.Item {
        let tools = store.dashboard.snapshots.map(\.tool)
        guard tools.count > 1 else {
            return .init(title: "打开日志目录", shortcut: "l") {
                store.openLogDirectory(for: tools.first ?? .claudeCode)
            }
        }
        return .init(title: "打开日志目录", shortcut: "", submenu: tools.enumerated().map { index, tool in
            .init(title: tool.displayName, shortcut: index == 0 ? "l" : "") { store.openLogDirectory(for: tool) }
        }) {}
    }

    private func footer(_ updatedAt: Date) -> some View {
        HStack {
            Text(store.isLoading ? "账号额度已就绪 · 用量读取中" : "更新于 \(Format.clock(updatedAt)) · 本地读取")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
            if let release = updater.availableRelease {
                // Leads to Settings rather than installing on the spot: the
                // install ends in a restart, too much for a stray click.
                Button {
                    onOpenSettings()
                } label: {
                    Text("新版本 \(release.version)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(usesGlass ? .clear : theme.accent.opacity(0.12), in: Capsule())
                        .liquidGlass(usesGlass, in: Capsule(), tint: theme.accent.opacity(0.2))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if let version = updater.justUpdated {
                Text("已更新到 \(version)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.positive)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.positive.opacity(0.12), in: Capsule())
                    .fixedSize()
            }
            Spacer()
            if store.dashboard.usageParts.count > 1 {
                IconMenu(symbol: prefs.usageScope.footerSymbol,
                         tint: prefs.usageScope.category.map { theme.categorySeries($0) } ?? theme.textPrimary,
                         tool: prefs.usageScope.tool, action: {
                    prefs.usageScope = prefs.usageScope.next
                })
                .frame(width: 22, height: 22)
                .help("当前：\(prefs.usageScope.title)用量；点击切换至\(prefs.usageScope.next.title)")
                .accessibilityLabel("用量范围：\(prefs.usageScope.title)")
            }
            IconMenu(symbol: prefs.appearance.symbol, tint: theme.textPrimary, action: {
                prefs.appearance = switch prefs.appearance {
                case .system: .light
                case .light: .dark
                case .dark: .system
                }
            })
                .frame(width: 22, height: 22)
            IconMenu(symbol: "gearshape", tint: theme.textPrimary, items: [
                .init(title: "刷新", shortcut: "r") { Task { await store.refresh() } },
                logItem,
                .init(title: "", shortcut: "") {},
                .init(title: "设置…", shortcut: ",") { onOpenSettings() },
                .init(title: "", shortcut: "") {},
                .init(title: "退出", shortcut: "q") { NSApplication.shared.terminate(nil) },
            ])
            .frame(width: 22, height: 22)
        }
        .frame(height: 22)
        .padding(.top, 2)
        .padding(.horizontal, 2)
        .onChange(of: panelIsOpen) { _, open in
            if !open { updater.acknowledgeUpdate() }
        }
    }
}

private struct LoadingView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在读取本地会话日志…")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }
}
