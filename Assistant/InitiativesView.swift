import SwiftUI

// Initiatives, as in Linear and on the web: a larger goal (a semester, a research effort) grouping projects.

private let statusLabels: [(Initiative.statusPayload, String)] = [(.active, "Active"), (.planned, "Planned"), (.completed, "Completed")]

private func progress(_ i: Initiative) -> Double { i.taskCount > 0 ? Double(i.doneCount) / Double(i.taskCount) : 0 }

private func targetText(_ day: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.timeZone = seoul
    f.dateFormat = "MMM d, yyyy"
    return f.string(from: midnight(day))
}

struct StatusMark: View {
    let status: Initiative.statusPayload
    var body: some View {
        switch status {
        case .active: Image(systemName: "circle.lefthalf.filled").foregroundStyle(.orange)
        case .planned: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
        }
    }
}

struct InitiativesView: View {
    @EnvironmentObject private var model: AppModel
    let open: (String) -> Void
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        List {
            HStack {
                TextField("New initiative name, Return to add", text: $name).textFieldStyle(.roundedBorder).onSubmit { Task { await add() } }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if model.sortedInitiatives.isEmpty {
                Text("No initiatives yet. Group projects toward a bigger goal, like a semester. PLMS adds one per semester.").foregroundStyle(.secondary)
            }
            ForEach(model.sortedInitiatives, id: \.id) { i in
                Button { open(i.id) } label: {
                    HStack(spacing: 10) {
                        StatusMark(status: i.status)
                        Text(i.name).fontWeight(.medium).lineLimit(1)
                        if let t = i.targetDate { Text(targetText(t)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text("\(i.projectIds.count) project\(i.projectIds.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: progress(i)).frame(width: 80)
                        Text("\(Int((progress(i) * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(i.doneCount) of \(i.taskCount) done")
            }
        }
        .navigationTitle("Initiatives")
    }

    private func add() async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        do {
            let id = try await model.api.createInitiative(name: n)
            name = ""
            await model.refresh()
            open(id)
        } catch { self.error = error.localizedDescription }
    }
}

struct InitiativeView: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    let back: () -> Void
    let openProject: (String) -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var confirmDelete = false
    @FocusState private var editing: Field?

    private enum Field { case name, description }

    var body: some View {
        if let i = model.initiative(id) {
            content(i)
                .onAppear { name = i.name; description = i.description }
                .onChange(of: id) { _, _ in name = model.initiative(id)?.name ?? ""; description = model.initiative(id)?.description ?? "" }
                // Text saves when it loses focus, as on the web.
                .onChange(of: editing) { old, _ in
                    if old == .name, !name.trimmingCharacters(in: .whitespaces).isEmpty, name != i.name { Task { await model.changeInitiative(id, ["name": name.trimmingCharacters(in: .whitespaces)]) } }
                    if old == .description, description != i.description { Task { await model.changeInitiative(id, ["description": description]) } }
                }
        } else {
            Text(model.loading ? "Loading…" : "No such initiative.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ i: Initiative) -> some View {
        let mine = model.data.projects.filter { i.projectIds.contains($0.id) }
        let others = model.data.projects.filter { !i.projectIds.contains($0.id) && $0.state != .completed && $0.state != .canceled }
        return List {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Initiative name", text: $name).textFieldStyle(.plain).font(.title2.weight(.semibold)).focused($editing, equals: .name).onSubmit { editing = nil }
                HStack(spacing: 12) {
                    Picker("Status", selection: Binding(get: { i.status }, set: { s in Task { await model.changeInitiative(id, ["status": s.rawValue]) } })) {
                        ForEach(statusLabels, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .fixedSize()
                    Toggle("Target", isOn: Binding(
                        get: { i.targetDate != nil },
                        set: { on in Task { await model.changeInitiative(id, ["targetDate": on ? dayString(Date()) : NSNull()]) } }
                    ))
                    if let t = i.targetDate {
                        DatePicker("", selection: Binding(get: { midnight(t) }, set: { d in Task { await model.changeInitiative(id, ["targetDate": dayString(d)]) } }), displayedComponents: .date).labelsHidden().fixedSize()
                    }
                    Spacer()
                    ProgressView(value: progress(i)).frame(width: 90)
                    Text("\(Int((progress(i) * 100).rounded()))% · \(i.doneCount)/\(i.taskCount) done").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                TextField("Add a description…", text: $description, axis: .vertical).textFieldStyle(.plain).lineLimit(2...12).focused($editing, equals: .description).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            Section {
                if mine.isEmpty { Text("No projects in this initiative yet.").foregroundStyle(.secondary) }
                ForEach(mine, id: \.id) { p in
                    let open = model.data.tasks.filter { $0.projectId == p.id && !$0.closed }.count
                    HStack {
                        Button { openProject(p.id) } label: {
                            HStack {
                                Circle().fill(Color(hex: p.color)).frame(width: 8, height: 8)
                                Text(p.name)
                                if p.state == .completed || p.state == .canceled { Text(p.state.rawValue.capitalized).font(.caption).foregroundStyle(.tertiary) }
                                Spacer()
                                if open > 0 { Text("\(open) open").font(.caption).foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { Task { await model.changeInitiative(id, ["projectIds": i.projectIds.filter { $0 != p.id }]) } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Remove from initiative")
                    }
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    if !others.isEmpty {
                        Menu("Add project…") {
                            ForEach(others, id: \.id) { p in Button(p.name) { Task { await model.changeInitiative(id, ["projectIds": i.projectIds + [p.id]]) } } }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
        }
        .navigationTitle(i.name)
        .toolbar {
            ToolbarItem(placement: .navigation) { Button { back() } label: { Label("Initiatives", systemImage: "chevron.left") }.help("All initiatives") }
            ToolbarItem { Button(role: .destructive) { confirmDelete = true } label: { Label("Delete initiative", systemImage: "trash") }.help("Delete initiative") }
        }
        .confirmationDialog("Delete \(i.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    do { try await model.api.deleteInitiative(id); back(); await model.refresh() } catch { model.error = error.localizedDescription }
                }
            }
        } message: { Text("Its projects stay.") }
    }
}

/** A project's initiatives, at the top of its task list, with a menu to add it to others. */
struct InitiativeChips: View {
    @EnvironmentObject private var model: AppModel
    let projectId: String

    var body: some View {
        let all = model.sortedInitiatives
        let mine = all.filter { $0.projectIds.contains(projectId) }
        let others = all.filter { !$0.projectIds.contains(projectId) && $0.status != .completed }
        HStack(spacing: 6) {
            ForEach(mine, id: \.id) { i in
                HStack(spacing: 4) {
                    StatusMark(status: i.status).font(.caption)
                    Text(i.name).font(.caption)
                    Button { Task { await model.changeInitiative(i.id, ["projectIds": i.projectIds.filter { $0 != projectId }]) } } label: { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.borderless).help("Remove from \(i.name)")
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            if !others.isEmpty {
                Menu {
                    ForEach(others, id: \.id) { i in Button(i.name) { Task { await model.changeInitiative(i.id, ["projectIds": i.projectIds + [projectId]]) } } }
                } label: { Label(mine.isEmpty ? "Add to initiative" : "Add", systemImage: "flag").font(.caption) }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            Spacer()
        }
    }
}
