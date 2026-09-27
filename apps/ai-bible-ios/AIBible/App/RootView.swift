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
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ReaderPreferences.themeKey) private var theme = ReaderTheme.system

    var body: some View {
        Group {
            if let error = model.loadError {
                ContentUnavailableView(error, systemImage: "book.closed")
            } else {
                TabView {
                    ReadTab()
                        .tabItem { Label("Read", systemImage: "book") }
                    ToolsTab()
                        .tabItem { Label("Tools", systemImage: "checklist") }
                    SearchTab()
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    SettingsTab()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                }
            }
        }
        .preferredColorScheme(theme.colorScheme)
    }
}
