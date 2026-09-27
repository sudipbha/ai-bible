import XCTest
import StoreKitTest

/// Launch arguments understood by the Debug-only hook in AIBible/App/UITestSupport.swift.
/// Each test uses its own named store under the simulator's temporary folder, so test data
/// never mixes with other tests or with any real saved data.
enum TestStore {
    static func arguments(_ name: String, reset: Bool) -> [String] {
        ["-AIBibleUITestStore", name] + (reset ? ["-AIBibleUITestReset"] : [])
    }
}

/// Xcode's local StoreKit test environment (synthetic StoreKit/Products.storekit). It never
/// touches a real Apple account. The data-store reset above does not reset StoreKit, so any
/// test whose result depends on the purchase state starts from here.
@MainActor
enum LocalStoreKit {
    /// A session with no local transactions and purchase dialogs off. Fails the test if a
    /// transaction from an earlier test is still present after clearing.
    static func cleanSession(file: StaticString = #filePath, line: UInt = #line) throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "Products")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        XCTAssertTrue(session.allTransactions().isEmpty,
                      "Local StoreKit still has \(session.allTransactions().count) transaction(s) after clearing",
                      file: file, line: line)
        return session
    }

    /// Removes every local transaction. Called from tearDown so a test that fails after a
    /// simulated purchase can't leave the next test unlocked.
    static func clearAll() throws {
        let session = try SKTestSession(configurationFileNamed: "Products")
        session.clearTransactions()
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
        let contents = element("contents.bookmarks")
        if !contents.waitForExistence(timeout: 10) {
            logDiagnostics("Contents list didn't appear", focus: ["contents.bookmarks"])
            XCTFail("Contents list didn't appear")
        }
    }

    /// Types after placing the cursor in a text field.
    func type(_ text: String, into identifier: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Missing field \(identifier)")
        field.tap()
        field.typeText(text)
    }

    /// Waits for the first element with this identifier to exist and be hittable. On failure
    /// it logs every element with any of the `diagnose` identifiers (count, frames,
    /// hittability) before failing, so the log shows which copy was found and where.
    func expectHittable(_ identifier: String, diagnose: [String] = [], timeout: TimeInterval = 10,
                        file: StaticString = #filePath, line: UInt = #line) {
        let target = element(identifier)
        // Existence first: hittability is only evaluated for an element that exists.
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: target)
        if !target.waitForExistence(timeout: timeout) || XCTWaiter.wait(for: [hittable], timeout: timeout) != .completed {
            logDiagnostics("\(identifier) not hittable after \(timeout)s", focus: [identifier] + diagnose)
            XCTFail("\(identifier) never became hittable", file: file, line: line)
        }
    }

    /// Fails if the first element with this identifier is on screen and hittable.
    func expectNotHittable(_ identifier: String, _ message: String, diagnose: [String] = [],
                           file: StaticString = #filePath, line: UInt = #line) {
        let target = element(identifier)
        if target.exists && target.isHittable {
            logDiagnostics(message, focus: [identifier] + diagnose)
            XCTFail(message, file: file, line: line)
        }
    }

    /// Swipes up at most `maxSwipes` times until the element exists and is hittable.
    /// Lists and Forms create rows lazily, so an element further down may not exist yet.
    @discardableResult
    func scrollUntilHittable(_ identifier: String, maxSwipes: Int = 8) -> XCUIElement {
        let target = element(identifier)
        var swipes = 0
        while !(target.exists && target.isHittable) && swipes < maxSwipes {
            swipeUp()
            swipes += 1
        }
        if !(target.exists && target.isHittable) {
            logDiagnostics("\(identifier) not hittable after \(swipes) swipes", focus: [identifier])
            XCTFail("\(identifier) not hittable after \(swipes) swipes")
        }
        return target
    }

    /// Swipes up at most `maxSwipes` times until a static text whose label contains `text`
    /// exists. `LabeledContent("Manual", value: …)` is exposed as one element labelled
    /// "Manual, 240 min (4 h)" (seen in run 36346633175's hierarchy as "Manual, 0 min"), so
    /// the value alone is not an exact label.
    func expectText(containing text: String, maxSwipes: Int = 6, file: StaticString = #filePath, line: UInt = #line) {
        let match = staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        var swipes = 0
        while !match.waitForExistence(timeout: 2) && swipes < maxSwipes {
            swipeUp()
            swipes += 1
        }
        if !match.exists {
            logDiagnostics("no text containing '\(text)' after \(swipes) swipes")
            XCTFail("No text containing '\(text)'", file: file, line: line)
        }
    }

    /// Replaces the number in a trailing-aligned numeric field and reads it back.
    ///
    /// The field sits inside `LabeledContent`. In run 36346633175 the `cost.tasks` field's
    /// accessibility frame was {{32, 181.5}, {311, 46.5}} and its wrapped label occupied the
    /// top 20.5 points of that same frame, so the earlier tap at the frame's centre could miss
    /// the editor. This taps once in the lower trailing part of the frame, below the label,
    /// where the trailing-aligned number is drawn. `typeText` on the field itself then fails
    /// the test explicitly if that field did not take focus; there is no retry. One bounded
    /// line with the field's state is logged first, so it is in the log even if typing aborts.
    func replaceNumber(_ text: String, in identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = scrollUntilHittable(identifier)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8)).tap()
        let keyboard = keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 5) {
            logDiagnostics("no keyboard after tapping \(identifier)", focus: [identifier])
            XCTFail("No keyboard after tapping \(identifier)", file: file, line: line)
            return
        }
        let current = field.value as? String ?? ""
        XCTContext.runActivity(named: "AIBIBLE-DIAG before typing into \(identifier): frame \(field.frame) "
                               + "hittable \(field.isHittable) value '\(current.prefix(40))' keyboard \(keyboard.frame)") { _ in }
        // Replace rather than append: delete the characters currently shown, then type.
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
        field.waitFor("value == '\(text)'", 5, file: file, line: line)
    }

    /// Writes a bounded description of what is on screen into the test log (each line is an
    /// XCTest activity name, which xcodebuild prints) and attaches a screenshot and a
    /// truncated hierarchy to the result bundle. Diagnostics only; it asserts nothing.
    func logDiagnostics(_ reason: String, focus identifiers: [String] = []) {
        var lines: [String] = ["reason: \(reason)"]
        lines.append("window: \(windows.firstMatch.exists ? "\(windows.firstMatch.frame)" : "none")")
        let selectedTab = tabBars.buttons.matching(NSPredicate(format: "isSelected == true")).firstMatch
        lines.append("selected tab: \(selectedTab.exists ? selectedTab.label : "none")")
        let bars = navigationBars.allElementsBoundByIndex.prefix(4)
        lines.append("navigation bars (\(navigationBars.count)): "
                     + bars.map { "'\($0.identifier)' \($0.frame)" }.joined(separator: "; "))
        let keyboard = keyboards.firstMatch
        lines.append("keyboard: \(keyboard.exists ? "shown \(keyboard.frame)" : "not shown")")
        lines.append("search fields: \(searchFields.count); sheets: \(sheets.count)")
        let scrollers = scrollViews.allElementsBoundByIndex.prefix(4)
        lines.append("scroll views (\(scrollViews.count)): " + scrollers.map { "\($0.frame)" }.joined(separator: "; "))
        for identifier in identifiers.prefix(6) {
            let matches = descendants(matching: .any).matching(identifier: identifier)
            let all = matches.allElementsBoundByIndex
            lines.append("'\(identifier)': \(all.count) match(es)")
            for (index, match) in all.prefix(4).enumerated() {
                lines.append("  [\(index)] type \(match.elementType.rawValue) frame \(match.frame) "
                             + "hittable \(match.isHittable) label '\(match.label.prefix(80))' "
                             + "value '\(String(describing: match.value).prefix(80))'")
            }
        }
        XCTContext.runActivity(named: "AIBIBLE-DIAG begin") { activity in
            let shot = XCTAttachment(screenshot: screenshot())
            shot.name = "AIBIBLE-DIAG screenshot"
            shot.lifetime = .keepAlways
            activity.add(shot)
            let tree = XCTAttachment(string: String(debugDescription.prefix(20_000)))
            tree.name = "AIBIBLE-DIAG hierarchy (first 20,000 characters)"
            tree.lifetime = .keepAlways
            activity.add(tree)
        }
        for line in lines.prefix(40) {
            XCTContext.runActivity(named: "AIBIBLE-DIAG " + String(line.prefix(400))) { _ in }
        }
    }
}

@MainActor
extension XCUIElement {
    @discardableResult
    func waitToAppear(_ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !waitForExistence(timeout: timeout) {
            XCUIApplication().logDiagnostics("missing element \(self)")
            XCTFail("Missing element: \(self)", file: file, line: line)
        }
        return self
    }

    func waitToDisappear(_ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed,
                       "Still present: \(self)", file: file, line: line)
    }

    func waitFor(_ format: String, _ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: self)
        if XCTWaiter.wait(for: [matched], timeout: timeout) != .completed {
            // The identifier can only be read from an element that exists.
            let focus = exists && !identifier.isEmpty ? [identifier] : []
            XCUIApplication().logDiagnostics("\(self) never matched \(format)", focus: focus)
            XCTFail("\(self) never matched \(format)", file: file, line: line)
        }
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
