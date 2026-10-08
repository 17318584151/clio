import SwiftUI

/// The settings window from the design, plus the quota ceilings the
/// subscription card needs — no local file records those, so they are entered
/// here or the percentages stay hidden.
struct SettingsView: View {
    var onPreviewConfetti: () -> Void = {}

    @EnvironmentObject private var prefs: Preferences
    @Environment(\.colorScheme) private var scheme

    /// The window turns clear at the same time, so the glass shows the desktop.
    private var usesGlass: Bool { prefs.liquidGlass && LiquidGlass.isAvailable }

    var body: some View {
        let theme = Theme.resolve(scheme)
        ScrollView { SettingsContent(onPreviewConfetti: onPreviewConfetti) }
            .scrollIndicators(.never)
            .edgeFade()
            .frame(width: 420, height: 640)
            .background(usesGlass ? .clear : theme.panelFill)
            .background {
                Color.clear
                    .liquidGlass(usesGlass, in: Rectangle(), tint: theme.glassTint)
                    .ignoresSafeArea()
            }
    }
}

private extension View {
    /// The pointing-hand pointer over a link, from macOS 15.
    @ViewBuilder
    func linkPointer() -> some View {
        if #available(macOS 15, *) {
            pointerStyle(.link)
        } else {
            self
        }
    }

    /// Fades a scroll view's edge on whichever side still has content out of
    /// view. Meant for scroll views without scroll bars, which it would fade
    /// too. Before macOS 15 the edges stay sharp.
    @ViewBuilder
    func edgeFade(_ length: CGFloat = 44) -> some View {
        if #available(macOS 15, *) {
            modifier(EdgeFade(length: length))
        } else {
            self
        }
    }
}

@available(macOS 15, *)
private struct EdgeFade: ViewModifier {
    let length: CGFloat
    @State private var hidden = Hidden()

    struct Hidden: Equatable {
        var above = false
        var below = false
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Hidden.self) { g in
                // Content runs under the title bar, so at rest the offset is
                // minus that inset rather than zero.
                Hidden(above: g.contentOffset.y + g.contentInsets.top > 0.5,
                       below: g.visibleRect.maxY < g.contentSize.height - 0.5)
            } action: { _, now in
                withAnimation(.easeOut(duration: 0.15)) { hidden = now }
            }
            .mask {
                VStack(spacing: 0) {
                    edge(.top, faded: hidden.above)
                    Color.black
                    edge(.bottom, faded: hidden.below)
                }
            }
    }

    /// The outer half drops close to nothing, so the row at the very edge all
    /// but disappears and reads as more to come. Opaque when not faded.
    private func edge(_ side: VerticalEdge, faded: Bool) -> some View {
        ZStack {
            Color.black.opacity(faded ? 0 : 1)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.2), location: 0.45),
                    .init(color: .black, location: 1),
                ],
                startPoint: side == .top ? .top : .bottom,
                endPoint: side == .top ? .bottom : .top)
        }
        .frame(height: length)
    }
}

/// The settings body, kept separate from the scroll view so it can be rendered
/// on its own.
struct SettingsContent: View {
    var onPreviewConfetti: () -> Void = {}

    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var store: UsageStore
    @Environment(\.colorScheme) private var scheme
    @State private var bridgeState = StatusLineInstaller.state()
    @ObservedObject private var updater = Updater.shared

