import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case sepia
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Match iPhone"
        case .light: "Light"
        case .sepia: "Sepia"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light, .sepia: .light
        case .dark: .dark
        }
    }

    /// Sepia keeps system black text on a warm background, well above 4.5:1 contrast.
    var readerBackground: Color {
        switch self {
        case .sepia: Color(red: 0.97, green: 0.94, blue: 0.87)
        default: Color(uiColor: .systemBackground)
        }
    }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case serif
    case sans

    var id: String { rawValue }

    var title: String {
        switch self {
        case .serif: "Serif"
        case .sans: "Sans serif"
        }
    }

    var design: Font.Design {
        switch self {
        case .serif: .serif
        case .sans: .default
        }
    }
}

enum ReaderPreferences {
    static let themeKey = "reader.theme"
    static let fontKey = "reader.font"
}

/// Routes shared by the Read and Search tabs.
enum ReadRoute: Hashable {
    case reader(ReaderPosition)
    case bookmarks
    /// Converted editions only: the cover and title page.
    case edition(EditionFocus)
}

enum RootTab: Hashable {
    case decisions, read, tools, search, settings
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ReaderPreferences.themeKey) private var theme = ReaderTheme.system
    /// A fresh install opens in the reader. Once the owner has AI tool decisions, the app opens
    /// on them instead: the book explains the method, and Decisions is where it is used.
    @State private var selection: RootTab?

    var body: some View {
        Group {
            if let error = model.loadError {
                ContentUnavailableView(error, systemImage: "book.closed")
            } else {
                TabView(selection: Binding(get: { selection ?? initialTab }, set: { selection = $0 })) {
                    DecisionsTab()
                        .tabItem { Label("Decisions", systemImage: "checkmark.seal") }
                        .tag(RootTab.decisions)
                    ReadTab()
                        .tabItem { Label("Read", systemImage: "book") }
                        .tag(RootTab.read)
                    ToolsTab()
                        .tabItem { Label("Tools", systemImage: "checklist") }
                        .tag(RootTab.tools)
                    SearchTab()
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                        .tag(RootTab.search)
                    SettingsTab()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(RootTab.settings)
                }
                .onAppear { if selection == nil { selection = initialTab } }
            }
        }
        .preferredColorScheme(theme.colorScheme)
    }

    private var initialTab: RootTab {
        model.evaluations.isEmpty ? .read : .decisions
    }
}
