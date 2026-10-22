import SwiftUI

/** One screen of the day: the next class (room, newest files), what's due soon, today's events, Triage. */
struct TodayView: View {
    @Binding var selected: String?
    /** Goes elsewhere in the app (the calendar, Triage, Files). */
    var go: (Destination) -> Void
    @EnvironmentObject private var model: AppModel
    @State private var today: TodayInfo?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Today").font(.largeTitle.bold())
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month().day())).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let t = today {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), alignment: .top)], alignment: .leading, spacing: 16) {
                        card("Next class") { next(t) }
                        card("Due soon") { due(t) }
                        card("Today's events") { events(t) }
                        if t.triage > 0 {
                            Button { go(.triage) } label: {
                                HStack { Text("\(t.triage)").font(.title2.bold()).foregroundStyle(.tint); Text("waiting in Triage"); Spacer() }
                                    .padding(16).frame(maxWidth: .infinity).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if error == nil {
                    ProgressView()
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .task {
            // Kept fresh while it's shown: the next class moves on, tasks get done.
            while !Task.isCancelled {
                do { today = try await model.api.today(); error = nil } catch { self.error = error.localizedDescription }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func next(_ t: TodayInfo) -> some View {
        if let n = t.next {
            Button { go(.calendar) } label: { Text(n.event.title).font(.title3.bold()) }.buttonStyle(.plain)
            HStack(spacing: 4) {
                Text(nextWhen(n.event)).bold()
                if let room = n.event.location { Text("· \(room)") }
                if let p = n.projectName { Text("· \(p)") }
            }
            .font(.callout).foregroundStyle(.secondary)
            ForEach(n.files, id: \.path) { f in
                Button { reveal(f.path) } label: {
                    HStack {
                        Image(systemName: driveIcon(driveKind(f.name, folder: false))).foregroundStyle(.secondary)
                        Text(f.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let m = f.modified { Text(m.formatted(.dateTime.month().day())).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
            }
        } else {
            Text("No classes this week. A lecture shows here once its event is linked to the course's project.").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func due(_ t: TodayInfo) -> some View {
        if t.due.isEmpty { Text("Nothing due in the next two days.").font(.callout).foregroundStyle(.secondary) }
        ForEach(t.due, id: \.id) { task in
            Button { selected = task.id } label: {
                HStack {
                    RefText(markdown: task.title).lineLimit(1)
                    Spacer()
                    if let d = task.due { Text(dueText(d, today: todayString)).font(.caption).foregroundStyle(task.overdue ? .red : .secondary) }
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func events(_ t: TodayInfo) -> some View {
        if t.events.isEmpty { Text("Nothing on the calendar today.").font(.callout).foregroundStyle(.secondary) }
        ForEach(Array(t.events.enumerated()), id: \.offset) { _, e in
            Button { go(.calendar) } label: {
                HStack {
                    Circle().fill(Color(hex: e.color ?? "#2F5BE0")).frame(width: 8, height: 8)
                    Text(e.title).lineLimit(1)
                    Spacer()
                    Text(when(e) + (e.location.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /** "12:30–13:45", or "All day". */
    private func when(_ e: EventItem) -> String {
        guard let s = e.start, let end = e.end else { return "All day" }
        return "\(s.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    /** "Now, until 13:45", "In 25 min", or the day and time. */
    private func nextWhen(_ e: EventItem) -> String {
        guard let s = e.start, let end = e.end else { return "All day" }
        let now = Date.now
        if s <= now { return "Now, until \(end.formatted(date: .omitted, time: .shortened))" }
        let minutes = Int(s.timeIntervalSince(now) / 60)
        if minutes < 60 { return "In \(minutes) min" }
        let day = Calendar.current.isDateInToday(s) ? "Today" : s.formatted(.dateTime.weekday(.abbreviated))
        return "\(day) \(when(e))"
    }

    /** The file in Files, selected. */
    private func reveal(_ path: String) {
        go(.files)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .driveReveal, object: path) }
    }
}
