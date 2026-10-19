import AssistantAPI
import AppKit
import Foundation
import UserNotifications

/** Everything the task views show; the last good copy is kept on disk for offline reading. */
struct Snapshot: Codable {
    var tasks: [TaskItem] = []
    var projects: [Project] = []
    var labels: [TaskLabel] = []
    /** Optional so a copy saved before initiatives existed still loads. */
    var initiatives: [Initiative]? = []
    var fetchedAt: Date?
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var data = Snapshot()
    @Published private(set) var loading = false
    @Published var error: String?
    /** A task to show (from a reference link, the menu bar or a notification). */
    @Published var openTask: String?
    /** Triage: inputs with their suggestions (loaded with everything else, and polled while the model reads). */
    @Published var triage: [TriageInput] = []

    @Published var serverURL: String = UserDefaults.standard.string(forKey: "server") ?? Defaults.server {
        didSet { UserDefaults.standard.set(serverURL, forKey: "server") }
    }

    var api: API { API(base: URL(string: serverURL) ?? URL(string: Defaults.server)!) }

    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Assistant")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "snapshot.json")
    }()

    private init() {
        if let raw = try? Data(contentsOf: cacheURL), let s = try? JSONDecoder().decode(Snapshot.self, from: raw) { data = s }
        // Refresh every few minutes while running, so the menu bar and reminders stay current.
        // Whatever was handed to Triage before a quit goes out now.
        Task { @MainActor in TriageOutbox.shared.run() }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in await AppModel.shared.refresh() } }
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let api = api
            async let tasks = api.tasks()
            async let projects = api.projects()
            async let labels = api.labels()
            async let initiatives = api.initiatives()
            data = Snapshot(tasks: try await tasks, projects: try await projects, labels: try await labels, initiatives: try await initiatives, fetchedAt: Date())
            error = nil
            if let raw = try? JSONEncoder().encode(data) { try? raw.write(to: cacheURL) }
            Reminders.schedule(data.tasks)
            await refreshTriage()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /** Applies a change on screen at once, then sends it as a merge patch (NSNull clears). */
    func change(_ t: TaskItem, _ patch: [String: Any]) async {
        if let i = data.tasks.firstIndex(where: { $0.id == t.id }) {
            var n = data.tasks[i]
            if let s = patch["status"] as? String, let status = TaskStatus(rawValue: s) { n.status = status; if n.closed { n.overdue = false } }
            if let p = patch["priority"] as? String, let priority = Priority(rawValue: p) { n.priority = priority }
            if let title = patch["title"] as? String { n.title = title }
            if let d = patch["description"] as? String { n.description = d }
            data.tasks[i] = n
        }
        do { try await api.patchTask(t.id, patch) } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func create(_ req: Components.Schemas.CreateTaskRequest) async throws -> TaskItem {
        let t = try await api.create(req)
        await refresh()
        return t
    }

    func delete(_ t: TaskItem) async {
        data.tasks.removeAll { $0.id == t.id || $0.parentId == t.id }
        do { try await api.delete(t.id) } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func project(_ id: String?) -> Project? { data.projects.first { $0.id == id } }

    func refreshTriage() async {
        if let list = try? await api.triage() { triage = list }
    }

    /** Suggestions waiting for a decision, plus inputs the model hasn't read yet. */
    var triageCount: Int {
        triage.reduce(0) { n, i in n + (i.status == "pending" ? 1 : i.items.filter { $0.status == "pending" }.count) }
    }

    /** Changes Triage on screen at once, sends it, and puts it back if the server refuses. */
    func triageAction(_ change: ([TriageInput]) -> [TriageInput], _ send: @escaping () async throws -> Void) async {
        let before = triage
        triage = change(triage)
        do {
            try await send()
            await refreshTriage()
            if let t = try? await api.tasks() { data.tasks = t }
        } catch {
            triage = before
            self.error = error.localizedDescription
        }
    }

    func initiative(_ id: String?) -> Initiative? { data.initiatives?.first { $0.id == id } }

    /** Initiatives active first, then planned, then completed; by name within each. */
    var sortedInitiatives: [Initiative] {
        let order: [Initiative.statusPayload] = [.active, .planned, .completed]
        return (data.initiatives ?? []).sorted { a, b in
            let x = order.firstIndex(of: a.status) ?? 0, y = order.firstIndex(of: b.status) ?? 0
            return x != y ? x < y : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /** Applies a change to an initiative on screen at once (name, status, projects), then sends it as a merge patch. */
    func changeInitiative(_ id: String, _ patch: [String: Any]) async {
        if var list = data.initiatives, let i = list.firstIndex(where: { $0.id == id }) {
            if let name = patch["name"] as? String { list[i].name = name }
            if let s = patch["status"] as? String, let status = Initiative.statusPayload(rawValue: s) { list[i].status = status }
            if let ids = patch["projectIds"] as? [String] { list[i].projectIds = ids }
            if patch.keys.contains("targetDate") { list[i].targetDate = patch["targetDate"] as? String }
            if let d = patch["description"] as? String { list[i].description = d }
            data.initiatives = list
        }
        do { try await api.patchInitiative(id, patch) } catch { self.error = error.localizedDescription }
        await refresh()
    }

    /** Open projects for the sidebar: those in an active initiative, or in none (a finished semester's courses drop out). */
    var sidebarProjects: [Project] {
        let active = Set((data.initiatives ?? []).filter { $0.status == .active }.map(\.id))
        return data.projects.filter { p in
            p.state != .completed && p.state != .canceled && (p.initiativeIds.isEmpty || p.initiativeIds.contains { active.contains($0) })
        }
    }
}

/** Deadline reminders as local notifications: a day and an hour before; 9:00 the day before and on the day when there's no time. */
enum Reminders {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func schedule(_ tasks: [TaskItem]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date()
        var items: [(Date, TaskItem, String)] = []
        for t in tasks where !t.closed {
            guard let due = t.due, let day = dayFromString(due.date) else { continue }
            if let time = due.time, let h = Int(time.prefix(2)), let m = Int(time.dropFirst(3).prefix(2)) {
                let at = calendarKST.date(bySettingHour: h, minute: m, second: 0, of: day)!
                items.append((at.addingTimeInterval(-86_400), t, "Due tomorrow at \(time.prefix(5))"))
                items.append((at.addingTimeInterval(-3_600), t, "Due in an hour (\(time.prefix(5)))"))
            } else {
                let nine = calendarKST.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
                items.append((nine.addingTimeInterval(-86_400), t, "Due tomorrow"))
                items.append((nine, t, "Due today"))
            }
        }
        // macOS keeps at most 64 pending notifications per app: the soonest ones.
        for (i, (at, t, text)) in items.filter({ $0.0 > now }).sorted(by: { $0.0 < $1.0 }).prefix(60).enumerated() {
            let content = UNMutableNotificationContent()
            content.title = plainText(t.title)
            content.body = text
            content.userInfo = ["task": t.id]
            let parts = calendarKST.dateComponents(in: seoul, from: at)
            let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(timeZone: seoul, year: parts.year, month: parts.month, day: parts.day, hour: parts.hour, minute: parts.minute), repeats: false)
            center.add(UNNotificationRequest(identifier: "due-\(i)-\(t.id)", content: content, trigger: trigger))
        }
    }
}
