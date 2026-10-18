import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var server = ""

    var body: some View {
        Form {
            TextField("Server", text: $server)
            HStack {
                Button("Save & sync") { model.serverURL = server; Task { await model.refresh() } }
                Button("Default") { server = Defaults.server }
            }
            Text("The Mac reaches the server over Tailscale; keep the Tailscale app running.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Capture from anywhere with ⌥Space, the Share menu, or by dropping screenshots on the Dock icon.").font(.caption)
            Text("Reminders: a day and an hour before each deadline; 9:00 the day before and on the day for date-only tasks.").font(.caption)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { server = model.serverURL }
    }
}
