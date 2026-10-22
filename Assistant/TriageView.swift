import SwiftUI

/**
 * Triage, as on the web: what was shared or came in by mail, read by the model, with suggestions to
 * accept (a task or event is made) or decline. Keys: J/K to move, 1 to accept, 3 to decline.
 */
struct TriageView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var outbox = TriageOutbox.shared
    @Binding var selectedTask: String?
    @State private var selected: String?
    @State private var edits: [String: Edit] = [:]
    @State private var showMaybe = false
    @State private var showNothing = false
    @FocusState private var focused: Bool

    struct Edit { var title: String; var projectId: String? }

    private var undecided: [TriageInput] { model.triage.filter { $0.items.contains { $0.status == "pending" } } }
    private var open: [TriageInput] { undecided.filter { $0.verdict != "maybe" } }
    private var maybe: [TriageInput] { undecided.filter { $0.verdict == "maybe" } }
    private var reading: [TriageInput] { model.triage.filter { $0.status == "pending" } }
    private var failed: [TriageInput] { model.triage.filter { $0.status == "failed" } }
    private var nothing: [TriageInput] { model.triage.filter { $0.status == "done" && $0.items.isEmpty } }
    private var pendingItems: [TriageItem] { (open + (showMaybe ? maybe : [])).flatMap { $0.items.filter { $0.status == "pending" } } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(outbox.jobs) { j in OutboxCard(job: j) }
                if open.isEmpty && reading.isEmpty && failed.isEmpty && outbox.jobs.isEmpty {
                    Text("All clear. Share a screenshot (⌥Space, the Share menu, or drop it here); the model reads it and suggests tasks here.")
                        .foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(reading, id: \.id) { i in InputCard(input: i) { Text(i.error.map { "Waiting: \($0)" } ?? "Reading…").foregroundStyle(.secondary) } }
                ForEach(open, id: \.id) { i in InputCard(input: i) { suggestions(i) } }
                if !maybe.isEmpty {
                    Fold(title: "Maybe", detail: "\(maybe.count) · might not apply to you", open: $showMaybe)
                    if showMaybe { ForEach(maybe, id: \.id) { i in InputCard(input: i) { suggestions(i) } } }
                }
                ForEach(failed, id: \.id) { i in InputCard(input: i) { Text("Couldn't read this: \(i.error ?? "")").foregroundStyle(.red) } }
                if !nothing.isEmpty {
                    Fold(title: "Nothing to do", detail: "\(nothing.count)", open: $showNothing)
                    if showNothing { ForEach(nothing, id: \.id) { i in InputCard(input: i) { EmptyView() } } }
                }
            }
            .padding(16)
        }
        .navigationTitle("Triage")
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(characters: CharacterSet(charactersIn: "jk13")) { press in key(press.characters) }
        // J and K come as the arrow keys (see Keys), as everywhere.
        .onKeyPress(.downArrow) { key("j") }
        .onKeyPress(.upArrow) { key("k") }
        .task {
            // While the model is reading, look again every few seconds.
            while !Task.isCancelled {
                await model.refreshTriage()
                try? await Task.sleep(for: .seconds(model.triage.contains { $0.status == "pending" } ? 5 : 30))
            }
        }
        .dropDestination(for: Data.self) { items, _ in
            sendImages(items)
            return !items.isEmpty
        }
    }

    @ViewBuilder private func suggestions(_ i: TriageInput) -> some View {
        ForEach(i.items, id: \.id) { item in
            if item.status == "pending" {
                SuggestionRow(
                    item: item,
                    edit: edit(item),
                    selected: item.id == (selected ?? pendingItems.first?.id),
                    onEdit: { edits[item.id] = $0 },
                    onSelect: { selected = item.id },
                    onAccept: { decide(item, accept: true) },
                    onDecline: { decide(item, accept: false) },
                    onOpenTask: { selectedTask = $0 }
                )
            } else {
                HStack {
                    Text(item.proposal.kind == "event" ? "Event" : "Task").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    Text(item.proposal.title).foregroundStyle(.secondary)
                    Spacer()
                    Text(item.status == "accepted" ? "Accepted" : "Declined").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func edit(_ item: TriageItem) -> Edit { edits[item.id] ?? Edit(title: item.proposal.title, projectId: item.proposal.projectId) }

    private func decide(_ item: TriageItem, accept: Bool) {
        let list = pendingItems
        let i = list.firstIndex { $0.id == item.id } ?? 0
        selected = list.indices.contains(i + 1) ? list[i + 1].id : (i > 0 ? list[i - 1].id : nil)
        var proposal = item.proposal
        let e = edit(item)
        proposal.title = e.title
        proposal.projectId = e.projectId
        let status = accept ? "accepted" : "declined"
        Task {
            await model.triageAction({ inputs in
                inputs.map { input in
                    var input = input
                    input.items = input.items.map { var x = $0; if x.id == item.id { x.status = status }; return x }
                    return input
                }
            }) {
                if accept { try await model.api.acceptTriage(item.id, proposal) } else { try await model.api.declineTriage(item.id) }
            }
        }
    }

    private func key(_ c: String) -> KeyPress.Result {
        let list = pendingItems
        guard !list.isEmpty else { return .ignored }
        let i = list.firstIndex { $0.id == selected } ?? 0
        switch c {
        case "j": selected = list[min(i + 1, list.count - 1)].id
        case "k": selected = list[max(i - 1, 0)].id
        case "1": decide(list[i], accept: true)
        case "3": decide(list[i], accept: false)
        default: return .ignored
        }
        return .handled
    }

    /** Images dropped on the list go to Triage, sent in the background. */
    private func sendImages(_ items: [Data]) {
        let images = items.filter { NSImage(data: $0) != nil }.map { CapturedImage(data: $0, name: "screenshot.png", mimeType: "image/png") }
        if !images.isEmpty { TriageOutbox.shared.send(text: "", images: images) }
    }
}

/** Handed to Triage, still on its way to the server. */
private struct OutboxCard: View {
    let job: TriageJob
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("SENDING").font(.caption2.bold()).foregroundStyle(.tertiary)
            Text(job.title.isEmpty ? (job.images.isEmpty ? String(job.text.prefix(60)) : "\(job.images.count) screenshot\(job.images.count == 1 ? "" : "s")") : job.title).lineLimit(1)
            if let e = job.error { Text("Retrying: \(e)").font(.caption).foregroundStyle(.orange).lineLimit(1) }
            Spacer()
            if job.error != nil { Button("Discard") { TriageOutbox.shared.discard(job.id) }.controlSize(.small) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

private struct Fold: View {
    let title: String
    let detail: String
    @Binding var open: Bool
    var body: some View {
        Button { withAnimation { open.toggle() } } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).font(.caption.weight(.semibold))
                Text(title).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }
}

private let triageSources = ["share": "Shared", "capture": "Captured", "addin": "From Outlook", "mail": "Mail", "chatgpt": "From ChatGPT"]

/** One input: where it came from, its screenshots, the model's reason, and what's inside. */
private struct InputCard<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    let input: TriageInput
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text((triageSources[input.source] ?? input.source).uppercased()).font(.caption2.bold()).foregroundStyle(.tertiary)
                if let link = input.link, let url = externalTarget(link) {
                    Button { NSWorkspace.shared.open(url) } label: { Label(input.title, systemImage: "envelope").lineLimit(1) }.buttonStyle(.link)
                } else {
                    Text(input.title).fontWeight(.semibold).lineLimit(1)
                }
                if let sender = input.sender { Text(sender.replacingOccurrences(of: #"\s*<.*>$"#, with: "", options: .regularExpression)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text(input.createdAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if input.status != "pending" {
                    Button("Read again") { Task { await model.triageAction({ $0 }) { try await model.api.retryTriage(input.id) } } }.controlSize(.small)
                }
                Button("Dismiss") { Task { await model.triageAction({ $0.filter { $0.id != input.id } }) { try await model.api.dismissTriage(input.id) } } }.controlSize(.small)
            }
            if !input.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(input.attachments, id: \.id) { a in
                            AsyncImage(url: model.api.attachmentURL(a.id)) { $0.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.1) }
                                .frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 6))
                                .onTapGesture { NSWorkspace.shared.open(model.api.attachmentURL(a.id)) }
                        }
                    }
                }
            }
            if let reason = input.reason { Text((input.verdict == "nothing" ? "Nothing to do: " : "") + reason).font(.callout).foregroundStyle(.secondary) }
            content()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

