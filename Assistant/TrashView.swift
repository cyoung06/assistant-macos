import SwiftUI

/**
 * The drive's trash: what was deleted (here, on the web, on the tablet, or in Finder), kept 30 days.
 * Each can be put back where it was, or deleted for good; or the whole trash emptied.
 */
struct TrashView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Trashed] = []
    @State private var loading = true
    @State private var error: String?
    @State private var restored: String?
    @State private var purging: Trashed?
    @State private var emptying = false
    private var api: API { AppModel.shared.api }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Trash").font(.headline)
                Text("Deleted things are kept 30 days.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Empty Trash…") { emptying = true }.disabled(items.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if let error { Text(error).foregroundStyle(.red).font(.caption).padding(8) }
            if let restored { Text("Put back to \(restored)").font(.caption).foregroundStyle(.secondary).padding(8) }
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text("The trash is empty.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { t in
                    HStack(spacing: 10) {
                        Image(systemName: t.folder ? "folder" : driveIcon(driveKind(t.name, folder: false))).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).lineLimit(1).truncationMode(.middle)
                            Text("from \(driveParent(t.path).replacingOccurrences(of: "Projects/", with: "").nilIfEmpty ?? "the drive") · \(t.deletedAt.formatted(date: .abbreviated, time: .shortened))\(t.folder ? "" : " · " + driveSize(t.size))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        IconButton("Put Back", symbol: "arrow.uturn.backward") { act { restored = try await api.driveRestore(t.id) } }
                        IconButton("Delete for Good…", symbol: "trash.slash") { purging = t }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .task { await load() }
        .confirmationDialog("Delete “\(purging?.name ?? "")” for good?", isPresented: Binding(get: { purging != nil }, set: { if !$0 { purging = nil } })) {
            Button("Delete for Good", role: .destructive) { if let t = purging { act { try await api.drivePurge(t.id) } } }
        } message: {
            Text("It can't be put back after this.")
        }
        .confirmationDialog("Empty the trash?", isPresented: $emptying) {
            Button("Empty Trash", role: .destructive) { act { try await api.driveEmptyTrash() } }
        } message: {
            Text("Everything in it is deleted for good.")
        }
    }

    private func load() async {
        do { items = try await api.driveTrash(); error = nil } catch { self.error = error.localizedDescription }
        loading = false
    }

    /** Does [work], then shows the trash as it is now (and the drive's folders, which it may have changed). */
    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            await load()
            await DriveStore.shared.reloadAll()
            DriveDomain.changed()
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
