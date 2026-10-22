import AppKit
import SwiftUI

/**
 * The web's keys, here too, when nothing's being typed into: C new task, Q quick note, G then D / T /
 * P / C / I / F to go to Today, tasks, projects, the calendar, Triage, Files, ? this list; in a list,
 * J / K down and up, X done (again: reopen). Keys with ⌘, ⌥ or ⌃ are the menus'.
 */
@MainActor
final class Keys {
    static let shared = Keys()
    private var monitor: Any?
    private var pendingG = Date.distantPast
    /** What the keys do, set by the window's content. */
    var newTask: () -> Void = {}
    var go: (Destination) -> Void = { _ in }
    var markDone: () -> Void = {}
    var showList: () -> Void = {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
    }

    /** The key's doing, or the event as it was (for whatever takes it next). */
    private func handle(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(), !typing(in: event.window) else { return event }
        if Date.now.timeIntervalSince(pendingG) < 1.2 {
            pendingG = .distantPast
            let to: Destination? = switch key {
            case "d": .today
            case "t": .active
            case "p": .initiatives
            case "c": .calendar
            case "i": .triage
            case "f": .files
            default: nil
            }
            if let to { go(to); return nil }
            return event
        }
        switch event.characters {
        case "?": showList(); return nil
        default: break
        }
        switch key {
        case "g": pendingG = .now; return nil
        case "c": newTask(); return nil
        case "q": QuickNote.make(); return nil
        case "x": markDone(); return nil
        // J and K as the arrow keys (the list moves its selection itself).
        case "j": return arrow(event, keyCode: 125, char: NSDownArrowFunctionKey)
        case "k": return arrow(event, keyCode: 126, char: NSUpArrowFunctionKey)
        default: return event
        }
    }

    /** Whether text is being typed into (a field or a note being edited). */
    private func typing(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextField
    }

    private func arrow(_ event: NSEvent, keyCode: UInt16, char: Int) -> NSEvent? {
        let s = String(Character(UnicodeScalar(char)!))
        return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: [.numericPad, .function], timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: event.isARepeat, keyCode: keyCode)
    }
}

/** The keys, as on the web: a sheet listing them (?). */
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    private let keys: [(String, String)] = [
        ("⌘K", "Go to, make, or find anything"),
        ("C  or  ⌘N", "New task"),
        ("Q  or  ⌃⌥N", "Quick note, for the class on now (⌃⌥N from any app)"),
        ("⌥Space", "Capture, from any app"),
        ("G then D / T / P / C / I / F", "Go to today / tasks / projects / calendar / triage / files"),
        ("J / K", "Next / previous"),
        ("X", "Mark done (again: reopen)"),
        ("1 / 3", "Accept / decline (in Triage)"),
        ("⌘E  ·  ⌘↩", "Edit a note · done editing"),
        ("⌘B / ⌘I / ⌘K", "Bold / italic / link (in a note)"),
        ("⌘R", "Refresh"),
        ("?", "This list"),
        ("S / P / D / L / M", "Status, priority, due, labels, move (on the web)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard Shortcuts").font(.title2.bold())
            Grid(alignment: .leading, verticalSpacing: 6) {
                ForEach(keys, id: \.0) { k, what in
                    GridRow {
                        Text(k).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        Text(what)
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520)
    }
}
