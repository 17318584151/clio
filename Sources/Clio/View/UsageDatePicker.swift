import SwiftUI

/// The usage header's compact switch, with the calendar attached to its custom segment.
struct UsageDatePicker: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var granularity: Granularity
    @Binding var customRange: UsageDateRange?
    @State private var target: Granularity?
    var isPresented: Binding<Bool> = .constant(false)

    private let options: [(Granularity, String)] = [(.day, "日"), (.week, "周"), (.month, "月"), (.custom, "自定义")]

    private var selection: Binding<Granularity> {
        Binding(get: { granularity }, set: select)
    }

    var body: some View {
        SegmentTrack(selection: selection, target: $target, thumbRadius: 4, trackRadius: 5, inset: 1.5,
                     spring: Motion.spring(Motion.period, reduce: reduceMotion)) {
            HStack(spacing: 0) {
                ForEach(options, id: \.0) { period, title in
                    segment(period, title: title)
                }
            }
        }
        .environment(\.liquidGlass, false)
        .help("日、周、月按本地自然周期统计；自然周从周一开始")
    }

    private func segment(_ period: Granularity, title: String) -> some View {
        Button { select(period) } label: {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(period == (target ?? granularity) ? theme.segmentedSelectedText : theme.textSecondary)
                .frame(height: 16)
                .padding(.horizontal, 8)
                .segmentFrame(period)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("日期范围：\(title)")
        .anchorPreference(key: UsageDateAnchorKey.self, value: .bounds) { period == .custom ? $0 : nil }
    }

    private func select(_ period: Granularity) {
        if period == .custom {
            isPresented.wrappedValue = true
        } else {
            isPresented.wrappedValue = false
            granularity = period
        }
    }
}

