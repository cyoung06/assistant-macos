import AssistantAPI
import SwiftUI

/** One task: title and description with references, properties, sub-tasks, attachments. */
struct TaskDetailView: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    var select: (String?) -> Void
    @State private var editingTitle = false
    @State private var editingDescription = false
    @State private var titleDraft = ""
    @State private var descriptionDraft = ""
    @State private var newSub = ""
    @State private var confirmDelete = false

    var body: some View {
        if let t = model.data.tasks.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("#\(t.number)").foregroundStyle(.secondary)
                        Spacer()
                        if let u = t.url, let url = URL(string: u) { Link("Open in \(t.source?.uppercased() ?? "source")", destination: url) }
                    }
                    title(t)
                    properties(t)
                    description(t)
                    if !t.attachments.isEmpty { attachments(t) }
                    subtasks(t)
                    if !t.relations.isEmpty {
                        Divider()
                        Text("Relations").font(.headline)
                        ForEach(t.relations, id: \.id) { r in
                            Button("\(r.kind.rawValue.replacingOccurrences(of: "_", with: " ")): #\(r.task.number) \(plainText(r.task.title))") { select(r.task.id) }.buttonStyle(.link)
                        }
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button("Delete", role: .destructive) { confirmDelete = true }
                    }
                }
                .padding(16)
            }
            .confirmationDialog(t.subtasks > 0 ? "Delete with \(t.subtasks) sub-tasks?" : "Delete this task?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { select(nil); Task { await model.delete(t) } }
            }
        } else {
            Text("This task isn't here (anymore).").foregroundStyle(.secondary).padding()
        }
    }

    @ViewBuilder private func title(_ t: TaskItem) -> some View {
        if editingTitle {
            MentionField(api: model.api, text: $titleDraft, prompt: "Title", axis: .vertical)
            HStack {
                Button("Cancel") { editingTitle = false }
                Button("Save") {
                    editingTitle = false
                    if !titleDraft.trimmingCharacters(in: .whitespaces).isEmpty { Task { await model.change(t, ["title": titleDraft.trimmingCharacters(in: .whitespaces)]) } }
                }.keyboardShortcut(.defaultAction)
            }
        } else {
            RefText(markdown: t.title).font(.title2.weight(.semibold))
                .onTapGesture { if t.source == nil { titleDraft = t.title; editingTitle = true } }
                .help(t.source == nil ? "Click to edit" : "Set in \(t.source!.uppercased())")
        }
    }

    @ViewBuilder private func properties(_ t: TaskItem) -> some View {
        Grid(alignment: .leading, verticalSpacing: 8) {
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { t.status }, set: { s in Task { await model.change(t, ["status": s.rawValue]) } })) {
                    ForEach(TaskStatus.allCases, id: \.self) { Text(statusLabel($0)).tag($0) }
                }.labelsHidden()
            }
            GridRow {
                Text("Priority").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { t.priority }, set: { p in Task { await model.change(t, ["priority": p.rawValue]) } })) {
                    ForEach(Priority.allCases, id: \.self) { Text(priorityLabel($0)).tag($0) }
                }.labelsHidden()
            }
            GridRow {
                Text("Due").foregroundStyle(.secondary)
                if t.source != nil {
                    Text((t.due.map { dueText($0, today: todayString) } ?? "none") + " · set in \(t.source!.uppercased())").foregroundStyle(t.overdue ? .red : .secondary)
                } else {
                    DueEditor(due: t.due) { due in
                        Task { await model.change(t, ["due": due.map { d -> Any in var o: [String: Any] = ["date": d.date]; if let time = d.time { o["time"] = time }; return o } ?? NSNull()]) }
                    }
                }
            }
            GridRow {
                Text("Project").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { t.projectId }, set: { p in Task { await model.change(t, ["projectId": p ?? NSNull()]) } })) {
                    Text("No project").tag(String?.none)
                    ForEach(model.data.projects, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden()
            }
            GridRow {
                Text("Labels").foregroundStyle(.secondary)
                Menu(t.labelIds.compactMap { id in model.data.labels.first { $0.id == id }?.name }.joined(separator: ", ").ifEmpty("Add labels")) {
                    ForEach(model.data.labels, id: \.id) { l in
                        Toggle(l.name, isOn: Binding(get: { t.labelIds.contains(l.id) }, set: { on in
                            let ids = on ? t.labelIds + [l.id] : t.labelIds.filter { $0 != l.id }
                            Task { await model.change(t, ["labelIds": ids]) }
                        }))
                    }
                }.fixedSize()
            }
        }
    }

    @ViewBuilder private func description(_ t: TaskItem) -> some View {
        if editingDescription {
            MentionField(api: model.api, text: $descriptionDraft, prompt: "Description (@ to reference)", axis: .vertical)
            HStack {
                Button("Cancel") { editingDescription = false }
                Button("Save") { editingDescription = false; Task { await model.change(t, ["description": descriptionDraft]) } }
            }
        } else {
            Group {
                if t.description.isEmpty { Text("Add description…").foregroundStyle(.tertiary) } else { RefText(markdown: t.description) }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { descriptionDraft = t.description; editingDescription = true }
        }
    }

    @ViewBuilder private func attachments(_ t: TaskItem) -> some View {
        Divider()
        Text("Attachments").font(.headline)
        ScrollView(.horizontal) {
            HStack { ForEach(t.attachments, id: \.id) { a in AttachmentThumb(info: a) } }
        }
    }

    @ViewBuilder private func subtasks(_ t: TaskItem) -> some View {
        Divider()
        let subs = model.data.tasks.filter { $0.parentId == t.id }.sorted { $0.number < $1.number }
        Text(subs.isEmpty ? "Sub-tasks" : "Sub-tasks \(t.subtasksDone)/\(t.subtasks)").font(.headline)
        ForEach(subs, id: \.id) { s in
            HStack {
                Button { Task { await model.change(s, ["status": s.closed ? "todo" : "done"]) } } label: { StatusIcon(status: s.status) }.buttonStyle(.plain)
                Button("#\(s.number) \(plainText(s.title))") { select(s.id) }.buttonStyle(.plain).foregroundStyle(s.closed ? .secondary : .primary)
            }
        }
        TextField("Add sub-task", text: $newSub)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                let title = newSub.trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { return }
                newSub = ""
                Task { _ = try? await model.create(.init(parentId: t.id, projectId: t.projectId, title: title)) }
            }
    }
}

