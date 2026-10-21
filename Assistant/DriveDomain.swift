import FileProvider

/**
 * The drive in Finder's sidebar, as "Assistant" (see DriveProvider): added when the app starts, and
 * told to look again every minute while it runs and after a change made here. (The drive can't say
 * what changed, so Finder only learns of changes made elsewhere when asked to look.)
 */
@MainActor
enum DriveDomain {
    private static let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("drive"), displayName: "Assistant")
    private static var timer: Timer?

    static func start() {
        NSFileProviderManager.add(domain) { error in
            if let error { print("Drive in Finder: \(error.localizedDescription)") }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in changed() } }
    }

    /** Something may have changed: Finder looks at the folders it has open again. */
    static func changed() {
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }
}
