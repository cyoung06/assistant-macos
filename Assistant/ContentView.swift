import SwiftUI

enum Destination: Hashable {
    case active, backlog, all, project(String), calendar
}

/** Sidebar (task views, projects, calendar) and the selected list, with the task in an inspector. */
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var destination: Destination? = .active
    @State private var selected: String?
    @State private var creating = false

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Section("Tasks") {
                    Label("Active", systemImage: "circle.dotted.circle").tag(Destination.active)
                    Label("Backlog", systemImage: "tray").tag(Destination.backlog)
                    Label("All tasks", systemImage: "list.bullet").tag(Destination.all)
                }
                Section("Projects") {
                    ForEach(model.sidebarProjects, id: \.id) { p in
                        let open = model.data.tasks.filter { $0.projectId == p.id && !$0.closed }.count
                        HStack {
                            Circle().fill(Color(hex: p.color)).frame(width: 8, height: 8)
                            Text(p.name).lineLimit(1)
                            Spacer()
                            if open > 0 { Text("\(open)").foregroundStyle(.secondary).font(.caption) }
                        }
                        .tag(Destination.project(p.id))
                    }
                }
                Section {
                    Label("Calendar", systemImage: "calendar").tag(Destination.calendar)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            Group {
                switch destination ?? .active {
                case .calendar: CalendarView(selected: $selected)
                default: TaskListView(destination: destination ?? .active, selected: $selected)
                }
            }
            .toolbar {
                ToolbarItem { Button { creating = true } label: { Label("New task", systemImage: "square.and.pencil") }.keyboardShortcut("n") }
                ToolbarItem { Button { CapturePanel.shared.show() } label: { Label("Capture", systemImage: "camera.viewfinder") } }
                ToolbarItem { Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.keyboardShortcut("r") }
            }
        }
        // On the split view itself: inside its detail column AppKit asserts on the window's separators.
        .inspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            Group {
                if let id = selected { TaskDetailView(id: id, select: { selected = $0 }) }
            }
            .inspectorColumnWidth(min: 320, ideal: 380)
        }
        .sheet(isPresented: $creating) {
            CreateTaskView(projectId: { if case let .project(id) = destination { return id }; return nil }()) { creating = false }
                .environmentObject(model)
        }
        .onChange(of: model.openTask) { _, id in
            if let id { selected = id; model.openTask = nil }
        }
        .onOpenURL { url in openAppLink(url.absoluteString) }
        .environment(\.openURL, OpenURLAction { url in
            // Tasks and projects open here, mail in Apple Mail, PLMS and the rest in the browser.
            if openAppLink(url.absoluteString) { return .handled }
            return .systemAction
        })
    }

    @discardableResult
    private func openAppLink(_ url: String) -> Bool {
        if let target = externalTarget(url) { NSWorkspace.shared.open(target); return true }
        // Our pages: "<origin>/task/<id>", or "#task/<id>" in older text.
        if let m = url.firstMatch(of: /[\/#]task\/([0-9a-f-]{36})/) { selected = String(m.output.1); return true }
        if let m = url.firstMatch(of: /[\/#]tasks\/project\/([0-9a-f-]{36})/) { destination = .project(String(m.output.1)); return true }
        return false
    }
}

struct TaskListView: View {
    @EnvironmentObject private var model: AppModel
    let destination: Destination
    @Binding var selected: String?
    @State private var showClosed = false
    @State private var query = ""
    @State private var schedule: ProjectSchedule?

    var body: some View {
        let today = todayString
        let tasks = filtered
        let groups = groupByDue(tasks, today: today)
        let closed = (destination == .all || isProject) ? tasks.filter(\.closed).sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) } : []
        List(selection: $selected) {
            if let e = model.error { Text(e).foregroundStyle(.red) }
            if case let .project(id) = destination { ProjectScheduleSection(schedule: schedule, projectName: model.project(id)?.name ?? "") }
            ForEach(groups) { g in
                Section {
                    ForEach(g.tasks, id: \.id) { t in TaskRowView(task: t).tag(t.id) }
                } header: {
                    HStack { Text(g.label).foregroundStyle(g.danger ? .red : .primary); Text("\(g.tasks.count)").foregroundStyle(.secondary) }
                }
            }
            if !closed.isEmpty {
                // A plain list draws no disclosure chevron for Section(isExpanded:), so the header toggles it.
                Section {
                    if showClosed { ForEach(closed, id: \.id) { t in TaskRowView(task: t).tag(t.id) } }
                } header: {
                    Button { withAnimation { showClosed.toggle() } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(showClosed ? 90 : 0)).font(.caption.weight(.semibold))
                            Text("Closed")
                            Text("\(closed.count)").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if groups.isEmpty && closed.isEmpty { Text("Nothing here.").foregroundStyle(.secondary) }
        }
        .searchable(text: $query, prompt: "Search or #number")
        .navigationTitle(title)
        .task(id: String(describing: destination)) {
            schedule = nil
            if case let .project(id) = destination { schedule = try? await model.api.projectSchedule(id) }
        }
    }

    private var isProject: Bool { if case .project = destination { return true }; return false }

    private var title: String {
        switch destination {
        case .active: "Active"
        case .backlog: "Backlog"
        case .all: "All tasks"
        case let .project(id): model.project(id)?.name ?? "Project"
        case .calendar: "Calendar"
        }
    }

    private var filtered: [TaskItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.data.tasks.filter { t in
            let inView: Bool = switch destination {
            case .active: t.status == .todo || t.status == .in_progress
            case .backlog: t.status == .backlog
            case .all, .calendar: true
            case let .project(id): t.projectId == id
            }
            return inView && (q.isEmpty || plainText(t.title).lowercased().contains(q) || "#\(t.number)" == q)
        }
    }
}

struct TaskRowView: View {
    @EnvironmentObject private var model: AppModel
    let task: TaskItem

    var body: some View {
        let t = task
        HStack(spacing: 8) {
            Menu {
                ForEach(TaskStatus.allCases, id: \.self) { s in Button(statusLabel(s)) { Task { await model.change(t, ["status": s.rawValue]) } } }
            } label: { StatusIcon(status: t.status) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            PriorityIcon(priority: t.priority)
            Text("#\(t.number)").font(.caption).foregroundStyle(.tertiary).frame(width: 34, alignment: .leading)
            RefText(markdown: t.title).lineLimit(1).foregroundStyle(t.closed ? .secondary : .primary)
            if t.blocked { Text("Blocked").font(.caption2).padding(.horizontal, 5).background(.red.opacity(0.15), in: Capsule()).foregroundStyle(.red) }
            if t.subtasks > 0 { Text("\(t.subtasksDone)/\(t.subtasks)").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let p = model.project(t.projectId) {
                HStack(spacing: 4) { Circle().fill(Color(hex: p.color)).frame(width: 7, height: 7); Text(p.name).lineLimit(1) }.font(.caption).foregroundStyle(.secondary)
            }
            if let d = t.due {
                Text(dueText(d, today: todayString)).font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                    .foregroundStyle(t.closed ? Color.secondary : t.overdue ? .red : d.date <= addDays(todayString, 1) ? .orange : .secondary)
            }
            if let s = t.source { Text(s.uppercased()).font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 2)
    }
}

/** Text with references as links (tasks open in the app, others in the browser). */
struct RefText: View {
    let markdown: String
    var body: some View {
        var s = AttributedString()
        for p in refParts(markdown) {
            var part = AttributedString(p.url == nil ? p.text : "↗\u{2009}" + p.text)
            if let u = p.url, let url = URL(string: u) { part.link = url }
            s += part
        }
        return Text(s)
    }
}

struct StatusIcon: View {
    let status: TaskStatus
    var body: some View {
        switch status {
        case .backlog: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .todo: Image(systemName: "circle").foregroundStyle(.secondary)
        case .in_progress: Image(systemName: "circle.lefthalf.filled").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
        case .canceled: Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
    }
}

struct PriorityIcon: View {
    let priority: Priority
    var body: some View {
        switch priority {
        case .urgent: Image(systemName: "exclamationmark.square.fill").foregroundStyle(.red)
        case .high: Image(systemName: "cellularbars", variableValue: 1).foregroundStyle(.secondary)
        case .medium: Image(systemName: "cellularbars", variableValue: 0.66).foregroundStyle(.secondary)
        case .low: Image(systemName: "cellularbars", variableValue: 0.33).foregroundStyle(.secondary)
        case .none: Image(systemName: "minus").foregroundStyle(.tertiary)
        }
    }
}

extension Color {
    init(hex: String?) {
        let h = (hex ?? "#888888").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(h, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
