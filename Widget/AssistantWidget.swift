import SwiftUI
import WidgetKit

/** The day as the widget shows it: from the server's Today (nil while it can't be reached). */
struct DayEntry: TimelineEntry {
    let date: Date
    let today: TodayInfo?
}

/** Today from the server, fetched again every quarter of an hour (and once the next class has started). */
struct DayProvider: TimelineProvider {
    private let api = API(base: URL(string: Defaults.server)!)

    func placeholder(in context: Context) -> DayEntry { DayEntry(date: .now, today: nil) }

    func getSnapshot(in context: Context, completion: @escaping (DayEntry) -> Void) {
        Task { completion(DayEntry(date: .now, today: try? await api.today())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DayEntry>) -> Void) {
        Task {
            let today = try? await api.today()
            var next = Date.now.addingTimeInterval(15 * 60)
            if let start = today?.next?.event.start, start > .now { next = min(next, start) }
            completion(Timeline(entries: [DayEntry(date: .now, today: today)], policy: .after(next)))
        }
    }
}

struct DayView: View {
    let entry: DayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = entry.today {
                next(t)
                if family != .systemSmall {
                    Divider()
                    due(t, limit: family == .systemLarge ? 6 : 3)
                }
                if family == .systemLarge {
                    Divider()
                    events(t)
                }
                Spacer(minLength: 0)
                if family != .systemSmall { actions }
            } else {
                Text("Can't reach Assistant").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                actions
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func next(_ t: TodayInfo) -> some View {
        if let n = t.next, let start = n.event.start {
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT CLASS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(n.event.title).font(.headline).lineLimit(2)
                Text([when(start), n.event.location].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .widgetURL(URL(string: "assistant://today"))
        } else {
            Text("No classes this week").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func due(_ t: TodayInfo, limit: Int) -> some View {
        if t.due.isEmpty {
            Text("Nothing due soon").font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(t.due.prefix(limit), id: \.id) { task in
                Link(destination: URL(string: "assistant://task/\(task.id)")!) {
                    HStack {
                        Text(plainText(task.title)).font(.caption).lineLimit(1)
                        Spacer()
                        if let d = task.due { Text(dueText(d, today: todayString)).font(.caption2).foregroundStyle(task.overdue ? .red : .secondary) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func events(_ t: TodayInfo) -> some View {
        ForEach(Array(t.events.prefix(5).enumerated()), id: \.offset) { _, e in
            HStack {
                Text(e.title).font(.caption).lineLimit(1)
                Spacer()
                Text(e.start.map { $0.formatted(date: .omitted, time: .shortened) } ?? "All day").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Link(destination: URL(string: "assistant://quick-note")!) { Label("Quick Note", systemImage: "square.and.pencil") }
            Link(destination: URL(string: "assistant://capture")!) { Label("Capture", systemImage: "camera.viewfinder") }
        }
        .font(.caption)
    }

    /** "In 25 min", "13:30", or "Mon 12:30". */
    private func when(_ start: Date) -> String {
        let minutes = Int(start.timeIntervalSinceNow / 60)
        if minutes <= 0 { return "Now" }
        if minutes < 60 { return "In \(minutes) min" }
        let time = start.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(start) ? time : "\(start.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "today", provider: DayProvider()) { entry in
            DayView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("The next class, what's due soon, and a quick note or capture.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct AssistantWidgets: WidgetBundle {
    var body: some Widget { TodayWidget() }
}
