import SwiftUI

/** The menu bar: overdue and due today, tick them off, capture, open the app. */
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let today = todayString
        let due = sortTasks(model.data.tasks.filter { !$0.closed && ($0.overdue || ($0.due?.date ?? "~") <= today) })
        VStack(alignment: .leading, spacing: 8) {
            Text(due.isEmpty ? "Nothing due today" : "Due · \(due.count)").font(.headline)
            ForEach(due, id: \.id) { t in
                HStack {
                    Button { Task { await model.change(t, ["status": "done"]) } } label: { Image(systemName: "circle") }.buttonStyle(.plain)
                    Button {
                        model.openTask = t.id
                        openWindow(id: "main")
                        NSApp.activate()
                    } label: {
                        Text(plainText(t.title)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    if let d = t.due { Text(dueText(d, today: today)).font(.caption).foregroundStyle(t.overdue ? .red : .secondary) }
                }
            }
            Divider()
            HStack {
                Button("Capture… ⌥Space") { CapturePanel.shared.show() }
                Button("Quick Note ⌃⌥N") { QuickNote.make() }
                Spacer()
                Button("Open") { openWindow(id: "main"); NSApp.activate() }
            }
            if let e = model.error { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .padding(12)
        .frame(width: 320)
        .task { await model.refresh() }
    }
}
