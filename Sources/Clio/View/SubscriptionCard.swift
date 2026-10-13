import SwiftUI

/// Where a pace readout should appear, in the card's own coordinates.
private struct QuotaTip {
    var text: Text
    /// The filled edge of the bar it belongs to.
    var x: CGFloat
    /// The bar's bottom.
    var y: CGFloat
}

/// The quota block: for each account, two rolling windows and an optional
/// per-model allowance beneath the account's name and plan.
///
/// A Codex window without reported utilisation displays an unknown value.
/// Claude Code windows can display local token totals until utilisation is reported.
struct SubscriptionCard: View {
    @Environment(\.theme) private var theme
    var snapshots: [ToolSnapshot]

    /// The readout is drawn over the whole card, in the card's coordinates.
    @State private var tip: QuotaTip?
    @State private var tipWidth: CGFloat = 0
    @State private var cardWidth: CGFloat = 0

    fileprivate static let space = "quotaCard"

    var body: some View {
        Card {
            ForEach(Array(snapshots.enumerated()), id: \.element.tool) { index, snapshot in
                if index > 0 {
                    // A hairline that takes up a whole point, as in the usage card.
                    Rectangle()
                        .fill(theme.separator)
                        .frame(height: 0.5)
                        .frame(height: 1)
                }
                HStack(spacing: 7) {
                    BrandIcon(tool: snapshot.tool, size: 14,
                              color: snapshot.tool.brandColor ?? theme.textPrimary)
                    Text(snapshot.tool.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    if let plan = snapshot.plan, !plan.isEmpty {
                        PlanBadge(text: plan)
                    }
                }
                .frame(height: 22)
                if let fiveHour = snapshot.fiveHour {
                    QuotaRow(window: fiveHour, showsTokensWhenUnknown: snapshot.tool == .claudeCode,
                             onTip: { tip = $0 })
                }
                QuotaRow(window: snapshot.week, showsTokensWhenUnknown: snapshot.tool == .claudeCode,
                         onTip: { tip = $0 })
                if let modelQuota = snapshot.modelQuota {
                    QuotaRow(window: modelQuota, onTip: { tip = $0 })
                }
                if snapshot.tool == .codex {
                    HStack {
                        Text("剩余重置次数")
                        Spacer()
                        Text(snapshot.remainingResets.map { "\($0) 次" } ?? "未知")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .frame(height: 17)
                }
            }
        }
        .coordinateSpace(name: Self.space)
        .background(
            GeometryReader { geo in
                Color.clear.onChange(of: geo.size.width, initial: true) { _, width in cardWidth = width }
            }
        )
        .overlay(alignment: .topLeading) {
            if let tip {
                HoverTip(text: tip.text, arrowEdge: .top)
                    .background(
                        GeometryReader { geo in
                            Color.clear.onChange(of: geo.size.width, initial: true) { _, width in
                                tipWidth = width
                            }
                        }
                    )
                    .offset(x: min(max(0, tip.x - tipWidth / 2), max(0, cardWidth - tipWidth)),
                            y: tip.y + 4)
            }
        }
        // Above the cards that follow, so the last row's readout is not cut off.
        .zIndex(tip == nil ? 0 : 1)
    }
}

private struct QuotaRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.panelIsOpen) private var panelIsOpen
    var window: QuotaWindow
    var showsTokensWhenUnknown = true
    var onTip: (QuotaTip?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(window.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text(window.fraction.map(Format.percent)
                         ?? (showsTokensWhenUnknown ? Format.compact(window.used) : "未知"))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.quotaColor(window.fraction, base: theme.textPrimary))
                    Text(Format.reset(window.resetsAt))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                }
                .fixedSize()
            }
            .frame(height: 17)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track)
                    if let fraction = window.fraction {
                        Capsule()
                            .fill(theme.quotaColor(fraction))
                            .frame(width: panelIsOpen && fraction > 0 ? max(3, geo.size.width * fraction) : 0)
                    }
                }
                // A 6pt bar is a small target; the hit area reaches past it
                // without taking any more room in the card.
                .contentShape(Rectangle().inset(by: -4))
                .onContinuousHover { phase in
                    guard case .active = phase, let fraction = window.fraction, let pace else {
                        onTip(nil)
                        return
                    }
                    let frame = geo.frame(in: .named(SubscriptionCard.space))
                    onTip(QuotaTip(text: pace,
                                   x: frame.minX + frame.width * fraction,
                                   y: frame.maxY))
                }
            }
            .frame(height: 6)
            .opacity(window.fraction == nil ? 0 : 1)
            .frame(height: window.fraction == nil ? 0 : 6)
        }
    }

    /// What the pace so far implies, or that the window resets first.
    private var pace: Text? {
        guard let projected = window.timeToExhaustion(), let resetsAt = window.resetsAt else { return nil }
        guard projected < resetsAt.timeIntervalSinceNow else {
            return Text("按当前速率在重置前不会耗尽")
        }
        return Text("按当前速率约 ")
            + Text(Format.duration(projected)).fontWeight(.semibold)
            + Text("后耗尽")
    }
}
