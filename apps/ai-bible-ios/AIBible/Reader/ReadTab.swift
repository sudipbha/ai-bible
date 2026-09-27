import SwiftUI

/// Opens straight into the reader at the last position (Chapter 1 on first launch).
/// Back leads to the contents.
struct ReadTab: View {
    @Environment(AppModel.self) private var model
    @State private var path: [ReadRoute] = []
    @State private var didOpenLastPosition = false
    @State private var unlockPresented = false

    var body: some View {
        NavigationStack(path: $path) {
            ContentsView(open: { open($0, replacingReader: false) })
                .navigationDestination(for: ReadRoute.self) { route in
                    switch route {
                    case .reader(let position):
                        ReaderView(position: position, open: { open($0, replacingReader: true) })
                    case .bookmarks:
                        BookmarksView(open: { open($0, replacingReader: false) })
                    }
                }
        }
        .onAppear {
            guard !didOpenLastPosition, !model.book.chapters.isEmpty else { return }
            didOpenLastPosition = true
            path = [.reader(model.startPosition())]
        }
        .sheet(isPresented: $unlockPresented) { UnlockSheet() }
    }

    private func open(_ position: ReaderPosition, replacingReader: Bool) {
        guard model.canRead(chapterID: position.chapterID) else {
            unlockPresented = true
            return
        }
        if replacingReader, case .reader = path.last {
            path[path.count - 1] = .reader(position)
        } else {
            path.append(.reader(position))
        }
    }
}

struct ContentsView: View {
    @Environment(AppModel.self) private var model
    let open: (ReaderPosition) -> Void

    var body: some View {
        List {
            if let anchor = model.lastPosition, let chapter = model.book.chapter(anchor.chapterID) {
                Section {
                    Button {
                        open(ReaderPosition(chapterID: anchor.chapterID, blockID: anchor.blockID))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Continue reading").font(.headline)
                            Text("\(chapter.label): \(chapter.title)").foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("contents.continue")
                }
            }

            Section("Contents") {
                ForEach(model.book.chapters) { chapter in
                    Button {
                        open(ReaderPosition(chapterID: chapter.id, blockID: nil))
                    } label: {
                        ChapterRow(chapter: chapter, locked: !model.canRead(chapter))
                    }
                    .accessibilityIdentifier("contents.chapter.\(chapter.id)")
                }
            }

            Section {
                NavigationLink(value: ReadRoute.bookmarks) {
                    Label("Bookmarks (\(model.bookmarks.count))", systemImage: "bookmark")
                }
                .accessibilityIdentifier("contents.bookmarks")
            }
        }
        .navigationTitle(model.book.title)
    }
}

private struct ChapterRow: View {
    let chapter: Chapter
    let locked: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.label).font(.subheadline).foregroundStyle(.secondary)
                Text(chapter.title).foregroundStyle(.primary)
            }
            Spacer(minLength: 8)
            if locked {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(locked ? "Included with the full book" : "")
    }
}

struct BookmarksView: View {
    @Environment(AppModel.self) private var model
    let open: (ReaderPosition) -> Void

    var body: some View {
        List {
            if model.bookmarks.isEmpty {
                Text("No bookmarks yet. In the reader, tap the bookmark button or press and hold a paragraph.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.bookmarks) { bookmark in
                Button {
                    open(ReaderPosition(chapterID: bookmark.anchor.chapterID, blockID: bookmark.anchor.blockID))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.book.chapter(bookmark.anchor.chapterID)?.title ?? "")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(bookmark.anchor.quote).lineLimit(3).foregroundStyle(.primary)
                        if bookmark.isApproximate {
                            Text("Position is approximate after a content update.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("bookmark.\(bookmark.anchor.blockID)")
            }
            .onDelete { offsets in
                model.deleteBookmarks(ids: Set(offsets.map { model.bookmarks[$0].id }))
            }
        }
        .navigationTitle("Bookmarks")
    }
}
