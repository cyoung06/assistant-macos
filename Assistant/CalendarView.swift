import SwiftUI

/** A week as an agenda: events and deadlines per day. */
struct CalendarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selected: String?
    @State private var weekStart = CalendarView.sunday(of: todayString)
    @State private var events: [EventItem] = []
    @State private var error: String?

    static func sunday(of day: String) -> String {
        addDays(day, 1 - calendarKST.component(.weekday, from: dayFromString(day)!))
    }

    var body: some View {
        let end = addDays(weekStart, 6)
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(0..<7, id: \.self) { i in
                let day = addDays(weekStart, i)
                Section {
                    let deadlines = model.data.tasks.filter { $0.due?.date == day && $0.status != .canceled }
                    let dayEvents = events.filter { e in
                        if let s = e.startDate { return s <= day && (e.endDate ?? s) >= day }
                        return e.start.map { dayString($0) == day } ?? false
                    }
                    if deadlines.isEmpty && dayEvents.isEmpty { Text("—").foregroundStyle(.tertiary) }
                    ForEach(dayEvents, id: \.self) { e in
                        HStack {
                            RoundedRectangle(cornerRadius: 2).fill(Color(hex: e.color)).frame(width: 4, height: 28)
                            VStack(alignment: .leading) {
                                Text(plainText(e.title))
                                Text([time(e), e.repeats ? "repeats" : nil, e.calendarName].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(deadlines, id: \.id) { t in
                        HStack {
                            StatusIcon(status: t.status)
                            VStack(alignment: .leading) {
                                Text(plainText(t.title))
                                Text("Due" + (t.due?.time.map { " \($0.prefix(5))" } ?? "")).font(.caption).foregroundStyle(t.overdue ? .red : .secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selected = t.id }
                    }
                } header: {
                    Text(header(day)).foregroundStyle(day == todayString ? Color.accentColor : .primary)
                }
            }
        }
        .navigationTitle("Calendar")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { weekStart = addDays(weekStart, -7) } label: { Image(systemName: "chevron.left") }
                Button("Today") { weekStart = CalendarView.sunday(of: todayString) }
                Button { weekStart = addDays(weekStart, 7) } label: { Image(systemName: "chevron.right") }
                Text("\(header(weekStart)) – \(header(end))").foregroundStyle(.secondary)
            }
        }
        .task(id: weekStart) {
            do { events = try await model.api.events(from: weekStart, to: end); error = nil } catch { self.error = error.localizedDescription }
        }
    }

    private func header(_ day: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = seoul
        f.dateFormat = "EEE, MMM d"
        return f.string(from: dayFromString(day)!)
    }

    private func time(_ e: EventItem) -> String? {
        guard let s = e.start, let en = e.end else { return "All day" }
        let f = DateFormatter()
        f.timeZone = seoul
        f.dateFormat = "HH:mm"
        return "\(f.string(from: s))–\(f.string(from: en))"
    }
}
