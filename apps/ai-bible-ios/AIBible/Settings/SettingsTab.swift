import SwiftUI

struct SettingsTab: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ReaderPreferences.themeKey) private var theme = ReaderTheme.system
    @AppStorage(ReaderPreferences.fontKey) private var font = ReaderFont.serif
    @State private var confirmDelete = false
    @State private var unlockPresented = false

    var body: some View {
        let store = model.entitlements
        NavigationStack {
            Form {
                Section {
                    Picker("Theme", selection: $theme) {
                        ForEach(ReaderTheme.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Font", selection: $font) {
                        ForEach(ReaderFont.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Reading")
                } footer: {
                    Text("Text size follows your iPhone's Text Size setting in Settings › Display & Brightness or Accessibility.")
                }

                Section("Purchase") {
                    LabeledContent("Full book", value: store.state.access == .full ? "Unlocked" : "Not purchased")
                    if store.state.awaitingApproval {
                        Text("A purchase is waiting for approval.")
                    }
                    if store.state.access != .full {
                        Button("See what's included") { unlockPresented = true }
                    }
                    Button("Restore Purchases") {
                        Task { await store.restore() }
                    }
                    .disabled(store.flow == .working)
                    if case .message(let text) = store.flow {
                        Text(text).font(.footnote)
                    }
                }

                Section {
                    Text("Your reading position, bookmarks and tool records are stored only on this iPhone. The app doesn't collect them or send them anywhere. They're included in your iPhone's own backups, and deleting the app deletes them.")
                    Button("Delete My Data…", role: .destructive) { confirmDelete = true }
                    if let notice = model.storageNotice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Your data")
                }

                Section("About") {
                    if model.book.isFixture {
                        Label("Test build: synthetic sample text, not the book.", systemImage: "exclamationmark.triangle")
                    }
                    if let url = AppConfig.privacyPolicyURL {
                        Link("Privacy Policy", destination: url)
                    } else {
                        Text("Privacy policy link: not set yet (required before App Store submission).")
                            .foregroundStyle(.secondary)
                    }
                    if let url = AppConfig.supportURL {
                        Link("Support", destination: url)
                    } else {
                        Text("Support link: not set yet.")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Content edition", value: model.book.contentVersion)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete your reading position, bookmarks and all tool records from this iPhone?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete My Data", role: .destructive) { model.deleteAllUserData() }
            } message: {
                Text("This can't be undone. Your purchase isn't affected.")
            }
        }
        .sheet(isPresented: $unlockPresented) { UnlockSheet() }
    }
}
