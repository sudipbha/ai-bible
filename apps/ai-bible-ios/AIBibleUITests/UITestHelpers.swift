import XCTest

/// Launch arguments understood by the Debug-only hook in AIBible/App/UITestSupport.swift.
/// Each test uses its own named store under the simulator's temporary folder, so test data
/// never mixes with other tests or with any real saved data.
enum TestStore {
    static func arguments(_ name: String, reset: Bool) -> [String] {
        ["-AIBibleUITestStore", name] + (reset ? ["-AIBibleUITestReset"] : [])
    }
}

@MainActor
extension XCUIApplication {
    func launch(store: String, reset: Bool) {
        launchArguments = TestStore.arguments(store, reset: reset)
        launch()
    }

    /// Relaunch with the same store and no reset, after the app's save delay has passed.
    func relaunchKeepingData(store: String) {
        pause(1.5)
        terminate()
        launch(store: store, reset: false)
    }

    /// Any element with this accessibility identifier.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func openTab(_ name: String) {
        tabBars.buttons[name].firstMatch.tap()
    }

    /// Back from the reader (opened automatically at launch) to the contents list.
    func backToContents() {
        let back = navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) { back.tap() }
        XCTAssertTrue(element("contents.bookmarks").waitForExistence(timeout: 10), "Contents list didn't appear")
    }

    /// Types after placing the cursor in a text field.
    func type(_ text: String, into identifier: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Missing field \(identifier)")
        field.tap()
        field.typeText(text)
    }
}

@MainActor
extension XCUIElement {
    @discardableResult
    func waitToAppear(_ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(waitForExistence(timeout: timeout), "Missing element: \(self)", file: file, line: line)
        return self
    }

    func waitToDisappear(_ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed,
                       "Still present: \(self)", file: file, line: line)
    }

    func waitFor(_ format: String, _ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: self)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: timeout), .completed,
                       "\(self) never matched \(format)", file: file, line: line)
    }

    /// Taps the switch itself rather than its label (a plain tap on a Form row can miss it).
    func tapSwitch() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }
}

/// Lets the app's 0.4-second save delay pass before a relaunch.
@MainActor
func pause(_ seconds: TimeInterval) {
    _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pause")], timeout: seconds)
}
