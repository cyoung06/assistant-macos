import AppKit
import Foundation
import UserNotifications

/** Something handed to Triage that the server doesn't have yet. */
struct TriageJob: Codable, Identifiable {
    var id = UUID()
    var text: String
    var title: String
    var link: String?
    /** Image files in the job's folder, with their types. */
    var images: [String]
    var mimeTypes: [String]
    /** Attachments already uploaded (in order), so a retry doesn't send them again. */
    var uploaded: [String] = []
    var created = Date()
    var attempts = 0
    var error: String?
}

/**
 * Sends to Triage in the background: whatever is handed over (from Capture or a drop) is saved to
 * disk at once and the panel closes; uploads and the submit happen here, retried until the server
 * has them, also after a relaunch.
 */
@MainActor
final class TriageOutbox: ObservableObject {
    static let shared = TriageOutbox()

    @Published private(set) var jobs: [TriageJob] = []
    private let dir: URL
    private var running = false
    private var notified = false

    private init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Assistant/outbox")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        jobs = folders.compactMap { f in (try? Data(contentsOf: f.appending(path: "job.json"))).flatMap { try? JSONDecoder().decode(TriageJob.self, from: $0) } }
            .sorted { $0.created < $1.created }
    }

    func send(text: String, title: String = "", link: String? = nil, images: [CapturedImage]) {
        var job = TriageJob(text: text, title: title, link: link, images: [], mimeTypes: [])
        let folder = dir.appending(path: job.id.uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, img) in images.enumerated() {
            let (data, mime) = shrink(img)
            let name = "\(i)"
            guard (try? data.write(to: folder.appending(path: name))) != nil else { continue }
            job.images.append(name)
            job.mimeTypes.append(mime)
        }
        save(job)
        jobs.append(job)
        run()
    }

    /** An `assistant-handoff:` link from the Share extension: queues what it put on the pasteboard. */
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard url.scheme == Handoff.scheme else { return false }
        if let p = Handoff.take(url) {
            send(text: p.text, title: p.title, link: p.link, images: zip(p.images, p.mimeTypes).map { CapturedImage(data: $0, name: "shared.png", mimeType: $1) })
        }
        return true
    }

    func discard(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: dir.appending(path: id.uuidString))
    }

    /** Sends what's waiting, one at a time; on failure waits (longer each time) and tries again. */
    func run() {
        guard !running else { return }
        running = true
        Task {
            while let job = jobs.first {
                if await deliver(job) { continue }
                let attempts = jobs.first { $0.id == job.id }?.attempts ?? 1
                try? await Task.sleep(for: .seconds(min(300, 1 << min(attempts, 9))))
            }
            running = false
            notified = false
        }
    }

    private func deliver(_ start: TriageJob) async -> Bool {
        var job = start
        let api = AppModel.shared.api
        let folder = dir.appending(path: job.id.uuidString)
        do {
            for i in job.uploaded.count..<job.images.count {
                let data = try Data(contentsOf: folder.appending(path: job.images[i]))
                job.uploaded.append(try await api.upload(data, filename: "screenshot-\(i + 1).png", mimeType: job.mimeTypes[i]))
                update(job)
            }
            try await api.submitTriage(text: job.text, attachmentIds: job.uploaded, title: job.title, link: job.link)
            discard(job.id)
            await AppModel.shared.refreshTriage()
            return true
        } catch {
            job.attempts += 1
            job.error = error.localizedDescription
            update(job)
            if !notified {
                notified = true
                let content = UNMutableNotificationContent()
                content.title = "Couldn't send to Triage yet"
                content.body = "\(job.error ?? ""). Retrying in the background."
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "outbox-\(job.id)", content: content, trigger: nil))
            }
            return false
        }
    }

    private func update(_ job: TriageJob) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[i] = job
        save(job)
    }

    private func save(_ job: TriageJob) {
        if let raw = try? JSONEncoder().encode(job) { try? raw.write(to: dir.appending(path: job.id.uuidString).appending(path: "job.json")) }
    }

    /** Screenshots scaled down to 2048px on the long side (about what the model reads at), as PNG; smaller ones as they are. */
    private func shrink(_ img: CapturedImage) -> (Data, String) {
        guard let rep = NSBitmapImageRep(data: img.data), max(rep.pixelsWide, rep.pixelsHigh) > 2048, let cg = rep.cgImage else { return (img.data, img.mimeType) }
        let scale = 2048 / Double(max(rep.pixelsWide, rep.pixelsHigh))
        let w = Int(Double(rep.pixelsWide) * scale), h = Int(Double(rep.pixelsHigh) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (img.data, img.mimeType) }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:]) else { return (img.data, img.mimeType) }
        return (png, "image/png")
    }
}
