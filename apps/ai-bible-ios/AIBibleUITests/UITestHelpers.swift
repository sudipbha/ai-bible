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
    /// Returns how many transactions remain afterwards (expected 0). `nonisolated` so the
    /// synchronous `tearDownWithError()` can call it without an actor hop: it uses only a
    /// fresh, method-local `SKTestSession` and touches no UI.
    @discardableResult
    nonisolated static func clearAll() throws -> Int {
        let session = try SKTestSession(configurationFileNamed: "Products")
        session.clearTransactions()
        return session.allTransactions().count
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

    /// Drags the visible content up by about 60% of its height. The drag stays inside the
    /// region between the navigation bar and whichever is higher of the tab bar and the
    /// keyboard, so it moves the Form or scroll view and never starts on the bars or the
    /// keyboard. A plain `app.swipeUp()`
    /// starts at the window's centre and did not reach the Filter summary in run 36350115237.
    func dragContentUp() {
        let window = windows.firstMatch.frame
        var top = window.minY
        var bottom = window.maxY
        let bar = navigationBars.firstMatch
        if bar.exists { top = max(top, bar.frame.maxY) }
        let tabs = tabBars.firstMatch
        if tabs.exists { bottom = min(bottom, tabs.frame.minY) }
        let keyboard = keyboards.firstMatch
        if keyboard.exists { bottom = min(bottom, keyboard.frame.minY) }
        let height = bottom - top
        guard height > 40 else {
            logDiagnostics("no content region to drag (top \(top), bottom \(bottom))")
            XCTFail("No content region to drag")
            return
        }
        let origin = coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: window.midX, dy: top + height * 0.8))
        let end = origin.withOffset(CGVector(dx: window.midX, dy: top + height * 0.2))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    /// Swipes up at most `maxSwipes` times until the element exists and is hittable.
    /// Lists and Forms create rows lazily, so an element further down may not exist yet.
    @discardableResult
    func scrollUntilHittable(_ identifier: String, maxSwipes: Int = 8) -> XCUIElement {
        let target = element(identifier)
        var swipes = 0
        while !(target.exists && target.isHittable) && swipes < maxSwipes {
            dragContentUp()
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
            dragContentUp()
            swipes += 1
        }
        if !match.exists {
            logDiagnostics("no text containing '\(text)' after \(swipes) swipes")
            XCTFail("No text containing '\(text)'", file: file, line: line)
        }
    }

    /// Replaces the number in a trailing-aligned numeric field and reads it back.
    ///
    /// Run 36350115237 showed the tap at (0.95, 0.8) focuses the field (typing reached it),
    /// but the value became "200" instead of "20". The caret position
    /// wasn't observed, so this selects the whole current text with the system edit menu's
    /// Select All and types over the selection. If the menu doesn't offer Select All after
    /// two bounded attempts (a second tap, then a press), the test fails with diagnostics;
    /// it never deletes by length at an unknown caret position.
    func replaceNumber(_ text: String, in identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = scrollUntilHittable(identifier)
        // Run 36352200784: `cost.setup` was hittable, but its tap point (y 448.2) lay under
        // the keyboard (top 446), so the tap and press went to the keyboard. Keep the whole
        // field above the current keyboard, re-checking after the keyboard appears.
        guard revealAboveKeyboard(field, identifier, file: file, line: line) else { return }
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8)).tap()
        let keyboard = keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 5) {
            logDiagnostics("no keyboard after tapping \(identifier)", focus: [identifier])
            XCTFail("No keyboard after tapping \(identifier)", file: file, line: line)
            return
        }
        guard revealAboveKeyboard(field, identifier, file: file, line: line) else { return }
        // Recomputed from the field's current frame after any scrolling above.
        let point = field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8))
        let before = field.value as? String ?? ""
        XCTContext.runActivity(named: "AIBIBLE-DIAG before replacing \(identifier): frame \(field.frame) "
                               + "value '\(before.prefix(40))' keyboard \(keyboard.frame)") { _ in }
        if !before.isEmpty {
            // Matched by label, not element type: depending on the iOS version the edit menu's
            // entries are exposed as menu items or as buttons.
            let selectAll = descendants(matching: .any).matching(NSPredicate(format: "label == 'Select All'")).firstMatch
            point.tap()   // a tap on the focused field shows the edit menu
            if !selectAll.waitForExistence(timeout: 3) {
                guard revealAboveKeyboard(field, identifier, file: file, line: line) else { return }
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8)).press(forDuration: 1.0)
            }
            guard selectAll.waitForExistence(timeout: 3) else {
                let editLabels = NSPredicate(format: "label IN {'Select', 'Select All', 'Paste', 'Copy', 'Cut', 'AutoFill'}")
                let offered = descendants(matching: .any).matching(editLabels).allElementsBoundByIndex
                    .prefix(6).map { "\($0.label) (type \($0.elementType.rawValue))" }.joined(separator: ", ")
                logDiagnostics("no Select All for \(identifier); menu items: [\(offered)]", focus: [identifier])
                XCTFail("No Select All menu item for \(identifier)", file: file, line: line)
                return
            }
            selectAll.tap()
        }
        field.typeText(text)
        let after = field.value as? String ?? ""
        XCTContext.runActivity(named: "AIBIBLE-DIAG after replacing \(identifier): value '\(after.prefix(40))'") { _ in }
        field.waitFor("value == '\(text)'", 5, file: file, line: line)
    }

    /// True when the whole field lies between the navigation bar and a line 48 points above
    /// the current keyboard's top (the margin covers the suggestion bar that can sit just
    /// above the reported keyboard frame), or above the tab bar when there is no keyboard.
    func isAboveKeyboard(_ field: XCUIElement) -> Bool {
        guard field.exists else { return false }
        let frame = field.frame
        var top = windows.firstMatch.frame.minY
        let bar = navigationBars.firstMatch
        if bar.exists { top = max(top, bar.frame.maxY) }
        var bottom = windows.firstMatch.frame.maxY
        let tabs = tabBars.firstMatch
        if tabs.exists { bottom = min(bottom, tabs.frame.minY) }
        let keyboard = keyboards.firstMatch
        if keyboard.exists { bottom = min(bottom, keyboard.frame.minY - 48) }
        return frame.minY >= top && frame.maxY <= bottom
    }

    /// Drags the content (at most 4 times) until the field is fully above the keyboard, then
    /// re-checks. Fails with the field and keyboard geometry if it never gets there.
    func revealAboveKeyboard(_ field: XCUIElement, _ identifier: String,
                             file: StaticString = #filePath, line: UInt = #line) -> Bool {
        var drags = 0
        while !isAboveKeyboard(field) && drags < 4 {
            dragContentUp()
            drags += 1
        }
        if isAboveKeyboard(field) { return true }
        let keyboard = keyboards.firstMatch
        logDiagnostics("\(identifier) not above the keyboard after \(drags) drags: field "
                       + "\(field.exists ? "\(field.frame)" : "missing") keyboard "
                       + "\(keyboard.exists ? "\(keyboard.frame)" : "none")", focus: [identifier])
        XCTFail("\(identifier) could not be brought above the keyboard", file: file, line: line)
        return false
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
        let collections = collectionViews.allElementsBoundByIndex.prefix(4)
        lines.append("collection views (\(collectionViews.count)): " + collections.map { "\($0.frame)" }.joined(separator: "; "))
        let texts = staticTexts.allElementsBoundByIndex
        lines.append("static texts: \(texts.count); last 6 (label, frame):")
        for text in texts.suffix(6) {
            lines.append("  '\(text.label.prefix(60))' \(text.frame)")
        }
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
