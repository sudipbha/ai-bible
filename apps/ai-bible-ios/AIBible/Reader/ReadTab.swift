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
                    case .edition(let focus):
                        EditionView(focus: focus)
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

            if let presentation = model.book.presentation, presentation.cover != nil || presentation.titlePage != nil {
                Section {
                    NavigationLink(value: ReadRoute.edition(presentation.cover != nil ? .cover : .titlePage)) {
                        EditionEntryRow(presentation: presentation, coverImage: model.coverImage, title: model.book.title)
                    }
                    .accessibilityIdentifier("contents.edition")
                }
            }

            if let entries = model.book.presentation?.contents, !entries.isEmpty {
                // The source's own contents: every entry leads to its cover, title page, chapter or heading.
                Section("Contents") {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        SourceContentsRow(entry: entry, destination: model.destination(for: entry.target), open: open)
                            .accessibilityIdentifier("contents.entry.\(index)")
                    }
                }
            } else {
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
            }

            Section {
                NavigationLink(value: ReadRoute.bookmarks) {
                    Label("Bookmarks (\(model.bookmarks.count))", systemImage: "bookmark")
                }
                .accessibilityIdentifier("contents.bookmarks")
            }
        }
        // Identifies the Contents list itself (its collection view); each row keeps its own element and identifier.
        .accessibilityIdentifier("contents.list")
        .navigationTitle(model.book.title)
    }
}

/// One entry of the source contents, indented by its depth.
private struct SourceContentsRow: View {
    @Environment(AppModel.self) private var model
    let entry: ContentsEntry
    let destination: ContentsDestination?
    let open: (ReaderPosition) -> Void

    var body: some View {
        switch destination {
        case .some(.edition(let focus)):
            NavigationLink(value: ReadRoute.edition(focus)) { label(locked: false) }
        case .some(.reader(let position)):
            Button { open(position) } label: { label(locked: !model.canRead(chapterID: position.chapterID)) }
        case .none:
            // Validation rejects unmapped targets, so this only shows for malformed data.
            label(locked: false).foregroundStyle(.secondary)
        }
    }

    private func label(locked: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: entry.label)
                .font(entry.depth == 1 ? .body : .subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if locked {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, CGFloat(max(entry.depth - 1, 0)) * 16)
        .accessibilityElement(children: .combine)
        .accessibilityValue(locked ? "Included with the full book" : "")
    }
}

/// A compact row that opens the full cover and title page.
private struct EditionEntryRow: View {
    let presentation: BookPresentation
    let coverImage: Data?
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            if let coverImage, let image = UIImage(data: coverImage) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 64)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text("Cover and title page").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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
