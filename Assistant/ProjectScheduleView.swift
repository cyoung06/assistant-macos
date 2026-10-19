import SwiftUI

/**
 * A project's calendar (loaded by the list, which is always on screen) without the clutter: its repeating events (lectures) as one line each, and
 * only what's coming up once: exams, meetings, and lectures that won't happen.
 */
struct ProjectScheduleSection: View {
    let schedule: ProjectSchedule?
    let projectName: String

    var body: some View {
        if let s = schedule, !(s.recurring.isEmpty && s.upcoming.isEmpty && s.skipped.isEmpty) {
            Section {
                ForEach(s.recurring, id: \.eventId) { r in Text(line(r)).foregroundStyle(.secondary) }
                ForEach(items(s), id: \.key) { i in ItemRow(item: i) }
            } header: { Text("Schedule") }
        }
    }

    private func line(_ r: RecurringSummary) -> String {
        let title = plainText(r.title)
        return (title == projectName ? "" : title + " · ") + scheduleLine(r)
    }

    private struct ItemRow: View {
        let item: Item
        var body: some View {
            HStack(spacing: 10) {
                Text(item.day).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                Text(item.time).foregroundStyle(.secondary).monospacedDigit().frame(width: 40, alignment: .leading)
                Text(item.title).foregroundStyle(item.skipped ? .tertiary : .primary).lineLimit(1)
            }
        }
    }

    private struct Item { let key: String; let sortKey: String; let day: String; let time: String; let title: String; let skipped: Bool }

    private func items(_ s: ProjectSchedule) -> [Item] {
        let time = DateFormatter(), day = DateFormatter()
        time.timeZone = seoul; time.dateFormat = "HH:mm"
        day.timeZone = seoul; day.locale = Locale(identifier: "en_US"); day.dateFormat = "EEE, MMM d"
        let upcoming = s.upcoming.map { o -> Item in
            let date = o.startDate ?? o.start.map(dayString) ?? ""
            let t = o.start.map { time.string(from: $0) } ?? ""
            return Item(key: "\(o.id):\(date)\(t)", sortKey: date + t, day: dayFromString(date).map(day.string) ?? date, time: t, title: plainText(o.title), skipped: false)
        }
        let skipped = s.skipped.map { k -> Item in
            let t = k.start.map { String($0.prefix(5)) } ?? ""
            return Item(key: "\(k.eventId):\(k.date)", sortKey: k.date + t, day: dayFromString(k.date).map(day.string) ?? k.date, time: t, title: plainText(k.title) + " · skipped", skipped: true)
        }
        return (upcoming + skipped).sorted { $0.sortKey < $1.sortKey }
    }
}

/** "Tue · Thu 12:30–13:45", "Every 2 weeks · Fri", "Daily 09:00–10:00". */
func scheduleLine(_ r: RecurringSummary) -> String {
    let short: [String: String] = ["MONDAY": "Mon", "TUESDAY": "Tue", "WEDNESDAY": "Wed", "THURSDAY": "Thu", "FRIDAY": "Fri", "SATURDAY": "Sat", "SUNDAY": "Sun"]
    let time = (r.start.flatMap { s in r.end.map { " \(s.prefix(5))–\($0.prefix(5))" } }) ?? ""
    let days = r.weekdays.map { short[$0.rawValue] ?? $0.rawValue }.joined(separator: " · ")
    switch r.freq {
    case .weekly: return (r.interval > 1 ? "Every \(r.interval) weeks · " : "") + days + time
    case .daily: return (r.interval > 1 ? "Every \(r.interval) days" : "Daily") + time
    case .monthly: return (r.interval > 1 ? "Every \(r.interval) months" : "Monthly") + time
    }
}
