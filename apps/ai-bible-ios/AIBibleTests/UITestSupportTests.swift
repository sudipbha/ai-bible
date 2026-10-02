#if DEBUG
import XCTest
@testable import AIBible

/// The UI-test data hook must stay inside its temporary folder and never touch real data.
/// (It doesn't exist in Release builds at all.)
final class UITestSupportTests: XCTestCase {
    func testWithoutTheArgumentTheRealStoreIsUsed() {
        XCTAssertNil(UITestSupport.fileStore(arguments: ["AIBible"]))
        XCTAssertNil(UITestSupport.fileStore(arguments: ["AIBible", UITestSupport.storeArgument]))
    }

    func testUnsafeNamesAreRejected() {
        for name in ["", ".", "..", "../x", "a/b", "x.y", "~", "é", String(repeating: "a", count: 41)] {
            XCTAssertNil(UITestSupport.fileStore(arguments: [UITestSupport.storeArgument, name]), name)
        }
    }

    func testStoreIsConfinedAndResetOnlyEmptiesItsOwnFolder() throws {
        let name = "unit-" + UUID().uuidString.prefix(8)
        let store = try XCTUnwrap(UITestSupport.fileStore(arguments: [UITestSupport.storeArgument, name]))
        XCTAssertEqual(store.url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                       UITestSupport.root.standardizedFileURL)
        XCTAssertNotEqual(store.url.deletingLastPathComponent().standardizedFileURL,
                          try FileStore.defaultStore().url.deletingLastPathComponent().standardizedFileURL)
        try store.save(UserData())

        let otherName = "unit-" + UUID().uuidString.prefix(8)
        let other = try XCTUnwrap(UITestSupport.fileStore(arguments: [UITestSupport.storeArgument, otherName]))
        try other.save(UserData())

        _ = UITestSupport.fileStore(arguments: [UITestSupport.storeArgument, name, UITestSupport.resetArgument])

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.url.path))
    }
}
#endif
