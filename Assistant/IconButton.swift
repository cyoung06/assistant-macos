import SwiftUI

/** A bar's action shown as its icon, as the Android app's are: its name is the tooltip and what VoiceOver reads. */
struct IconButton: View {
    let title: String
    let symbol: String
    var role: ButtonRole? = nil
    let action: () -> Void

    init(_ title: String, symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(minWidth: 20, minHeight: 20)
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}

/** An on/off bar setting shown as its icon (highlighted while on). */
struct IconToggle: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    init(_ title: String, symbol: String, isOn: Binding<Bool>) {
        self.title = title
        self.symbol = symbol
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(minWidth: 20, minHeight: 20)
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .foregroundStyle(isOn ? Color.accentColor : Color.primary)
        .help(title)
    }
}
