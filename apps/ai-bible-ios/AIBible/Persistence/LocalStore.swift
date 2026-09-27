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
///
/// The saved file is never overwritten unless it was read successfully or safely
/// moved aside first. When neither is possible, `load()` reports `.blocked` and the
/// caller must not save until the user explicitly deletes their data.
struct FileStore: Sendable {
    enum BlockReason: Equatable, Sendable {
        /// The file exists but couldn't be read (for example, the device is still locked).
        case unreadable
        /// The file was written by a newer version of the app.
        case newerVersion(Int)
        /// The file couldn't be decoded and couldn't be moved aside.
        case couldNotPreserve
    }

    enum LoadResult: Equatable {
        case fresh
        case loaded(UserData)
        /// The file couldn't be decoded. It was moved to `backup`, so starting fresh is safe.
        case quarantined(backup: URL)
        /// The file was left exactly where it is. Saving must stay off.
        case blocked(BlockReason)
    }

    static let fileName = "userdata.json"
    static let quarantinePrefix = "userdata.unreadable-"

    let url: URL
    /// File operations, replaceable in tests to simulate failures.
    var readData: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    var moveItem: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    var removeItem: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    var listDirectory: @Sendable (URL) throws -> [String] = { try FileManager.default.contentsOfDirectory(atPath: $0.path) }

    init(url: URL) {
        self.url = url
    }

    static func defaultStore() throws -> FileStore {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AIBible", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FileStore(url: directory.appendingPathComponent(fileName))
    }

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .fresh }

        let data: Data
        do {
            data = try readData(url)
        } catch {
            // Possibly temporary (file protection before first unlock); leave it untouched.
            return .blocked(.unreadable)
        }

        if let version = Self.schemaVersion(in: data), version > UserData.currentSchemaVersion {
            return .blocked(.newerVersion(version))
        }

        do {
            return .loaded(try Self.decoder.decode(UserData.self, from: data))
        } catch {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("\(Self.quarantinePrefix)\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json")
            do {
                try moveItem(url, backup)
            } catch {
                return .blocked(.couldNotPreserve)
            }
            return .quarantined(backup: backup)
        }
    }

    func save(_ userData: UserData) throws {
        let data = try Self.encoder.encode(userData)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Files this app wrote for the reader: the main file and any quarantined copies.
    /// Other files in the directory are never included. Throws if the directory can't be
    /// listed, so "couldn't look" is never mistaken for "nothing there".
    func userDataFiles() throws -> [URL] {
        let directory = url.deletingLastPathComponent()
        return try listDirectory(directory)
            .filter { $0 == url.lastPathComponent || ($0.hasPrefix(Self.quarantinePrefix) && $0.hasSuffix(".json")) }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// Removes every file from `userDataFiles()`. Returns the files that couldn't be removed.
    /// Throws, without removing anything, if the files couldn't be listed.
    func deleteAllUserDataFiles() throws -> [URL] {
        try userDataFiles().filter { file in
            do {
                try removeItem(file)
                return false
            } catch {
                return FileManager.default.fileExists(atPath: file.path)
            }
        }
    }

    /// Reads only the schema version, so a newer file is recognised even if the rest doesn't decode.
    private static func schemaVersion(in data: Data) -> Int? {
        struct Header: Decodable { var schemaVersion: Int? }
        return (try? JSONDecoder().decode(Header.self, from: data))?.schemaVersion
    }

    // Non-finite numbers are written as strings so a record with an invalid value
    // still saves and reopens (the worksheet then shows the validation message).
    private static let nonFinite = (positive: "inf", negative: "-inf", nan: "nan")

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: nonFinite.positive, negativeInfinity: nonFinite.negative, nan: nonFinite.nan)
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: nonFinite.positive, negativeInfinity: nonFinite.negative, nan: nonFinite.nan)
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
