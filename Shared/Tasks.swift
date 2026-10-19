import Foundation

// What tasks mean on screen; the same rules as the web app (src/tasks/model.ts).

extension TaskItem {
    var closed: Bool { status == .done || status == .canceled }
}

func statusLabel(_ s: TaskStatus) -> String {
    switch s {
    case .backlog: "Backlog"
    case .todo: "Todo"
    case .in_progress: "In Progress"
    case .done: "Done"
    case .canceled: "Canceled"
    }
}

func priorityLabel(_ p: Priority) -> String {
    switch p {
    case .urgent: "Urgent"
    case .high: "High"
    case .medium: "Medium"
    case .low: "Low"
    case .none: "No priority"
    }
}

private let priorityRank: [Priority: Int] = [.urgent: 0, .high: 1, .medium: 2, .low: 3, .none: 4]

let seoul = TimeZone(identifier: "Asia/Seoul")!

var calendarKST: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = seoul
    c.firstWeekday = 1
    return c
}

/** "2026-10-20" for a day in Seoul. */
func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

func dayFromString(_ s: String) -> Date? { dayFormatter.date(from: s) }

/** Made once: creating a DateFormatter is slow, and calendar views convert thousands of days. */
private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = calendarKST
    f.timeZone = seoul
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func addDays(_ day: String, _ n: Int) -> String {
    dayString(calendarKST.date(byAdding: .day, value: n, to: dayFromString(day)!)!)
}

/** The last day of the week (Saturday; weeks start on Sunday). */
func weekEnd(_ today: String) -> String {
    let weekday = calendarKST.component(.weekday, from: dayFromString(today)!)  // 1 = Sunday
    return addDays(today, 7 - weekday)
}

enum Bucket: String, CaseIterable {
    case overdue = "Overdue", today = "Today", week = "This week", later = "Later", none = "No due date"
}

func bucket(_ t: TaskItem, today: String) -> Bucket {
    guard let due = t.due else { return .none }
    if t.overdue { return .overdue }
    if due.date <= today { return .today }
    if due.date <= weekEnd(today) { return .week }
    return .later
}

func sortTasks(_ tasks: [TaskItem]) -> [TaskItem] {
    tasks.sorted { a, b in
        let pa = priorityRank[a.priority] ?? 4, pb = priorityRank[b.priority] ?? 4
        if pa != pb { return pa < pb }
        let da = a.due.map { $0.date + "T" + ($0.time ?? "24:00") } ?? "~", db = b.due.map { $0.date + "T" + ($0.time ?? "24:00") } ?? "~"
        if da != db { return da < db }
        return a.number > b.number
    }
}

struct TaskGroup: Identifiable {
    let id: String
    let label: String
    let tasks: [TaskItem]
    var danger = false
}

func groupByDue(_ tasks: [TaskItem], today: String) -> [TaskGroup] {
    let open = tasks.filter { !$0.closed }
    return Bucket.allCases.map { b in TaskGroup(id: b.rawValue, label: b.rawValue, tasks: sortTasks(open.filter { bucket($0, today: today) == b }), danger: b == .overdue) }
        .filter { !$0.tasks.isEmpty }
}

/** "Today 19:00", "Tomorrow", "Fri", "Nov 2". */
func dueText(_ due: Due, today: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.timeZone = seoul
    let date = dayFromString(due.date)!
    let day: String
    if due.date == today { day = "Today" }
    else if due.date == addDays(today, 1) { day = "Tomorrow" }
    else if due.date == addDays(today, -1) { day = "Yesterday" }
    else if due.date > today && due.date <= addDays(today, 6) { f.dateFormat = "EEE"; day = f.string(from: date) }
    else { f.dateFormat = "MMM d"; day = f.string(from: date) }
    return due.time.map { "\(day) \($0.prefix(5))" } ?? day
}

