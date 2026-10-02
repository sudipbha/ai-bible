import SwiftUI

struct SearchTab: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var path: [ReadRoute] = []
    @State private var unlockPresented = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !query.isEmpty && results.hits.isEmpty && results.lockedMatchCount == 0 {
                    Text("No matches for “\(query)”.").foregroundStyle(.secondary)
                }
                ForEach(results.hits) { hit in
                    NavigationLink(value: ReadRoute.reader(ReaderPosition(chapterID: hit.chapterID, blockID: hit.blockID))) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(hit.chapterLabel): \(hit.chapterTitle)")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(hit.snippet)
                        }
                    }
                    .accessibilityIdentifier("search.result.\(hit.blockID)")
                }
                if results.lockedMatchCount > 0 {
                    Section {
                        Button {
                            unlockPresented = true
                        } label: {
                            Text(results.lockedMatchCount == 1
                                 ? "1 more match in the full book"
                                 : "\(results.lockedMatchCount) more matches in the full book")
                        }
                        .accessibilityIdentifier("search.lockedMatches")
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search the book")
            .navigationTitle("Search")
            .navigationDestination(for: ReadRoute.self) { route in
                switch route {
                case .reader(let position):
                    ReaderView(position: position, open: open)
                case .bookmarks:
                    BookmarksView(open: open)
                case .edition(let focus):
                    EditionView(focus: focus)
                }
            }
            .task(id: query) {
                // Short pause so typing stays smooth.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                results = model.search(query)
            }
            .onChange(of: model.access) { _, _ in
                results = model.search(query)
            }
        }
        .sheet(isPresented: $unlockPresented) { UnlockSheet() }
    }

    private func open(_ position: ReaderPosition) {
        guard model.canRead(chapterID: position.chapterID) else {
            unlockPresented = true
            return
        }
        if case .reader = path.last {
            path[path.count - 1] = .reader(position)
        } else {
            path.append(.reader(position))
        }
    }
}
