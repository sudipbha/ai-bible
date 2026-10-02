import Foundation

#if DEBUG
/// Debug-only launch hook for the UI tests in AIBibleUITests. It is compiled out of
/// Release builds, so a shipping app ignores these launch arguments.
///
/// It only points saved data at a scratch folder under the temporary directory. It never
/// grants access (purchases still come from StoreKit) and it can't read, reset or delete
/// the real saved-data folder in Application Support.
enum UITestSupport {
    static let storeArgument = "-AIBibleUITestStore"
    static let resetArgument = "-AIBibleUITestReset"
    static let bookArgument = "-AIBibleUITestBook"
    /// Synthetic fixtures a UI test may select instead of the default one. Nothing else is accepted.
    static let selectableBooks: Set<String> = ["presentation.fixture"]

    /// A synthetic fixture chosen by a UI test, or nil. Only names in `selectableBooks` count.
    static func bookResource(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let index = arguments.firstIndex(of: bookArgument), arguments.indices.contains(index + 1),
              selectableBooks.contains(arguments[index + 1]) else { return nil }
        return arguments[index + 1]
    }

    /// Parent of every UI-test store: <tmp>/AIBibleUITests.
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AIBibleUITests", isDirectory: true)
    }

    /// A store in <tmp>/AIBibleUITests/<name>, or nil when the app wasn't launched by a UI
    /// test (or the name is unsafe). With the reset argument, only that folder is emptied first.
    static func fileStore(arguments: [String] = ProcessInfo.processInfo.arguments) -> FileStore? {
        guard let index = arguments.firstIndex(of: storeArgument),
              arguments.indices.contains(index + 1) else { return nil }
        let name = arguments[index + 1]
        guard isSafeName(name) else { return nil }
        let directory = root.appendingPathComponent(name, isDirectory: true)
        if arguments.contains(resetArgument) {
            try? FileManager.default.removeItem(at: directory)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FileStore(url: directory.appendingPathComponent(FileStore.fileName))
    }

    /// 1–40 ASCII letters, digits, "-" or "_": no path separators, dots or traversal.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }
}
#endif