/** Today, Tomorrow, End of week (Friday), Next week (Monday); a day named twice keeps its first name. */
func dueChoices(today: String) -> [(String, String)] {
    let weekday = calendarKST.component(.weekday, from: dayFromString(today)!) // 1 = Sunday
    func next(_ target: Int) -> String { let d = (target - weekday + 7) % 7; return addDays(today, d == 0 ? 7 : d) }
    var seen = Set<String>()
    return [("Today", today), ("Tomorrow", addDays(today, 1)), ("End of week", next(6)), ("Next week", next(2))].filter { seen.insert($0.1).inserted }
}

var todayString: String { dayString(Date()) }

// ---- references: Markdown links `[title](url)` ----------------------------------------

private let linkPattern = try! NSRegularExpression(pattern: #"\[((?:\\.|[^\]\\])*)\]\(((?:[^()\s]|\([^()\s]*\))+)\)"#)

private func unescapeBrackets(_ s: String) -> String { s.replacingOccurrences(of: "\\[", with: "[").replacingOccurrences(of: "\\]", with: "]") }

struct RefPart: Hashable {
    let text: String
    let url: String?
}

func refParts(_ markdown: String) -> [RefPart] {
    let ns = markdown as NSString
    var out: [RefPart] = []
    var last = 0
    for m in linkPattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
        if m.range.location > last { out.append(RefPart(text: ns.substring(with: NSRange(location: last, length: m.range.location - last)), url: nil)) }
        out.append(RefPart(text: unescapeBrackets(ns.substring(with: m.range(at: 1))), url: ns.substring(with: m.range(at: 2))))
        last = m.range.location + m.range.length
    }
    if last < ns.length { out.append(RefPart(text: ns.substring(from: last), url: nil)) }
    return out
}

func plainText(_ markdown: String) -> String { refParts(markdown).map(\.text).joined() }

func refMarkdown(_ title: String, _ url: String) -> String {
    let t = title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    return "[\(t)](\(url.replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20")))"
}

/** A marker for what a reference points to. */
func refSymbol(_ url: String) -> String {
    if url.hasPrefix("mid:") || url.contains("#mail/") { return "envelope" }
    if url.hasPrefix("plms:") || url.contains("plms.postech.ac.kr") { return "graduationcap" }
    if url.contains("/tasks/project/") || url.contains("#tasks/project/") { return "square.grid.2x2" }
    if url.contains("/task/") || url.contains("#task/") { return "circle" }
    if url.contains("/event/") || url.contains("#event/") { return "calendar" }
    if let m = url.firstMatch(of: /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+(?:\/(issues|pull)\/\d+)?/) {
        switch m.output.1 { case "pull": return "arrow.triangle.pull"; case "issues": return "smallcircle.filled.circle"; default: return "book.closed" }
    }
    return "link"
}

let plmsBase = "https://plms.postech.ac.kr"

/**
 * Where a link to something outside the app opens: a mail (`mid:<Message-ID>`, RFC 2392) in Apple
 * Mail, which finds it by its Message-ID; a `plms:` thing on PLMS. Nil for everything else.
 */
func externalTarget(_ url: String) -> URL? {
    if url.hasPrefix("mid:") {
        let id = String(url.dropFirst(4)).removingPercentEncoding ?? String(url.dropFirst(4))
        return URL(string: "message://%3C" + (id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@.-_"))) ?? id) + "%3E")
    }
    if url.hasPrefix("plms:") {
        let parts = url.dropFirst(5).split(separator: "/").map(String.init)
        switch (parts.first, parts.count) {
        case ("course", 2): return URL(string: "\(plmsBase)/course/view.php?id=\(parts[1])")
        case ("mod", 3): return URL(string: "\(plmsBase)/mod/\(parts[1])/view.php?id=\(parts[2])")
        case ("post", 3): return URL(string: "\(plmsBase)/mod/ubboard/article.php?id=\(parts[1])&bwid=\(parts[2])")
        default: return nil
        }
    }
    return nil
}
