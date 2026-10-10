import SwiftUI
import AppKit

/// The popover. Usage is shown for every tool together; the subscription card
/// lists each account's quota.
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
    @State private var granularity: Granularity = .day
    @State private var basis: ShareBasis = .tokens
    @State private var didApplyInitial = false

    private var theme: Theme { Theme.resolve(scheme) }
    /// Off-screen rendering can't draw the material, so snapshots keep the fills.
    private var usesGlass: Bool { prefs.liquidGlass && LiquidGlass.isAvailable && !isSnapshot }

    var body: some View {
        Group {
            if store.isLoading {
                LoadingView()
            } else if !store.dashboard.isEmpty {
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
        }
    }

    @ViewBuilder
    private func content(_ dashboard: Dashboard) -> some View {
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                SubscriptionCard(snapshots: dashboard.snapshots)
                UsageCard(usage: dashboard.combined, parts: dashboard.snapshots,
                          granularity: $granularity, basis: $basis)
                ActivityCards(activity: dashboard.combined.activity, parts: dashboard.snapshots)
                HeatmapCard(dailyTokens: dashboard.combined.dailyTokens, parts: dashboard.snapshots)
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
            Text("更新于 \(Format.clock(updatedAt)) · 本地读取")
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
