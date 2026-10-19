import AssistantAPI
import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

typealias TaskItem = Components.Schemas.TaskResponse
typealias Project = Components.Schemas.ProjectResponse
typealias TaskLabel = Components.Schemas.LabelResponse
typealias Initiative = Components.Schemas.InitiativeResponse
typealias ProjectSchedule = Components.Schemas.ProjectSchedule
typealias RecurringSummary = Components.Schemas.RecurringSummary
typealias TriageInput = Components.Schemas.TriageInputResponse
typealias TriageItem = Components.Schemas.TriageItemResponse
typealias Due = Components.Schemas.DueDto
typealias EventItem = Components.Schemas.EventOccurrence
typealias RefItem = Components.Schemas.Ref
typealias Proposal = Components.Schemas.Proposal
typealias TaskStatus = Components.Schemas.TaskResponse.statusPayload
typealias Priority = Components.Schemas.TaskResponse.priorityPayload

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/** Instants from the API come with or without fractional seconds. */
private struct FlexibleDates: DateTranscoder {
    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let plain = ISO8601DateFormatter()

    func encode(_ date: Date) throws -> String { fractional.string(from: date) }
    func decode(_ string: String) throws -> Date {
        if let d = fractional.date(from: string) ?? plain.date(from: string) { return d }
        throw APIError(message: "Bad date \(string)")
    }
}

/** The API: the generated client for most calls, URLSession for merge patches and uploads. */
final class API: @unchecked Sendable {
    let base: URL
    private let client: Client

    init(base: URL) {
        self.base = base
        client = Client(serverURL: base, configuration: .init(dateTranscoder: FlexibleDates()), transport: URLSessionTransport())
    }

    func tasks() async throws -> [TaskItem] { try await client.tasks(.init()).ok.body.json }
    func projects() async throws -> [Project] { try await client.projects().ok.body.json }
    func labels() async throws -> [TaskLabel] { try await client.labels().ok.body.json }
    func initiatives() async throws -> [Initiative] { try await client.initiatives().ok.body.json }
    func projectSchedule(_ id: String) async throws -> ProjectSchedule {
        try await client.projectSchedule(.init(path: .init(id: id), query: .init(days: 28))).ok.body.json
    }

    func create(_ req: Components.Schemas.CreateTaskRequest) async throws -> TaskItem {
        switch try await client.create(.init(body: .json(req))) {
        case let .created(r): return try r.body.json
        case let .undocumented(code, payload): throw await problem(code, payload)
        }
    }

    func delete(_ id: String) async throws { _ = try await client.delete(.init(path: .init(id: id))) }

    func events(from: String, to: String) async throws -> [EventItem] {
        try await client.occurrences(.init(query: .init(from: from, to: to))).ok.body.json
    }

    func createEvent(_ req: Components.Schemas.CreateEventRequest) async throws {
        switch try await client.createEvent(.init(body: .json(req))) {
        case .created: return
        case let .undocumented(code, payload): throw await problem(code, payload)
        }
    }

    func search(_ q: String) async throws -> [RefItem] { try await client.search(.init(query: .init(q: q, limit: 10))).ok.body.json }
    func resolve(_ url: String) async throws -> RefItem { try await client.resolve(.init(query: .init(url: url))).ok.body.json }

    // ---- Triage ---------------------------------------------------------------------

    func triage() async throws -> [TriageInput] { try await client.triage().ok.body.json }

    func acceptTriage(_ id: String, _ proposal: Proposal) async throws {
        _ = try await client.acceptTriage(.init(path: .init(id: id), body: .json(proposal))).ok
    }

    func declineTriage(_ id: String) async throws { _ = try await client.declineTriage(.init(path: .init(id: id))).ok }
    func retryTriage(_ id: String) async throws { _ = try await client.retryTriage(.init(path: .init(id: id))).ok }
    func dismissTriage(_ id: String) async throws { _ = try await client.dismissTriage(.init(path: .init(id: id))).noContent }

    /** Where an uploaded file (a shared screenshot) is served. */
    func attachmentURL(_ id: String) -> URL { base.appendingPathComponent("api/v1/attachments/\(id)") }

    /** Sends text and uploaded screenshots to Triage; the model reads them in the background. */
    func submitTriage(text: String, attachmentIds: [String], title: String = "", link: String? = nil, source: String = "capture") async throws {
        switch try await client.submitTriage(.init(body: .json(.init(attachmentIds: attachmentIds, link: link, source: source, text: text, title: title)))) {
        case .accepted: return
        case let .undocumented(code, payload): throw await problem(code, payload)
        }
    }

    /** JSON merge patch of a task; NSNull clears a field. */
    func patchTask(_ id: String, _ patch: [String: Any]) async throws {
        try await send("PATCH", "api/v1/tasks/\(id)", body: try JSONSerialization.data(withJSONObject: patch), type: "application/json")
    }

    func upload(_ data: Data, filename: String, mimeType: String) async throws -> String {
        let boundary = "assistant-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename.replacingOccurrences(of: "\"", with: ""))\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let out = try await send("POST", "api/v1/attachments", body: body, type: "multipart/form-data; boundary=\(boundary)")
        guard let json = try JSONSerialization.jsonObject(with: out) as? [String: Any], let id = json["id"] as? String else { throw APIError(message: "Upload failed") }
        return id
    }

    // ---- events, as plain JSON (the editor sends merge patches); appending(path:) escapes the ID ----

    func event(_ id: String) async throws -> [String: Any] {
        let data = try await send("GET", "api/v1/events/\(id)", body: nil, type: nil)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func saveEvent(id: String?, _ body: [String: Any]) async throws {
        let json = try JSONSerialization.data(withJSONObject: body)
        if let id { try await send("PATCH", "api/v1/events/\(id)", body: json, type: "application/json") }
        else { try await send("POST", "api/v1/events", body: json, type: "application/json") }
    }

    func deleteEvent(_ id: String) async throws { try await send("DELETE", "api/v1/events/\(id)", body: nil, type: nil) }

    // ---- initiatives, as merge patches (projectIds replaces the list; NSNull clears targetDate) ----

    @discardableResult
    func createInitiative(name: String) async throws -> String {
        let out = try await send("POST", "api/v1/initiatives", body: try JSONSerialization.data(withJSONObject: ["name": name]), type: "application/json")
        return ((try? JSONSerialization.jsonObject(with: out)) as? [String: Any])?["id"] as? String ?? ""
    }

    func patchInitiative(_ id: String, _ patch: [String: Any]) async throws {
        try await send("PATCH", "api/v1/initiatives/\(id)", body: try JSONSerialization.data(withJSONObject: patch), type: "application/json")
    }

    func deleteInitiative(_ id: String) async throws { try await send("DELETE", "api/v1/initiatives/\(id)", body: nil, type: nil) }

    func download(_ id: String) async throws -> Data { try await send("GET", "api/v1/attachments/\(id)", body: nil, type: nil) }

    @discardableResult
    private func send(_ method: String, _ path: String, body: Data?, type: String?) async throws -> Data {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = method
        req.httpBody = body
        if let type { req.setValue(type, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(code) { throw APIError(message: detail(data) ?? "HTTP \(code)") }
        return data
    }

    private func problem(_ code: Int, _ payload: UndocumentedPayload) async -> APIError {
        var data = Data()
        if let body = payload.body { data = (try? await Data(collecting: body, upTo: 1 << 20)) ?? Data() }
        return APIError(message: detail(data) ?? "HTTP \(code)")
    }

    private func detail(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
    }
}

enum Defaults {
    static let server = "https://assistant.lonk-kelvin.ts.net"
}