/// Calendar edits are local until Apply; shortcuts commit immediately.
struct UsageDatePopover: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    var savedRange: UsageDateRange?
    var onApply: (UsageDateRange) -> Void
    var onCancel: () -> Void
    @State private var selection = UsageDateSelection()
    @State private var month = Date()
    @State private var hoveredDate: Date?

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar
    }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var awaitingEnd: Bool { selection.start != nil && selection.end == nil }
    private var selected: UsageDateRange? {
        if awaitingEnd, let start = selection.start, let hoveredDate {
            return UsageDateRange(start: start, end: hoveredDate, calendar: calendar)
        }
        return selection.range(calendar: calendar)
    }
    private var endpointFill: Color { Color(hex: scheme == .dark ? 0x63A4FF : 0x0A84FF) }
    private var endpointText: Color { Color.white }
    private var monthStart: Date { calendar.dateInterval(of: .month, for: month)!.start }
    private var currentMonth: Date { calendar.dateInterval(of: .month, for: today)!.start }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                shortcut("近7天", days: 7)
                shortcut("近30天", days: 30)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                monthButton("chevron.left", label: "上个月", offset: -1)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    yearMenu
                    monthMenu
                }
                Spacer(minLength: 0)
                monthButton("chevron.right", label: "下个月", offset: 1)
                    .disabled(monthStart >= currentMonth)
            }
            .frame(height: 20)

            VStack(spacing: 3) {
                HStack(spacing: 0) {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { label in
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: 32, height: 16)
                    }
                }
                let leading = (calendar.component(.weekday, from: monthStart) + 5) % 7
                let days = calendar.range(of: .day, in: .month, for: month)!.count
                VStack(spacing: 3) {
                    ForEach(0..<((leading + days + 6) / 7), id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { column in
                                let index = row * 7 + column - leading
                                if index >= 0 && index < days {
                                    dayButton(calendar.date(byAdding: .day, value: index, to: monthStart)!)
                                } else {
                                    Color.clear.frame(width: 32, height: 24)
                                }
                            }
                        }
                        .background(alignment: .leading) { rangeBand(row: row, leading: leading, days: days) }
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let row = Int(point.y / 27)
                        let column = Int(point.x / 32)
                        let index = row * 7 + column - leading
                        guard awaitingEnd, point.x >= 0, point.x < 224, point.y >= 0,
                              index >= 0, index < days else { hoveredDate = nil; return }
                        let date = calendar.date(byAdding: .day, value: index, to: monthStart)!
                        hoveredDate = date <= today ? date : nil
                    case .ended: hoveredDate = nil
                    }
                }
            }

            Rectangle().fill(theme.separator).frame(height: 0.5)
            HStack(spacing: 6) {
                Text(selected?.title(calendar: calendar) ?? "请选择日期")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                if let selected {
                    Text("\(selected.dayCount(calendar: calendar))天")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .frame(height: 15)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("date-range-draft")

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("取消", action: onCancel)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                Button("应用") {
                    if let range = selection.range(calendar: calendar) { onApply(range) }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(endpointText)
                .background(endpointFill, in: RoundedRectangle(cornerRadius: 5))
                .disabled(selected == nil)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textPrimary)
        }
        .padding(12)
        .frame(width: 248)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("自定义日期范围")
        .onAppear {
            selection = UsageDateSelection(range: savedRange)
            month = savedRange?.end ?? today
        }
    }

    private func shortcut(_ title: String, days: Int) -> some View {
        Button(title) { onApply(.recent(days, calendar: calendar)) }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(theme.segmentedFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.cardStroke, lineWidth: 0.5))
    }

    private var yearMenu: some View {
        let year = calendar.component(.year, from: month)
        return Menu {
            ForEach(Array((1900...calendar.component(.year, from: today)).reversed()), id: \.self) { value in
                Button(String(value) + "年") { showMonth(year: value, month: calendar.component(.month, from: month)) }
            }
        } label: {
            menuLabel(String(year) + "年")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("选择年份")
    }

    private var monthMenu: some View {
        let value = calendar.component(.month, from: month)
        return Menu {
            ForEach(1...12, id: \.self) { value in
                Button("\(value)月") { showMonth(year: calendar.component(.year, from: month), month: value) }
                    .disabled(calendar.component(.year, from: month) == calendar.component(.year, from: today)
                              && value > calendar.component(.month, from: today))
            }
        } label: {
            menuLabel("\(value)月")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("选择月份")
    }

    private func menuLabel(_ title: String) -> some View {
        Text(title + " ▾")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.textPrimary)
    }

    private func showMonth(year: Int, month value: Int) {
        hoveredDate = nil
        let date = calendar.date(from: DateComponents(year: year, month: value, day: 1))!
        month = min(date, currentMonth)
    }

    @ViewBuilder
    private func rangeBand(row: Int, leading: Int, days: Int) -> some View {
        if let selected {
            let first = calendar.date(byAdding: .day, value: max(0, row * 7 - leading), to: monthStart)!
            let last = calendar.date(byAdding: .day, value: min(days - 1, row * 7 + 6 - leading), to: monthStart)!
            let start = max(first, selected.start)
            let end = min(last, selected.end)
            if start <= end {
                let offset = (calendar.dateComponents([.day], from: first, to: start).day ?? 0)
                    + max(0, leading - row * 7)
                let count = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.segmentedFill)
                    .frame(width: CGFloat(count) * 32, height: 24)
                    .offset(x: CGFloat(offset) * 32)
            }
        }
    }

    private func monthButton(_ symbol: String, label: String, offset: Int) -> some View {
        Button {
            hoveredDate = nil
            month = calendar.date(byAdding: .month, value: offset, to: monthStart)!
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func dayButton(_ date: Date) -> some View {
        let endpoint = selected.map { date == $0.start || date == $0.end } ?? false
        let within = selected.map { date >= $0.start && date <= $0.end } ?? false
        return Button {
            hoveredDate = nil
            selection.select(date, calendar: calendar)
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 11, weight: endpoint ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(date > today ? theme.textTertiary : (endpoint ? endpointText : theme.textPrimary))
                .frame(width: 32, height: 24)
                .background {
                    if endpoint {
                        RoundedRectangle(cornerRadius: 5).fill(endpointFill).frame(width: 24, height: 24)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(date > today)
        .accessibilityLabel(UsageDateRange(start: date, end: date, today: date, calendar: calendar).title(calendar: calendar))
        .accessibilityAddTraits(within ? .isSelected : [])
    }
}

/// The custom segment's frame, resolved in the panel's overlay.
struct UsageDateAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

/// One surface for the floating calendar body and its anchor arrow.
struct UsageDatePopoverShape: Shape {
    var arrowX: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY + 6,
                                            width: rect.width, height: rect.height - 6),
                        cornerRadius: 10)
        path.move(to: CGPoint(x: arrowX - 6, y: rect.minY + 6))
        path.addLine(to: CGPoint(x: arrowX, y: rect.minY))
        path.addLine(to: CGPoint(x: arrowX + 6, y: rect.minY + 6))
        path.closeSubpath()
        return path
    }
}
