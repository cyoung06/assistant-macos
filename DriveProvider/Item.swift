import FileProvider
import UniformTypeIdentifiers

/** A drive entry as Finder sees it. */
final class Item: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let entry: Store.DriveEntryRecord

    init(_ entry: Store.DriveEntryRecord, id: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier) {
        self.entry = entry
        itemIdentifier = id
        parentItemIdentifier = parent
    }

    /** The drive's top: "Projects" and what's beside it. */
    static func root() -> Item {
        Item(Store.DriveEntryRecord(DriveEntry(path: "", name: "Assistant", folder: true, size: 0, modified: nil, contentType: nil, etag: nil)), id: .rootContainer, parent: .rootContainer)
    }

    var filename: String { entry.name }

    var contentType: UTType {
        if entry.folder { return .folder }
        return UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? entry.contentType.flatMap { UTType(mimeType: $0) } ?? .data
    }

    var documentSize: NSNumber? { entry.folder ? nil : NSNumber(value: entry.size) }

    var contentModificationDate: Date? { entry.modified.flatMap { try? Date($0, strategy: .iso8601) } }

    /**
     * Course files only read (they're PLMS's); Projects/ and the project folders stay where they are
     * (they follow the projects), but take what's put in them; everything else, anything.
     */
    var capabilities: NSFileProviderItemCapabilities {
        if driveReadOnly(entry.path) { return entry.folder ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading] }
        if entry.path.isEmpty || driveFixed(entry.path) { return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems] }
        var all: NSFileProviderItemCapabilities = [.allowsReading, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        all.insert(entry.folder ? [.allowsContentEnumerating, .allowsAddingSubItems] : .allowsWriting)
        return all
    }

    /** Its content's version is its ETag (or size and time without one); its name's, the name. */
    var itemVersion: NSFileProviderItemVersion {
        let content = entry.etag ?? "\(entry.size)@\(entry.modified ?? "")"
        return NSFileProviderItemVersion(contentVersion: Data(content.utf8), metadataVersion: Data((entry.name + (entry.modified ?? "")).utf8))
    }
}
