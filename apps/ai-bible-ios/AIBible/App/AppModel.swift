import Foundation
import Observation

enum AppConfig {
    /// Placeholder. Replace with the non-consumable product ID created in App Store Connect.
    static let fullBookProductID = "com.example.aibible.fullbook"
    #if AIBIBLE_PRIVATE_BOOK
    /// Private local builds only, made with converter/stage-private-build.sh from a reviewed
    /// conversion. Public builds and CI never define AIBIBLE_PRIVATE_BOOK.
    static let bundledBookResource = "book.private"
    static let expectsFixtureContent = false
    #else
    /// Synthetic fixture. Real book content needs an approved, pinned edition first.
    static let bundledBookResource = "book.fixture"
    static let expectsFixtureContent = true
    #endif
    /// Required before App Store submission (Guideline 5.1.1(i)); not set yet.
    static let privacyPolicyURL: URL? = nil
    /// Required before App Store submission; not set yet.
    static let supportURL: URL? = nil
}

struct ReaderPosition: Hashable, Sendable {
    var chapterID: String
    var blockID: String?
}

/// The part of the edition view to show first.
enum EditionFocus: Hashable, Sendable {
    case cover
    case titlePage
}

enum ContentsDestination: Equatable {
    case edition(EditionFocus)
    case reader(ReaderPosition)
}

/// What an open reader may show right now. Re-evaluated on every render, so a
/// reader that is already on screen locks as soon as access is lost.
enum ReaderGate: Equatable {
    case readable(Chapter)
    case locked(Chapter)
    case missing
}

@MainActor
@Observable
final class AppModel {
    let book: BookBundle
    let loadError: String?
    /// The edition's cover image, already checked against its recorded SHA-256. Nil for the fixture.
    let coverImage: Data?
    let entitlements: EntitlementModel

    private(set) var lastPosition: ReadingAnchor?
    private(set) var bookmarks: [Bookmark]
    private(set) var filters: [FilterRecord]
    private(set) var rollouts: [RolloutRecord]
    private(set) var costs: [CostWorksheet]
    /// Shown in Settings when saved data couldn't be read, preserved, written or deleted.
    private(set) var storageNotice: String?
    /// True while an earlier saved file is still in place and couldn't be read or moved
    /// aside. Nothing is written until the user chooses Delete My Data.
    private(set) var savingPaused = false

    @ObservationIgnored private let searchIndex: SearchIndex
    @ObservationIgnored private let store: FileStore?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(book: BookBundle, loadError: String? = nil, store: FileStore?, provider: any PurchaseProvider, coverImage: Data? = nil) {
        self.book = book
        self.loadError = loadError
        self.coverImage = coverImage
        self.store = store
        self.searchIndex = SearchIndex(book: book)

        var saved = UserData()
        var notice: String?
        var paused = false
        if let store {
            switch store.load() {
            case .fresh:
                break
            case .loaded(let data):
                saved = data
            case .quarantined(let backup):
                notice = "Saved data couldn't be read, so the app started fresh. The old file was kept on this iPhone as \(backup.lastPathComponent)."
            case .blocked(let reason):
                paused = true
                notice = Self.blockedNotice(reason)
            }
        } else {
            notice = "This device isn't letting the app save right now, so changes may not be kept."
        }
        // With no loadable content, saved places and records are kept exactly as they are:
        // migrating them against the empty placeholder would drop valid positions.
        if loadError == nil {
            saved = AnchorMigration.migrate(saved, to: book)
        }

        lastPosition = saved.lastPosition
        bookmarks = saved.bookmarks
        filters = saved.filters
        rollouts = saved.rollouts
        costs = saved.costs
        storageNotice = notice
        savingPaused = paused
        entitlements = EntitlementModel(provider: provider, cached: saved.entitlement)
        entitlements.onChange = { [weak self] _ in self?.scheduleSave() }
    }

    private static func blockedNotice(_ reason: FileStore.BlockReason) -> String {
        let tail = " Saving is paused so it isn't overwritten. Changes you make now won't be kept. Delete My Data in Settings clears it and turns saving back on."
        switch reason {
        case .unreadable:
            return "Your saved data couldn't be opened right now (the iPhone may still be locked). Restart the app to try again." + tail
        case .newerVersion(let version):
            return "Your saved data is from a newer version of this app (format \(version)). Update the app to open it." + tail
        case .couldNotPreserve:
            return "Your saved data couldn't be read and couldn't be moved aside safely, so it was left in place." + tail
        }
    }