private struct SuggestionRow: View {
    @EnvironmentObject private var model: AppModel
    let item: TriageItem
    let edit: TriageView.Edit
    let selected: Bool
    let onEdit: (TriageView.Edit) -> Void
    let onSelect: () -> Void
    let onAccept: () -> Void
    let onDecline: () -> Void
    let onOpenTask: (String) -> Void

    var body: some View {
        let p = item.proposal
        HStack(alignment: .top, spacing: 10) {
            Text(p.kind == "event" ? "Event" : "Task").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading).padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: Binding(get: { edit.title }, set: { onEdit(.init(title: $0, projectId: edit.projectId)) }))
                    .textFieldStyle(.plain).fontWeight(.semibold)
                HStack(spacing: 8) {
                    Text(when(p)).font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { edit.projectId ?? "" }, set: { onEdit(.init(title: edit.title, projectId: $0.isEmpty ? nil : $0)) })) {
                        Text("No project").tag("")
                        ForEach(model.data.projects.filter { $0.state != .completed && $0.state != .canceled }, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().controlSize(.small).frame(maxWidth: 180)
                    if let same = item.sameAs, let t = model.data.tasks.first(where: { $0.number == same }) {
                        Button("Looks like #\(same)") { onOpenTask(t.id) }.buttonStyle(.link).font(.caption).foregroundStyle(.orange)
                    }
                }
                if !p.description.isEmpty { Text(p.description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
            Spacer()
            Button("Accept", action: onAccept).buttonStyle(.borderedProminent).help("Accept (1)")
            Button("Decline", action: onDecline).help("Decline (3)")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private func when(_ p: Proposal) -> String {
        let f = DateFormatter()
        f.timeZone = seoul
        f.locale = Locale(identifier: "en_US")
        if p.kind == "event" {
            if let d = p.startDate { return d }
            if let s = p.start {
                f.dateFormat = "EEE, MMM d HH:mm"
                let start = f.string(from: s)
                f.dateFormat = "HH:mm"
                return start + (p.end.map { "–" + f.string(from: $0) } ?? "")
            }
            return ""
        }
        return p.due.map { "Due " + dueText($0, today: todayString) } ?? "No due date"
    }
}
