import Foundation

/**
 * Something drawn on the calendar: an event occurrence or a task's deadline. An all-day item runs
 * from midnight of its first day to midnight after its last (Seoul time).
 */
struct CalItem: Identifiable {
    let id: String
    let title: String
    let color: String?
    let start: Date
    let end: Date
    let allDay: Bool
    var event: EventItem?
    var task: TaskItem?
    /** The first and last day it touches, so finding a day's items compares strings rather than dates. */
    let firstDay: String
    let lastDay: String

    init(id: String, title: String, color: String?, start: Date, end: Date, allDay: Bool, event: EventItem? = nil, task: TaskItem? = nil) {
        (self.id, self.title, self.color, self.start, self.end, self.allDay, self.event, self.task) = (id, title, color, start, end, allDay, event, task)
        firstDay = dayString(start)
        lastDay = dayString(max(start, end.addingTimeInterval(-1)))
    }

    func on(_ day: String) -> Bool { firstDay <= day && day <= lastDay }
}

func midnight(_ day: String) -> Date { dayFromString(day)! }

/** Deadlines in a day's last half hour start at 23:30 so their 30-minute marker stays in it (as on the web). */
func calItems(events: [EventItem], tasks: [TaskItem], projectColors: [String: String]) -> [CalItem] {
    let evs: [CalItem] = events.compactMap { e in
        if let sd = e.startDate {
            return CalItem(id: "e:\(e.id):\(sd)", title: plainText(e.title), color: e.color, start: midnight(sd),
                           end: midnight(addDays(e.endDate ?? sd, 1)), allDay: true, event: e)
        }
        guard let s = e.start else { return nil }
        let end = e.end.flatMap { $0 > s ? $0 : nil } ?? s.addingTimeInterval(3600)
        return CalItem(id: "e:\(e.id):\(s.timeIntervalSince1970)", title: plainText(e.title), color: e.color, start: s, end: end, allDay: false, event: e)
    }
    let deadlines: [CalItem] = tasks.compactMap { t in
        guard let due = t.due, t.status != .canceled else { return nil }
        let color = t.projectId.flatMap { projectColors[$0] }
        let parts = (due.time ?? "").split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, parts[0] * 60 + parts[1] > 0 else {
            return CalItem(id: "d:\(t.id)", title: plainText(t.title), color: color, start: midnight(due.date), end: midnight(addDays(due.date, 1)), allDay: true, task: t)
        }
        let minutes = min(parts[0] * 60 + parts[1], 23 * 60 + 30)
        let s = midnight(due.date).addingTimeInterval(Double(minutes) * 60)
        return CalItem(id: "d:\(t.id)", title: plainText(t.title), color: color, start: s, end: s.addingTimeInterval(30 * 60), allDay: false, task: t)
    }
    return evs + deadlines
}

/** A timed item's piece within one day, in minutes from midnight, in column `col` of `cols` side by side. */
struct Placed: Identifiable {
    let item: CalItem
    let startMin: Int
    let endMin: Int
    let col: Int
    let cols: Int
    var id: String { item.id }
}

/** Timed items on `day`, with overlapping ones placed side by side; short ones count as at least `minMinutes` long. */
func dayLayout(_ items: [CalItem], day: String, minMinutes: Int = 20) -> [Placed] {
    let start = midnight(day), dayEnd = 24 * 60
    let segs = items.filter { !$0.allDay && $0.on(day) }.map { i -> (CalItem, Int, Int) in
        let s = max(0, Int(i.start.timeIntervalSince(start) / 60))
        let e = min(dayEnd, Int(i.end.timeIntervalSince(start) / 60))
        return (i, s, max(e, min(s + minMinutes, dayEnd)))
    }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 > $1.2 }

    var out: [Placed] = []
    var cluster: [((CalItem, Int, Int), Int)] = []
    var colEnds: [Int] = []
    var clusterEnd = -1
    func flush() {
        out += cluster.map { seg, col in Placed(item: seg.0, startMin: seg.1, endMin: seg.2, col: col, cols: colEnds.count) }
        cluster = []; colEnds = []
    }
    for seg in segs {
        if seg.1 >= clusterEnd { flush() }
        let col = colEnds.firstIndex { $0 <= seg.1 } ?? { colEnds.append(0); return colEnds.count - 1 }()
        colEnds[col] = seg.2
        cluster.append((seg, col))
        clusterEnd = max(clusterEnd, seg.2)
    }
    flush()
    return out
}

/** All-day items on `day`: events first, then deadlines. */
func allDayOn(_ items: [CalItem], day: String) -> [CalItem] {
    let list = items.filter { $0.allDay && $0.on(day) }
    return list.filter { $0.task == nil } + list.filter { $0.task != nil }
}

/** Each of `days`' items for the month grid, all-day ones first (events, then deadlines), then timed ones by start. */
func itemsByDay(_ items: [CalItem], days: [String]) -> [String: [CalItem]] {
    guard let first = days.first, let last = days.last else { return [:] }
    var out: [String: [CalItem]] = [:]
    for i in items where i.lastDay >= first && i.firstDay <= last {
        var d = max(i.firstDay, first)
        while d <= min(i.lastDay, last) { out[d, default: []].append(i); d = addDays(d, 1) }
    }
    return out.mapValues { list in
        list.filter { $0.allDay && $0.task == nil } + list.filter { $0.allDay && $0.task != nil } + list.filter { !$0.allDay }.sorted { $0.start < $1.start }
    }
}

func sunday(of day: String) -> String {
    addDays(day, 1 - calendarKST.component(.weekday, from: midnight(day)))
}

/** The six weeks (Sunday first) shown for the month containing `day`. */
func monthGrid(_ day: String) -> [String] {
    let first = String(day.prefix(8)) + "01"
    return (0..<42).map { addDays(sunday(of: first), $0) }
}

/** How many days the week view fits: the whole week when there's room, three when narrow, one when very narrow. */
func visibleDays(width: CGFloat) -> Int { width >= 640 ? 7 : width >= 320 ? 3 : 1 }

/** The first day shown: the week's Sunday when showing a whole week, else `anchor` itself. */
func rangeStart(_ anchor: String, days: Int) -> String { days == 7 ? sunday(of: anchor) : anchor }