    static func live() -> AppModel {
        let provider = StoreKitPurchaseProvider(productID: AppConfig.fullBookProductID)
        var store = try? FileStore.defaultStore()
        #if DEBUG
        // UI tests only: keep their generated data in a temporary folder (see UITestSupport).
        if let testStore = UITestSupport.fileStore() { store = testStore }
        #endif
        var resource = AppConfig.bundledBookResource
        var expectFixture = AppConfig.expectsFixtureContent
        #if DEBUG
        // UI tests only: a second synthetic fixture with a cover, title page and source contents.
        if let testBook = UITestSupport.bookResource() {
            resource = testBook
            expectFixture = true
        }
        #endif
        do {
            let edition = try BookLoader.loadSelectedEdition(named: resource, expectFixture: expectFixture)
            return AppModel(book: edition.book, store: store, provider: provider, coverImage: edition.coverImage)
        } catch {
            // No fallback to other content: the selected edition is shown or nothing is.
            let empty = BookBundle(
                contentVersion: "missing", isFixture: true, title: "AI Bible", chapters: [], idMap: nil,
                tools: ToolContent(filterQuestions: [], rolloutItems: [])
            )
            let message: String
            switch error as? BookLoader.LoadError {
            case .wrongContentKind:
                message = "The packaged book content doesn't match this build's content selection."
            case .invalidContent(let count):
                message = "The packaged book content failed \(count) structural check(s), so it wasn't opened."
            case .coverMismatch:
                message = "The packaged cover image doesn't match the book content, so it wasn't opened."
            default:
                message = "The book content couldn't be loaded."
            }
            return AppModel(book: empty, loadError: message, store: store, provider: provider)
        }
    }

    // MARK: Access

    var access: ContentAccess { entitlements.state.access }

    func canRead(_ chapter: Chapter) -> Bool {
        chapter.access == .free || access == .full
    }

    func canRead(chapterID: String) -> Bool {
        book.chapter(chapterID).map { canRead($0) } ?? false
    }

    /// Paid tools stay readable and exportable after a refund or revocation; only editing and new records need the unlock.
    func canEdit(_ tool: ToolKind) -> Bool {
        tool.isFree || access == .full
    }

    // MARK: Reading

    /// Where a source contents entry leads, or nil if its target isn't in this edition.
    /// Chapter and block targets go through the normal reader route, so paid ones stay locked.
    func destination(for target: ContentsTarget) -> ContentsDestination? {
        switch target.kind {
        case .cover:
            return book.presentation?.cover == nil ? nil : .edition(.cover)
        case .titlePage:
            return book.presentation?.titlePage == nil ? nil : .edition(.titlePage)
        case .chapter:
            guard let chapterID = target.chapterID, book.chapter(chapterID) != nil else { return nil }
            return .reader(ReaderPosition(chapterID: chapterID, blockID: nil))
        case .block:
            guard let chapterID = target.chapterID, let blockID = target.blockID,
                  book.chapter(chapterID)?.blocks.contains(where: { $0.id == blockID }) == true else { return nil }
            return .reader(ReaderPosition(chapterID: chapterID, blockID: blockID))
        }
    }

    func readerGate(for position: ReaderPosition) -> ReaderGate {
        guard let chapter = book.chapter(position.chapterID) else { return .missing }
        return canRead(chapter) ? .readable(chapter) : .locked(chapter)
    }

    func startPosition() -> ReaderPosition {
        if let anchor = lastPosition, canRead(chapterID: anchor.chapterID) {
            return ReaderPosition(chapterID: anchor.chapterID, blockID: anchor.blockID)
        }
        // Converted editions keep copyright and introductory reading sections in `chapters`
        // before the numbered chapters. A fresh reader should open at Chapter 1, while those
        // front-matter sections remain available from Contents. Older/fixture editions without
        // that label retain their existing first-readable fallback.
        let first = book.chapters.first(where: { $0.label == "Chapter 1" && canRead($0) })
            ?? book.chapters.first(where: { canRead($0) })
            ?? book.chapters.first
        return ReaderPosition(chapterID: first?.id ?? "", blockID: first?.blocks.first?.id)
    }

    func updatePosition(blockID: String) {
        guard let anchor = ReadingAnchor(blockID: blockID, in: book), anchor != lastPosition else { return }
        lastPosition = anchor
        scheduleSave()
    }

    func search(_ query: String) -> SearchResults {
        searchIndex.search(query, fullAccess: access == .full)
    }

    func isBookmarked(blockID: String) -> Bool {
        bookmarks.contains { $0.anchor.blockID == blockID }
    }

