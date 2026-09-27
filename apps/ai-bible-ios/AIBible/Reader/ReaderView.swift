import SwiftUI
import UIKit

struct ReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ReaderPreferences.themeKey) private var theme = ReaderTheme.system
    @AppStorage(ReaderPreferences.fontKey) private var font = ReaderFont.serif

    let position: ReaderPosition
    let open: (ReaderPosition) -> Void

    /// Bound to the scroll view: setting it scrolls, scrolling updates it.
    @State private var visibleBlockID: String?
    @State private var unlockPresented = false

    init(position: ReaderPosition, open: @escaping (ReaderPosition) -> Void) {
        self.position = position
        self.open = open
        _visibleBlockID = State(initialValue: position.blockID)
    }

    // Access is checked on every render, not only when the route is opened, so an
    // open paid chapter stops showing its text as soon as access is lost (refund,
    // revocation, or a launch-time check that no longer finds the purchase).
    var body: some View {
        switch model.readerGate(for: position) {
        case .readable(let chapter):
            reader(chapter)
        case .locked(let chapter):
            LockedChapterView(chapter: chapter, unlock: { unlockPresented = true })
                .sheet(isPresented: $unlockPresented) { UnlockSheet() }
        case .missing:
            ContentUnavailableView("Chapter not found", systemImage: "book.closed")
        }
    }

    private func reader(_ chapter: Chapter) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(chapter.label).font(.subheadline).foregroundStyle(.secondary)
                    Text(chapter.title).font(.largeTitle.weight(.bold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(chapter.blocks) { block in
                        BlockView(block: block)
                            .id(block.id)
                            .contextMenu { blockMenu(block) }
                    }
                }
                .scrollTargetLayout()

                ChapterFooter(chapter: chapter, open: open)
            }
            // Keeps lines near a comfortable reading length on wide screens.
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $visibleBlockID, anchor: .top)
        .fontDesign(font.design)
        .background(theme.readerBackground)
        .navigationTitle(chapter.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !chapter.headings.isEmpty {
                    Menu {
                        ForEach(chapter.headings) { heading in
                            Button(InlineText.plain(heading.text ?? "")) { jump(to: heading.id) }
                        }
                    } label: {
                        Label("In this chapter", systemImage: "list.bullet")
                    }
                }
                bookmarkButton(chapter)
            }
        }
        .onChange(of: visibleBlockID) { _, id in
            if let id { model.updatePosition(blockID: id) }
        }
    }

    private func bookmarkButton(_ chapter: Chapter) -> some View {
        let target = visibleBlockID ?? chapter.blocks.first?.id
        let marked = target.map { model.isBookmarked(blockID: $0) } ?? false
        return Button {
            if let target { model.toggleBookmark(blockID: target) }
        } label: {
            Label(marked ? "Remove bookmark" : "Bookmark this place",
                  systemImage: marked ? "bookmark.fill" : "bookmark")
        }
        .disabled(target == nil)
    }

    @ViewBuilder
    private func blockMenu(_ block: Block) -> some View {
        Button {
            model.toggleBookmark(blockID: block.id)
        } label: {
            if model.isBookmarked(blockID: block.id) {
                Label("Remove bookmark", systemImage: "bookmark.slash")
            } else {
                Label("Bookmark", systemImage: "bookmark")
            }
        }
        Button {
            UIPasteboard.general.string = block.plainText
        } label: {
            Label("Copy text", systemImage: "doc.on.doc")
        }
        ShareLink(item: block.plainText) {
            Label("Share text", systemImage: "square.and.arrow.up")
        }
    }

    private func jump(to blockID: String) {
        if reduceMotion {
            visibleBlockID = blockID
        } else {
            withAnimation { visibleBlockID = blockID }
        }
    }
}

/// Shown in place of a paid chapter the reader can't open. No chapter text is shown.
private struct LockedChapterView: View {
    let chapter: Chapter
    let unlock: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("\(chapter.label): \(chapter.title)", systemImage: "lock")
        } description: {
            Text("This chapter is included with the full book. Your bookmarks and saved tool records are kept.")
        } actions: {
            Button("See what's included", action: unlock)
        }
        .navigationTitle(chapter.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ChapterFooter: View {
    @Environment(AppModel.self) private var model
    let chapter: Chapter
    let open: (ReaderPosition) -> Void

    var body: some View {
        let index = model.book.chapterIndex(chapter.id) ?? 0
        let chapters = model.book.chapters
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            if index + 1 < chapters.count {
                let next = chapters[index + 1]
                Button {
                    open(ReaderPosition(chapterID: next.id, blockID: nil))
                } label: {
                    footerLabel(prefix: "Next", chapter: next, locked: !model.canRead(next))
                }
            }
            if index > 0 {
                let previous = chapters[index - 1]
                Button {
                    open(ReaderPosition(chapterID: previous.id, blockID: nil))
                } label: {
                    footerLabel(prefix: "Previous", chapter: previous, locked: !model.canRead(previous))
                }
            }
        }
        .padding(.top, 16)
    }

    private func footerLabel(prefix: String, chapter: Chapter, locked: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(prefix).font(.subheadline).foregroundStyle(.secondary)
                Text("\(chapter.label): \(chapter.title)")
            }
            Spacer(minLength: 8)
            if locked {
                Image(systemName: "lock").accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(locked ? "Included with the full book" : "")
    }
}
