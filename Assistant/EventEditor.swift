import SwiftUI

/** What the event editor opens on: a new event on a day, or an existing one (from one of its occurrences). */
enum EventTarget: Identifiable {
    case new(day: String)
    case existing(id: String, occurrence: String)
    var id: String { switch self { case let .new(day): "new:\(day)"; case let .existing(id, occ): "\(id):\(occ)" } }
}

/**
 * Create or edit an event, as on the web: title, time or all-day, repeat (with skipped dates that
 * can be brought back), project and notes. Events from a source (holidays, contests) are shown
 * read-only.
 */
struct EventEditor: View {
    @EnvironmentObject private var model: AppModel
    let target: EventTarget
    let onDone: () -> Void

    @State private var loaded = false
    @State private var fixed = false
    @State private var calendarName = ""
    @State private var title = ""
    @State private var notes = ""
    /** Where it is (a lecture's room). */
    @State private var location = ""
    @State private var allDay = false
    @State private var day = Date()
    @State private var lastDay = Date()
    @State private var start = Date()
    @State private var end = Date()
    @State private var projectId = ""
    @State private var repeats = false
    @State private var freq = "weekly"
    @State private var interval = 1
    @State private var weekdays: Set<String> = []
    @State private var hasUntil = false
    @State private var until = Date()
    @State private var skipped: [String] = []
    @State private var foreignRule = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false