    func toggleBookmark(blockID: String) {
        if let index = bookmarks.firstIndex(where: { $0.anchor.blockID == blockID }) {
            bookmarks.remove(at: index)
        } else if let anchor = ReadingAnchor(blockID: blockID, in: book) {
            bookmarks.append(Bookmark(anchor: anchor))
        }
        scheduleSave()
    }

    func deleteBookmarks(ids: Set<UUID>) {
        bookmarks.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    // MARK: Tools

    @discardableResult
    func newFilter() -> UUID {
        let record = FilterRecord()
        filters.insert(record, at: 0)
        scheduleSave()
        return record.id
    }

    func update(_ record: FilterRecord) {
        guard let index = filters.firstIndex(where: { $0.id == record.id }), filters[index] != record else { return }
        var copy = record
        copy.updatedAt = Date()
        filters[index] = copy
        scheduleSave()
    }

    func newRollout() -> UUID? {
        guard canEdit(.rollout) else { return nil }
        let record = RolloutRecord()
        rollouts.insert(record, at: 0)
        scheduleSave()
        return record.id
    }

    func update(_ record: RolloutRecord) {
        guard canEdit(.rollout),
              let index = rollouts.firstIndex(where: { $0.id == record.id }),
              rollouts[index] != record else { return }
        var copy = record
        copy.updatedAt = Date()
        rollouts[index] = copy
        scheduleSave()
    }

    func newCostWorksheet() -> UUID? {
        guard canEdit(.cost) else { return nil }
        let sheet = CostWorksheet()
        costs.insert(sheet, at: 0)
        scheduleSave()
        return sheet.id
    }

    /// Saves the worksheet exactly as entered, including invalid numbers, so the
    /// reader sees and fixes them rather than finding a silently changed value.
    func update(_ sheet: CostWorksheet) {
        guard canEdit(.cost),
              let index = costs.firstIndex(where: { $0.id == sheet.id }),
              costs[index] != sheet else { return }
        var copy = sheet
        copy.updatedAt = Date()
        costs[index] = copy
        scheduleSave()
    }

    /// Deleting is always allowed, locked or not: the reader owns their records.
    func delete(_ tool: ToolKind, ids: Set<UUID>) {
        switch tool {
        case .filter: filters.removeAll { ids.contains($0.id) }
        case .rollout: rollouts.removeAll { ids.contains($0.id) }
        case .cost: costs.removeAll { ids.contains($0.id) }
        }
        scheduleSave()
    }

    /// Clears position, bookmarks and tool records, and removes this app's saved file
    /// and any recovery copies of it. Other files are left alone. The purchase is the
    /// App Store's record and is re-read from StoreKit, so it is not affected.
    @discardableResult
    func deleteAllUserData() -> Bool {
        // The content-error state is read-only; saved data is left for a build that can load the book.
        guard loadError == nil else { return false }
        pendingSave?.cancel()
        pendingSave = nil
        lastPosition = nil
        bookmarks = []
        filters = []
        rollouts = []
        costs = []

        guard let store else { return true }
        let remaining: [URL]
        do {
            remaining = try store.deleteAllUserDataFiles()
        } catch {
            // It's unknown which saved files exist, so nothing is claimed as deleted and
            // saving pauses (even if it wasn't paused before) so no saved file is overwritten.
            savingPaused = true
            storageNotice = "Your saved data couldn't be checked, so it may not have been deleted. Saving is paused so nothing is overwritten. Try Delete My Data again."
            return false
        }
        if remaining.isEmpty {
            savingPaused = false
            storageNotice = nil
            saveNow()
            return storageNotice == nil
        }
        // Keep saving paused if the original file is still there, so it isn't overwritten.
        savingPaused = savingPaused && remaining.contains(store.url)
        storageNotice = "Some saved data couldn't be deleted: " + remaining.map(\.lastPathComponent).joined(separator: ", ") + ". Try Delete My Data again."
        if !savingPaused { saveNow() }
        return false
    }

    // MARK: Saving

    func snapshot() -> UserData {
        var data = UserData()
        data.lastPosition = lastPosition
        data.bookmarks = bookmarks
        data.filters = filters
        data.rollouts = rollouts
        data.costs = costs
        data.entitlement = entitlements.state
        return data
    }

    /// Writes immediately. Call when the app leaves the foreground.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        saveNow()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        // Never write while the book content failed to load: the in-memory state is a placeholder.
        guard let store, !savingPaused, loadError == nil else { return }
        do {
            try store.save(snapshot())
            if storageNotice?.hasPrefix("Couldn't save") == true { storageNotice = nil }
        } catch {
            storageNotice = "Couldn't save your latest changes on this device. The app will try again on your next change."
        }
    }
}