    private var theme: Theme { Theme.resolve(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
                group {
                    row("100M Token 里程碑礼花",
                        detail: "日、周或月累计每突破 100M 时全屏庆祝，不打断操作") {
                        HStack(spacing: 10) {
                            Button("预览", action: onPreviewConfetti)
                                .controlSize(.small)
                            Toggle("", isOn: $prefs.confettiEnabled).labelsHidden()
                        }
                    }
                    if LiquidGlass.isAvailable {
                        divider
                        row("液态玻璃") {
                            Toggle("", isOn: $prefs.liquidGlass).labelsHidden()
                        }
                    }
                    divider
                    row("开机自启") {
                        Toggle("", isOn: $prefs.launchAtLogin).labelsHidden()
                    }
                    divider
                    row("刷新频率") {
                        Picker("", selection: $prefs.refreshInterval) {
                            Text("每 15 秒").tag(15.0)
                            Text("每 30 秒").tag(30.0)
                            Text("每 1 分钟").tag(60.0)
                            Text("每 5 分钟").tag(300.0)
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                }

                section("菜单栏显示") {
                    row("显示内容") {
                        Picker("", selection: $prefs.menuBarDisplay) {
                            ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                    divider
                    row("Token 数来源") {
                        Picker("", selection: $prefs.tokenSource) {
                            ForEach(TokenSource.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                }

                section("额度来源") {
                    row("主动查询", detail: liveDetail) {
                        Text(liveStatus)
                            .font(.system(size: 12))
                            .foregroundStyle(store.rateLimits == nil ? theme.textSecondary : theme.positive)
                    }
                    row("查询频率") {
                        Picker("", selection: $prefs.quotaInterval) {
                            Text("每 15 分钟").tag(900.0)
                            Text("每 30 分钟").tag(1800.0)
                            Text("每 1 小时").tag(3600.0)
                            Text("每 2 小时").tag(7200.0)
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                    divider
                    row("状态栏推送", detail: bridgeDetail) {
                        Button(bridgeState == .installed ? "移除" : "接入") {
                            toggleBridge()
                        }
                        .controlSize(.small)
                        .disabled(bridgeState == .unavailable)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bridgeState == .installed
                             ? "已写入 ~/.claude/settings.json 的 statusLine.command："
                             : "按「接入」会把 statusLine.command 改写成：")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(bridgeCommand)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.segmentedFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }

                section("数据来源（只读本地）") {
                    ForEach(Tool.allCases) { tool in
                        HStack(spacing: 8) {
                            BrandIcon(tool: tool, size: 13, color: tool.brandColor ?? theme.textPrimary)
                            Text(tool.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            Text(tool.logDirectoryDisplay)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                            StatusDot(isLive: store.dashboard.snapshot(for: tool) != nil)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        if tool != Tool.allCases.last { divider }
                    }
                }

                section("更新") {
                    updateStatus
                    divider
                    row("自动检查更新") {
                        Toggle("", isOn: $prefs.autoCheckUpdates).labelsHidden()
                    }
                    divider
                    row("自动安装更新") {
                        Toggle("", isOn: $prefs.autoInstallUpdates).labelsHidden()
                            .disabled(!prefs.autoCheckUpdates)
                    }
                }

                section("价格表") {
                    row(priceSource, detail: priceDetail) {
                        Button("立即更新") {
                            Task {
                                await PriceService.shared.refresh()
                                await store.refresh()
                            }
                        }
                        .controlSize(.small)
                    }
                }
        }
        .font(.system(size: 12))
        .toggleStyle(.switch)
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .onAppear { bridgeState = StatusLineInstaller.state() }
        .environment(\.theme, theme)
    }

    // MARK: - Building blocks

    private var divider: some View {
        Rectangle().fill(theme.separator).frame(height: 0.5)
    }

    @ViewBuilder
    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(theme.cardFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 0.5))
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, 2)
            group(content: content)
        }
    }

    private func row<Trailing: View>(_ title: String,
                                     detail: String? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        row(Text(title).foregroundStyle(theme.textPrimary), detail: detail.map { Text($0) }, trailing: trailing)
    }

    @ViewBuilder
    private func row<Title: View, Trailing: View>(_ title: Title,
                                                  detail: Text?,
                                                  @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                title
                if let detail {
                    detail
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The update state: an icon tile with a title and sub line, then when it
    /// was last checked and the button for the next step.
    private var updateStatus: some View {
        let face = UpdateFace(updater.phase, lastChecked: updater.lastChecked, theme: theme)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                UpdateIcon(icon: face.icon, tint: face.tint, quiet: face.quiet)
                VStack(alignment: .leading, spacing: 1) {
                    Text(face.title)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.textPrimary)
                    Group {
                        if face.linksReleases {
                            HStack(spacing: 0) {
                                Text("从 ")
                                LinkLabel(title: "GitHub Releases", url: Updater.releasesPage)
                                Text(" 获取稳定版")
                            }
                        } else if let sub = face.sub {
                            Text(sub)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
                }
            }
            HStack {
                Text("\(face.foot)\(face.stamp.map(stamp) ?? Text(""))")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                updateButton(face)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.18), value: updater.phase)
    }

    @ViewBuilder
    private func updateButton(_ face: UpdateFace) -> some View {
        let button = Button(action: performUpdateStep) {
            if let icon = face.buttonIcon {
                Label(face.button, systemImage: icon).labelStyle(.titleAndIcon)
            } else {
                Text(face.button)
            }
        }
        .controlSize(.small)
        .disabled(face.busy)
        if face.prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }

    private func performUpdateStep() {
        switch updater.phase {
        case .idle, .upToDate, .failed:
            Task { await updater.check() }
        case .available(let release), .ready(let release):
            Task { await updater.install(release) }
        case .checking, .downloading, .installing:
            break
        }
    }

    /// A time something was last fetched, darker and heavier than the grey
    /// label around it.
    private func stamp(_ date: Date) -> Text {
        Text(Format.stamp(date))
            .fontWeight(.medium)
            .foregroundStyle(theme.textPrimary)
    }

    @ViewBuilder
    private var priceSource: some View {
        if store.priceOrigin == .builtin {
            Text("内置价格").foregroundStyle(theme.textPrimary)
        } else {
            LinkLabel(title: "models.dev", url: URL(string: "https://models.dev")!)
                .fontWeight(.medium)
        }
    }

    private var priceDetail: Text {
        guard let fetched = store.priceFetchedAt else { return Text("尚未联网获取") }
        switch store.priceOrigin {
        case .network: return Text("最近更新 \(stamp(fetched))")
        case .stale: return Text("本次校验失败，沿用 \(stamp(fetched)) 的结果")
        case .builtin: return Text("尚未联网获取")
        }
    }

    /// What the button writes: this binary in front of whatever is configured.
    private var bridgeCommand: String {
        let binary = Bundle.main.executableURL?.path ?? "Clio"
        return "\"\(binary)\" --statusline -- <原有 statusLine 命令>"
    }

    private var bridgeDetail: String {
        switch bridgeState {
        case .installed:
            return "Claude Code 每渲染一次状态栏就推送一次额度；原状态栏照常显示"
        case .notInstalled:
            return "让 Claude Code 主动推送额度，用它时几乎实时；不含按模型窗口"
        case .unavailable:
            return "读不到 ~/.claude/settings.json"
        }
    }

    private func toggleBridge() {
        do {
            if bridgeState == .installed {
                try StatusLineInstaller.remove()
            } else {
                try StatusLineInstaller.install()
            }
        } catch {
            // The button reflects whatever the file actually says afterwards.
        }
        bridgeState = StatusLineInstaller.state()
    }

    private var liveStatus: String {
        guard UsageProbe.executable != nil else { return "未找到 claude" }
        guard let snapshot = store.rateLimits else { return "暂无数据" }
        return "已读取 · \(Format.clock(snapshot.updatedAt))"
    }

    private var liveDetail: String {
        guard UsageProbe.executable != nil else {
            return "找不到 claude 命令行，5 小时、本周与模型额度只能显示 Token 数"
        }
        return "展开面板时问一次，其余按下面的频率；失败时沿用上次结果"
    }

    private func binding(_ key: ReferenceWritableKeyPath<Preferences, [String: String]>, _ tool: Tool) -> Binding<String> {
        Binding(
            get: { prefs[keyPath: key][tool.rawValue] ?? "" },
            set: { prefs[keyPath: key][tool.rawValue] = $0 }
        )
    }

}

/// A data source's status dot. While the source has data, a ring of the same
/// green keeps spreading out from the dot and fading.
private struct StatusDot: View {
    var isLive: Bool

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(isLive ? theme.positive : theme.textTertiary)
            .frame(width: 6, height: 6)
            .background {
                if isLive && !reduceMotion {
                    Circle()
                        .fill(theme.positive)
                        .phaseAnimator([false, true]) { ring, spreading in
                            ring
                                .scaleEffect(spreading ? 2.6 : 1)
                                .opacity(spreading ? 0 : 0.5)
                        } animation: { spreading in
                            // The ring snaps back to the dot's size, hidden behind it.
                            spreading ? .easeOut(duration: 1.6).delay(0.6) : nil
                        }
                }
            }
    }
}

/// Text in the accent color that opens `url` in the browser, underlined while
/// the pointer is over it.
private struct LinkLabel: View {
    let title: String
    let url: URL

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var isHovered = false

    var body: some View {
        Button { openURL(url) } label: {
            Text(title)
                .underline(isHovered)
                .foregroundStyle(theme.accent)
        }
        .buttonStyle(.plain)
        .linkPointer()
        .onHover { isHovered = $0 }
    }
}

/// The update block's icon, wording and button in each phase.
@MainActor
private struct UpdateFace {
    enum Icon { case download, done, warning, busy }

    var icon: Icon
    var tint: Color
    /// A grey tile rather than one tinted with `tint`.
    var quiet = false
    var title: String
    var sub: String?
    /// The sub line reads 从 GitHub Releases 获取稳定版, with the link.
    var linksReleases = false
    var foot: String
    /// Follows `foot`, set apart from it.
    var stamp: Date?
    var button: String
    /// An SF Symbol before the button's title.
    var buttonIcon: String?
    var prominent = false
    var busy = false

    init(_ phase: Updater.Phase, lastChecked: Date?, theme: Theme) {
        let current = Updater.currentVersion
        let last = lastChecked == nil ? "尚未检查" : "上次检查 "
        switch phase {
        case .idle:
            icon = .download; tint = theme.textSecondary; quiet = true
            title = "Clio \(current)"; linksReleases = true
            foot = last; stamp = lastChecked
            button = "检查更新"; buttonIcon = "arrow.clockwise"
        case .checking:
            icon = .busy; tint = theme.accent
            title = "正在检查更新…"; sub = "连接 github.com"
            foot = "通常需要几秒"
            button = "检查中"; busy = true
        case .upToDate:
            icon = .done; tint = theme.positive
            title = "已是最新版本"; sub = "Clio \(current)"
            foot = last; stamp = lastChecked
            button = "再次检查"; buttonIcon = "arrow.clockwise"
        case .available(let release):
            icon = .download; tint = theme.accent
            title = "Clio \(release.version) 可更新"; sub = release.size.map(Self.megabytes)
            foot = "当前 \(current)"
            button = "下载并安装"; buttonIcon = "arrow.down"; prominent = true
        case .downloading(let release):
            icon = .busy; tint = theme.accent
            title = "正在下载 \(release.version)"; sub = release.size.map { "共 \(Self.megabytes($0))" }
            foot = "下载完成后自动安装"
            button = "下载中"; busy = true
        case .ready(let release):
            icon = .done; tint = theme.positive
            title = "\(release.version) 已准备就绪"; sub = "弹出层与设置窗口都关闭后自动安装并重启"
            foot = release.size.map { "已下载 \(Self.megabytes($0))" } ?? "已下载"
            button = "立即重启"; buttonIcon = "arrow.clockwise"; prominent = true
        case .installing(let release):
            icon = .busy; tint = theme.accent
            title = "正在安装 \(release.version)…"; sub = "请勿退出 Clio"
            foot = "完成后自动重新启动"
            button = "安装中"; busy = true
        case .failed(let message):
            icon = .warning; tint = theme.danger
            title = "更新没有完成"; sub = message
            foot = last; stamp = lastChecked
            button = "重试"; buttonIcon = "arrow.clockwise"
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

/// The update block's leading tile: a glyph, or an arc turning while busy.
private struct UpdateIcon: View {
    var icon: UpdateFace.Icon
    var tint: Color
    var quiet: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch icon {
            case .download: Image(systemName: "arrow.down")
            case .done: Image(systemName: "checkmark")
            case .warning: Image(systemName: "exclamationmark.triangle")
            case .busy:
                TimelineView(.animation) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 13, height: 13)
                        .rotationEffect(.degrees(turn * 360))
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 30, height: 30)
        .background(quiet ? theme.segmentedFill : tint.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