    private static let weekdayOrder = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isNew ? "New event" : calendarName).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                form.disabled(fixed)
                if fixed { Text("From \(calendarName); it can't be changed here.").font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                buttons
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await load() }
        .confirmationDialog("Delete this event?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await remove() } }
        } message: { Text(repeats ? "Every occurrence goes; to drop one date, use Skip instead." : "") }
    }

    private var isNew: Bool { if case .new = target { return true }; return false }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Event title", text: $title).textFieldStyle(.roundedBorder).font(.title3)
            Toggle("All day", isOn: $allDay)
            HStack {
                if repeats { Text("From") }
                DatePicker("", selection: $day, displayedComponents: .date).labelsHidden()
                if allDay {
                    Text("to")
                    DatePicker("", selection: $lastDay, in: day..., displayedComponents: .date).labelsHidden()
                } else {
                    DatePicker("", selection: $start, displayedComponents: .hourAndMinute).labelsHidden()
                    Text("–")
                    DatePicker("", selection: $end, displayedComponents: .hourAndMinute).labelsHidden()
                }
            }
            if !allDay && minutes(end) <= minutes(start) { Text("End must be after start.").font(.caption).foregroundStyle(.orange) }
            Picker("Project", selection: $projectId) {
                Text("None").tag("")
                ForEach(model.data.projects.filter { ($0.state != .completed && $0.state != .canceled) || $0.id == projectId }, id: \.id) { Text($0.name).tag($0.id) }
            }
            if foreignRule {
                Text("Repeats by a rule set in another app; edit the rule there.").font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Repeats", isOn: $repeats)
                if repeats { repeatForm.padding(.leading, 18) }
            }
            TextField("Room or place", text: $location)
            Text("Notes").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $notes).font(.body).frame(minHeight: 60, maxHeight: 120).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
    }

    private var repeatForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Every")
                Stepper("\(interval)", value: $interval, in: 1...99).fixedSize()
                Picker("", selection: $freq) {
                    Text(interval == 1 ? "day" : "days").tag("daily")
                    Text(interval == 1 ? "week" : "weeks").tag("weekly")
                    Text(interval == 1 ? "month" : "months").tag("monthly")
                }
                .labelsHidden().fixedSize()
            }
            if freq == "weekly" {
                HStack(spacing: 4) {
                    ForEach(Self.weekdayOrder, id: \.self) { d in
                        let on = weekdays.contains(d)
                        Button(String(d.prefix(1))) { if on { weekdays.remove(d) } else { weekdays.insert(d) } }
                            .buttonStyle(.bordered).tint(on ? .accentColor : .secondary).help(d.capitalized)
                    }
                }
            }
            HStack {
                Toggle("Until", isOn: $hasUntil)
                if hasUntil { DatePicker("", selection: $until, in: day..., displayedComponents: .date).labelsHidden() } else { Text("forever").foregroundStyle(.secondary) }
            }
            if !skipped.isEmpty {
                Text("Skipped").font(.caption).foregroundStyle(.secondary)
                ForEach(skipped, id: \.self) { d in
                    HStack {
                        Text(label(d))
                        Button { skipped.removeAll { $0 == d } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(.link).help("Bring back this date")
                    }
                }
            }
        }
    }

    private var buttons: some View {
        HStack {
            if !isNew && !fixed {
                Button("Delete", role: .destructive) { confirmDelete = true }
                if repeats, case let .existing(_, occurrence) = target, !skipped.contains(occurrence) {
                    Button("Skip \(label(occurrence))") { skipped.append(occurrence); Task { await save() } }.help("Cancel just this occurrence")
                }
            }
            Spacer()
            Button(fixed ? "Close" : "Cancel", action: onDone).keyboardShortcut(.cancelAction)
            if !fixed {
                Button(busy ? "Saving…" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty || (!allDay && minutes(end) <= minutes(start)))
            }
        }
    }

    // ---- loading and saving ---------------------------------------------------------

    private func load() async {
        switch target {
        case let .new(d):
            let base = midnight(d)
            day = base; lastDay = base
            start = base.addingTimeInterval(9 * 3600); end = base.addingTimeInterval(10 * 3600)
            weekdays = [Self.weekdayOrder[calendarKST.component(.weekday, from: base) - 1]]
            until = base
            loaded = true
        case let .existing(id, _):
            do {
                let e = try await model.api.event(id)
                title = e["title"] as? String ?? ""
                notes = e["notes"] as? String ?? ""
                location = e["location"] as? String ?? ""
                fixed = e["fixed"] as? Bool ?? false
                calendarName = e["calendarName"] as? String ?? ""
                projectId = e["projectId"] as? String ?? ""
                if let sd = e["startDate"] as? String {
                    allDay = true
                    day = midnight(sd); lastDay = midnight(e["endDate"] as? String ?? sd)
                    start = day.addingTimeInterval(9 * 3600); end = day.addingTimeInterval(10 * 3600)
                } else if let s = (e["start"] as? String).flatMap(parseISO), let en = (e["end"] as? String).flatMap(parseISO) {
                    start = s; end = en; day = midnight(dayString(s)); lastDay = day
                }
                foreignRule = (e["repeats"] as? Bool ?? false) && e["repeat"] == nil
                if let r = e["repeat"] as? [String: Any] {
                    repeats = true
                    freq = r["freq"] as? String ?? "weekly"
                    interval = r["interval"] as? Int ?? 1
                    weekdays = Set(r["weekdays"] as? [String] ?? [])
                    if let u = r["until"] as? String { hasUntil = true; until = midnight(u) } else { until = day }
                    skipped = r["skipped"] as? [String] ?? []
                } else {
                    weekdays = [Self.weekdayOrder[calendarKST.component(.weekday, from: day) - 1]]
                    until = day
                }
                loaded = true
            } catch { self.error = error.localizedDescription; loaded = true }
        }
    }

    private func save() async {
        busy = true
        error = nil
        defer { busy = false }
        let room = location.trimmingCharacters(in: .whitespaces)
        var body: [String: Any] = ["title": title.trimmingCharacters(in: .whitespaces), "notes": notes, "location": room.isEmpty ? NSNull() : room, "projectId": projectId.isEmpty ? NSNull() : projectId]
        let d = dayString(day)
        if allDay {
            body["startDate"] = d
            body["endDate"] = max(d, dayString(lastDay))
        } else {
            body["start"] = iso(on: day, at: start)
            body["end"] = iso(on: day, at: end)
        }
        if !foreignRule {
            body["repeat"] = repeats ? [
                "freq": freq, "interval": interval, "weekdays": freq == "weekly" ? Array(weekdays) : [],
                "until": hasUntil ? dayString(until) : NSNull(), "skipped": skipped,
            ] as [String: Any] : NSNull()
        }
        do {
            if case let .existing(id, _) = target { try await model.api.saveEvent(id: id, body) } else {
                if !repeats { body.removeValue(forKey: "repeat") }
                if projectId.isEmpty { body.removeValue(forKey: "projectId") }
                try await model.api.saveEvent(id: nil, body)
            }
            onDone()
        } catch { self.error = error.localizedDescription }
    }

    private func remove() async {
        guard case let .existing(id, _) = target else { return }
        do { try await model.api.deleteEvent(id); onDone() } catch { self.error = error.localizedDescription }
    }

    // ---- dates ----------------------------------------------------------------------

    private func minutes(_ d: Date) -> Int {
        let c = calendarKST.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /** The time of day of [time] on the date of [date], as ISO 8601 with Seoul's offset. */
    private func iso(on date: Date, at time: Date) -> String {
        let t = calendarKST.dateComponents([.hour, .minute], from: time)
        let at = calendarKST.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: date)!
        let f = ISO8601DateFormatter()
        f.timeZone = seoul
        return f.string(from: at)
    }

    private func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private func label(_ day: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = seoul
        f.dateFormat = "EEE, MMM d"
        return f.string(from: midnight(day))
    }
}
