import Foundation

struct Bookmark: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var anchor: ReadingAnchor
    var createdAt = Date()
    /// Set when a content update could only place the bookmark near its original spot.
    var isApproximate = false
}

/// Everything the app keeps about the reader. Stored only on this device.
struct UserData: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = UserData.currentSchemaVersion
    var lastPosition: ReadingAnchor?
    var bookmarks: [Bookmark] = []
    var filters: [FilterRecord] = []
    var rollouts: [RolloutRecord] = []
    var costs: [CostWorksheet] = []
    var entitlement = EntitlementState()

    init() {}

    // Tolerant decoding: fields added in later versions fall back to defaults
    // instead of discarding the reader's saved work.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        lastPosition = try c.decodeIfPresent(ReadingAnchor.self, forKey: .lastPosition)
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        filters = try c.decodeIfPresent([FilterRecord].self, forKey: .filters) ?? []
        rollouts = try c.decodeIfPresent([RolloutRecord].self, forKey: .rollouts) ?? []
        costs = try c.decodeIfPresent([CostWorksheet].self, forKey: .costs) ?? []
        entitlement = try c.decodeIfPresent(EntitlementState.self, forKey: .entitlement) ?? EntitlementState()
    }
}

/// A JSON file in Application Support, written atomically. It is included in the
/// device's own backups; it is not synced anywhere.
struct FileStore: Sendable {
    enum LoadResult: Equatable {
        case fresh
        case loaded(UserData)
        /// The file could not be read. It was moved aside, not deleted.
        case recovered(backup: URL)
    }

    let url: URL

    static func defaultStore() throws -> FileStore {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AIBible", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FileStore(url: directory.appendingPathComponent("userdata.json"))
    }

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .fresh }
        do {
            let data = try Data(contentsOf: url)
            return .loaded(try Self.decoder.decode(UserData.self, from: data))
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("userdata.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return .recovered(backup: backup)
        }
    }

    func save(_ userData: UserData) throws {
        let data = try Self.encoder.encode(userData)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func delete() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum AnchorMigration {
    /// Moves the saved position and bookmarks onto the current edition. Nothing is
    /// dropped: an anchor that can't be matched lands on its chapter (or the book)
    /// start and is marked approximate.
    static func migrate(_ userData: UserData, to book: BookBundle) -> UserData {
        var result = userData
        if let position = userData.lastPosition {
            result.lastPosition = migrated(position, in: book)?.anchor
        }
        result.bookmarks = userData.bookmarks.map { bookmark in
            guard let moved = migrated(bookmark.anchor, in: book) else { return bookmark }
            var copy = bookmark
            copy.anchor = moved.anchor
            copy.isApproximate = bookmark.isApproximate || moved.approximate
            return copy
        }
        return result
    }

    private static func migrated(_ anchor: ReadingAnchor, in book: BookBundle) -> (anchor: ReadingAnchor, approximate: Bool)? {
        if anchor.contentVersion == book.contentVersion, book.locate(blockID: anchor.blockID) != nil {
            return (anchor, false)
        }
        let resolution = AnchorResolver.resolve(anchor, in: book)
        guard let blockID = resolution.blockID, let updated = ReadingAnchor(blockID: blockID, in: book) else {
            return nil
        }
        return (updated, resolution.isApproximate)
    }
}
