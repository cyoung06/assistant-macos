import SwiftUI

/**
 * Week and month grids of events and deadlines (events are edited on the web). The week shows all
 * seven days when the window is wide, three when narrow, one when very narrow.
 */
struct CalendarView: View {
    enum Mode: String, CaseIterable { case week = "Week", month = "Month" }

    @EnvironmentObject private var model: AppModel
    @Binding var selected: String?
    @State private var mode = Mode.week
    @State private var anchor = todayString
    @State private var days = 7
    @State private var events: [EventItem] = []
    @State private var error: String?

    private var range: (from: String, to: String) {
        switch mode {
        case .week: let s = rangeStart(anchor, days: days); return (s, addDays(s, days - 1))
        case .month: let g = monthGrid(anchor); return (g.first!, g.last!)
        }
    }

    var body: some View {
        let (from, to) = range
        let colors = Dictionary(model.data.projects.map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a })
        let items = calItems(events: events, tasks: model.data.tasks, projectColors: colors)
        let select = { (id: String) in selected = id }
        VStack(spacing: 0) {
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(4) }
            switch mode {
            case .week: WeekGrid(dates: (0..<days).map { addDays(from, $0) }, items: items, select: select)
            case .month: MonthGrid(anchor: anchor, items: items, select: select) { anchor = $0; mode = .week }
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { days = visibleDays(width: g.size.width - WeekGrid.axis) }
                .onChange(of: g.size.width) { _, w in days = visibleDays(width: w - WeekGrid.axis) }
        })
        .navigationTitle("Calendar")
        .navigationSubtitle(mode == .month ? monthTitle(anchor) : rangeTitle(from, to))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow).help("Previous")
                Button("Today") { anchor = todayString }.keyboardShortcut("t").help("Today")
                Button { move(1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow).help("Next")
            }
            ToolbarItem {
                Picker("View", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }.pickerStyle(.segmented)
            }
        }
        .task(id: "\(from)/\(to)") {
            do { events = try await model.api.events(from: from, to: to); error = nil } catch { self.error = error.localizedDescription }
        }
    }

    private func move(_ by: Int) {
        switch mode {
        case .week: anchor = addDays(rangeStart(anchor, days: days), by * days)
        case .month: anchor = dayString(calendarKST.date(byAdding: .month, value: by, to: midnight(String(anchor.prefix(8)) + "01"))!)
        }
    }
}

private struct WeekGrid: View {
    static let axis: CGFloat = 52
    static let hour: CGFloat = 48
    let dates: [String]
    let items: [CalItem]
    let select: (String) -> Void
    @State private var allDayOpen = false

    var body: some View {
        let allDay = dates.map { allDayOn(items, day: $0) }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.axis, height: 1)
                ForEach(dates, id: \.self) { d in DayHeader(day: d).frame(maxWidth: .infinity) }
            }
            .padding(.vertical, 6)
            if allDay.contains(where: { !$0.isEmpty }) {
                let limit = allDayOpen ? Int.max : 3
                HStack(alignment: .top, spacing: 0) {
                    Text("all-day").font(.caption2).foregroundStyle(.secondary)
                        .frame(width: Self.axis - 6, alignment: .trailing).padding(.trailing, 6).padding(.top, 2)
                    ForEach(dates.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(allDay[i].prefix(limit)) { ItemChip(item: $0, select: select) }
                            if allDay[i].count > limit {
                                Button("+\(allDay[i].count - limit) more") { allDayOpen = true }.buttonStyle(.link).font(.caption2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(.horizontal, 1)
                    }
                }
                .padding(.bottom, 4)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(h == 0 ? "" : String(format: "%02d:00", h)).font(.caption2).foregroundStyle(.secondary)
                                    .offset(y: -7)
                                    .frame(width: Self.axis - 6, height: Self.hour, alignment: .topTrailing)
                                    .id(h)
                            }
                        }
                        .padding(.trailing, 6)
                        ForEach(dates, id: \.self) { d in
                            DayColumn(day: d, placed: dayLayout(items, day: d), select: select).frame(maxWidth: .infinity)
                        }
                    }
                    .overlay(alignment: .top) { Color.clear.frame(height: 1).id("start").padding(.top, Self.hour * 8 - 12) }
                }
                .onAppear { proxy.scrollTo("start", anchor: .top) }
            }
        }
    }
}

private struct DayHeader: View {
    let day: String
    var body: some View {
        let today = day == todayString
        HStack(spacing: 4) {
            Text(format(day, "EEE")).foregroundStyle(today ? Color.accentColor : .secondary)
            Text(format(day, "d")).fontWeight(.semibold)
                .foregroundStyle(today ? Color.white : .primary)
                .frame(minWidth: 24, minHeight: 24)
                .background(Circle().fill(today ? Color.accentColor : .clear))
        }
        .font(.callout)
    }
}

private struct DayColumn: View {
    let day: String
    let placed: [Placed]
    let select: (String) -> Void
    private let hour = WeekGrid.hour

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .topLeading) {
                Path { p in
                    for h in 0..<24 { p.move(to: .init(x: 0, y: CGFloat(h) * hour)); p.addLine(to: .init(x: w, y: CGFloat(h) * hour)) }
                    p.move(to: .zero); p.addLine(to: .init(x: 0, y: hour * 24))
                }
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                ForEach(placed) { p in
                    let cw = w / CGFloat(p.cols)
                    let h = max(CGFloat(p.endMin - p.startMin) / 60 * hour - 2, 12)
                    Block(item: p.item, height: h, select: select)
                        .frame(width: max(cw - 2, 1), height: h)
                        .padding(.leading, cw * CGFloat(p.col) + 1)
                        .padding(.top, CGFloat(p.startMin) / 60 * hour + 1)
                }
                if day == todayString {
                    TimelineView(.everyMinute) { ctx in
                        let c = calendarKST.dateComponents([.hour, .minute], from: ctx.date)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.red).frame(height: 2)
                            Circle().fill(.red).frame(width: 8, height: 8).offset(x: -4)
                        }
                        .padding(.top, CGFloat(c.hour! * 60 + c.minute!) / 60 * hour - 4)
                    }
                }
            }
        }
        .frame(height: hour * 24)
    }
}