struct AttachmentThumb: View {
    @EnvironmentObject private var model: AppModel
    let info: Components.Schemas.AttachmentInfo
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() } else { Text(info.filename).font(.caption).padding(4) }
        }
        .frame(width: 120, height: 88).clipped().background(.quaternary).cornerRadius(6)
        .onTapGesture { NSWorkspace.shared.open(model.api.base.appending(path: "api/v1/attachments/\(info.id)")) }
        .task { if info.contentType.hasPrefix("image/"), let data = try? await model.api.download(info.id) { image = NSImage(data: data) } }
    }
}

/** Quick due dates, a date picker, and an optional time. */
struct DueEditor: View {
    let due: Due?
    var onChange: (Due?) -> Void
    @State private var picking = false
    @State private var date = Date()
    @State private var withTime = false

    var body: some View {
        HStack(spacing: 6) {
            Text(due.map { dueText($0, today: todayString) } ?? "None")
            Menu("Change") {
                ForEach(dueChoices(today: todayString), id: \.1) { label, day in Button(label) { onChange(Due(date: day, time: due?.time)) } }
                Button("Pick a date…") { date = due.flatMap { dayFromString($0.date) } ?? Date(); withTime = due?.time != nil; picking = true }
                if due != nil { Button("No due date") { onChange(nil) } }
            }.fixedSize()
        }
        .popover(isPresented: $picking) {
            VStack(alignment: .leading) {
                DatePicker("", selection: $date, displayedComponents: withTime ? [.date, .hourAndMinute] : [.date]).datePickerStyle(.graphical).labelsHidden()
                Toggle("Time", isOn: $withTime)
                Button("Set") {
                    let f = DateFormatter()
                    f.timeZone = seoul
                    f.dateFormat = "HH:mm"
                    onChange(Due(date: dayString(date), time: withTime ? f.string(from: date) : nil))
                    picking = false
                }.keyboardShortcut(.defaultAction)
            }.padding()
        }
    }
}

struct CreateTaskView: View {
    @EnvironmentObject private var model: AppModel
    var projectId: String?
    var onDone: () -> Void
    @State private var title = ""
    @State private var description = ""
    @State private var due: Due?
    @State private var project: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New task").font(.headline)
            MentionField(api: model.api, text: $title, prompt: "Title (@ to reference)")
            MentionField(api: model.api, text: $description, prompt: "Description", axis: .vertical)
            HStack {
                DueEditor(due: due) { due = $0 }
                Spacer()
                Picker("", selection: $project) {
                    Text("No project").tag(String?.none)
                    ForEach(model.data.projects, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(maxWidth: 200)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Create task") {
                    Task {
                        do {
                            _ = try await model.create(.init(description: description, due: due, projectId: project, title: title.trimmingCharacters(in: .whitespaces)))
                            onDone()
                        } catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { project = projectId }
    }
}

extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
