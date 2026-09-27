import SwiftUI
import UIKit
#if DEBUG
import OSLog
#endif

struct ReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ReaderPreferences.themeKey) private var theme = ReaderTheme.system
    @AppStorage(ReaderPreferences.fontKey) private var font = ReaderFont.serif

    let position: ReaderPosition
    let open: (ReaderPosition) -> Void

    /// The block this reader was asked to open at, kept until the scroll view reports that
    /// block as the top visible one (acknowledgement). Until then it is the reader's place and
    /// the scroll view's other reports are treated as provisional.
    @State private var pendingBlockID: String?
    /// Set when the scroll to `pendingBlockID` has been dispatched, so it is dispatched at
    /// most once for this reader. Dispatch is not arrival: only acknowledgement clears the
    /// pending block.
    @State private var didDispatchPending = false
    /// The top visible block, as reported by the scroll view. Observed only: the reader
    /// scrolls through the `ScrollViewReader` proxy, never by writing this value.
    @State private var visibleBlockID: String?
    @State private var viewportHeight: CGFloat = 0
    @State private var unlockPresented = false

    init(position: ReaderPosition, open: @escaping (ReaderPosition) -> Void) {
        self.position = position
        self.open = open
        _pendingBlockID = State(initialValue: position.blockID)
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
        ScrollViewReader { proxy in
            ScrollView {
                // One lazy stack is the scroll view's direct content: the scroll target layout that
                // `.scrollPosition(id:)` observes, and the container whose block IDs the proxy
                // scrolls to. Only the blocks carry IDs; header and footer are plain rows.
                LazyVStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(chapter.label).font(.subheadline).foregroundStyle(.secondary)
                        Text(chapter.title).font(.largeTitle.weight(.bold))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("reader.chapterTitle")
                    .padding(.bottom, 4)   // keeps the earlier 20-point gap before the first block

                    ForEach(chapter.blocks) { block in
                        BlockView(block: block)
                            .id(block.id)
                            .accessibilityIdentifier("block.\(block.id)")
                            .contextMenu { blockMenu(block) }
                    }

                    ChapterFooter(chapter: chapter, open: open)
                        .padding(.top, 4)   // keeps the earlier 20-point gap after the last block
                }
                .scrollTargetLayout()
                // Keeps lines near a comfortable reading length on wide screens.
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition(id: $visibleBlockID, anchor: .top)
            // Dispatch the scroll to the requested opening block once the scroll view has a real
            // size. In runs 36350115237 and 36352200784 the reader didn't reach the requested
            // block when an initial `scrollPosition` value was the only mechanism; that this
            // was the cause is a hypothesis, not established.
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                viewportHeight = height
                dispatchPendingIfReady(proxy, chapter)
            }
            .fontDesign(font.design)
            .background(theme.readerBackground)
            .navigationTitle(chapter.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !chapter.headings.isEmpty {
                        Menu {
                            ForEach(chapter.headings) { heading in
                                Button(InlineText.plain(heading.text ?? "")) { jump(to: heading.id, proxy) }
                            }
                        } label: {
                            Label("In this chapter", systemImage: "list.bullet")
                        }
                    }
                    bookmarkButton(chapter)
                }
            }
            .onAppear {
                // Record the opened place right away. onChange below only fires after a
                // scroll, so without this a chapter opened from Contents, Search, a bookmark
                // or the footer was never saved as the place to resume.
                // On reappearance this keeps the current place: the pending block if it
                // hasn't been reached yet, otherwise the visible block, and only then the
                // route's block or the chapter's first block.
                if let id = pendingBlockID ?? visibleBlockID ?? position.blockID ?? chapter.blocks.first?.id {
                    model.updatePosition(blockID: id)
                }
                dispatchPendingIfReady(proxy, chapter)
            }
            .onChange(of: visibleBlockID) { _, id in
                guard let id else { return }
                if let pending = pendingBlockID {
                    // Until the scroll view reports the requested block, its reports are
                    // provisional and must not replace the saved place.
                    guard id == pending else { return }
                    pendingBlockID = nil
                }
                model.updatePosition(blockID: id)
            }
        }
    }

    /// Dispatches the scroll to the pending opening block at most once, when there is one and
    /// the scroll view has a real size. Called from `onAppear` and from the geometry change;
    /// whichever first finds both true dispatches, and `didDispatchPending` makes later calls
    /// no-ops. There is no retry: if the block is never reported visible, the pending block
    /// stays the saved place.
    private func dispatchPendingIfReady(_ proxy: ScrollViewProxy, _ chapter: Chapter) {
        guard let target = pendingBlockID, !didDispatchPending, viewportHeight > 0 else { return }
        didDispatchPending = true
        // A block that isn't in this chapter can never be reported visible, so it would leave
        // tracking suspended. Drop it; the reader then starts at the chapter start as before.
        guard chapter.blocks.contains(where: { $0.id == target }) else {
            pendingBlockID = nil
            return
        }
        proxy.scrollTo(target, anchor: .top)
        #if DEBUG
        // Dispatch evidence only; arrival is shown by the scroll view reporting the block.
        Logger(subsystem: "AIBible", category: "reader")
            .notice("AIBIBLE-READER dispatched opening block \(target, privacy: .public) at viewport height \(Double(self.viewportHeight), privacy: .public)")
        #endif
    }

    private func bookmarkButton(_ chapter: Chapter) -> some View {
        let target = pendingBlockID ?? visibleBlockID ?? chapter.blocks.first?.id
        let marked = target.map { model.isBookmarked(blockID: $0) } ?? false
        return Button {
            if let target { model.toggleBookmark(blockID: target) }
        } label: {
            Label(marked ? "Remove bookmark" : "Bookmark this place",
                  systemImage: marked ? "bookmark.fill" : "bookmark")
        }
        .disabled(target == nil)
        .accessibilityIdentifier("reader.bookmark")
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

    private func jump(to blockID: String, _ proxy: ScrollViewProxy) {
        // An explicit jump replaces any opening request, reached or not, and resumes normal
        // tracking at once, so a jump to a block that is already visible (no change reported)
        // can't leave later scrolling ignored.
        pendingBlockID = nil
        didDispatchPending = true
        if reduceMotion {
            proxy.scrollTo(blockID, anchor: .top)
        } else {
            withAnimation { proxy.scrollTo(blockID, anchor: .top) }
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
        .accessibilityIdentifier("reader.locked")
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