/** A timed item in the week grid; deadlines are short markers with the task's status. */
private struct Block: View {
    let item: CalItem
    let height: CGFloat
    let select: (String) -> Void
    @State private var showing = false

    var body: some View {
        let color = itemColor(item)
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    if let t = item.task { StatusIcon(status: t.status).font(.system(size: 9)) }
                    Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(height < 36 ? 1 : 3)
                        .foregroundStyle(item.task?.closed == true ? .secondary : .primary)
                }
                if height >= 40 { Text(timeText(item)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.leading, 4).padding(.top, 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(item.task == nil ? 0.24 : 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { if let t = item.task { select(t.id) } else { showing = true } }
        .popover(isPresented: $showing) { EventInfo(item: item) }
        .help(item.title)
    }
}

/** An all-day item, or any item in the month grid. */
private struct ItemChip: View {
    let item: CalItem
    let select: (String) -> Void
    @State private var showing = false

    var body: some View {
        let color = itemColor(item)
        HStack(spacing: 3) {
            if let t = item.task { StatusIcon(status: t.status).font(.system(size: 9)) }
            else if !item.allDay { Circle().fill(color).frame(width: 6, height: 6) }
            if !item.allDay { Text(timeText(item, short: true)).foregroundStyle(.secondary) }
            Text(item.title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(item.allDay && item.task == nil ? 0.3 : 0.12)))
        .contentShape(Rectangle())
        .onTapGesture { if let t = item.task { select(t.id) } else { showing = true } }
        .popover(isPresented: $showing) { EventInfo(item: item) }
        .help(item.title)
    }
}

private struct MonthGrid: View {
    let anchor: String
    let items: [CalItem]
    let select: (String) -> Void
    let pickDay: (String) -> Void

    var body: some View {
        let grid = monthGrid(anchor)
        let byDay = itemsByDay(items, days: grid)
        let month = String(anchor.prefix(7))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(grid.prefix(7), id: \.self) { Text(format($0, "EEE")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
            .padding(.vertical, 4)
            ForEach(0..<6, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(grid[(r * 7)..<(r * 7 + 7)], id: \.self) { d in
                        MonthCell(day: d, inMonth: d.hasPrefix(month), items: byDay[d] ?? [], select: select, pickDay: pickDay)
                    }
                }
            }
        }
    }
}

private struct MonthCell: View {
    let day: String
    let inMonth: Bool
    let items: [CalItem]
    let select: (String) -> Void
    let pickDay: (String) -> Void

    var body: some View {
        GeometryReader { g in
            // The day number takes ~22pt; each chip ~17pt.
            let fits = max(0, Int((g.size.height - 24) / 17))
            let shown = items.count > fits ? max(0, fits - 1) : items.count
            VStack(alignment: .leading, spacing: 2) {
                let today = day == todayString
                Button { pickDay(day) } label: {
                    Text(format(day, "d")).font(.callout)
                        .foregroundStyle(today ? Color.white : inMonth ? .primary : Color.secondary.opacity(0.6))
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Circle().fill(today ? Color.accentColor : .clear))
                }
                .buttonStyle(.plain).help("Show this week")
                ForEach(items.prefix(shown)) { ItemChip(item: $0, select: select) }
                if items.count > shown {
                    Button("+\(items.count - shown) more") { pickDay(day) }.buttonStyle(.link).font(.caption2)
                }
            }
            .padding(3)
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1) }
        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1) }
    }
}

private struct EventInfo: View {
    let item: CalItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(.headline)
            Text(format(dayString(item.start), "EEEE, MMM d") + (item.allDay ? "" : " · " + timeText(item)))
            if let e = item.event {
                Text(([e.calendarName] + (e.repeats ? ["repeats"] : [])).joined(separator: " · ")).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 220, alignment: .leading)
    }
}

private func itemColor(_ item: CalItem) -> Color { item.color.map { Color(hex: $0) } ?? .accentColor }

@MainActor private func timeText(_ item: CalItem, short: Bool = false) -> String {
    let f = formatter("HH:mm")
    if let t = item.task { let time = t.due?.time.map { String($0.prefix(5)) } ?? ""; return short ? time : "Due " + time }
    return short ? f.string(from: item.start) : "\(f.string(from: item.start))–\(f.string(from: item.end))"
}

@MainActor private func format(_ day: String, _ pattern: String) -> String { formatter(pattern).string(from: midnight(day)) }

/** Formatters by pattern, made once (making one is slow and the grids format hundreds of labels). */
@MainActor private var formatters: [String: DateFormatter] = [:]

@MainActor private func formatter(_ pattern: String) -> DateFormatter {
    if let f = formatters[pattern] { return f }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.timeZone = seoul
    f.dateFormat = pattern
    formatters[pattern] = f
    return f
}

@MainActor private func monthTitle(_ day: String) -> String { format(day, "MMMM yyyy") }

@MainActor private func rangeTitle(_ from: String, _ to: String) -> String {
    if from == to { return format(from, "EEE, MMM d") }
    if from.prefix(7) == to.prefix(7) { return "\(format(from, "MMM d")) – \(format(to, "d"))" }
    return "\(format(from, "MMM d")) – \(format(to, "MMM d"))"
}
