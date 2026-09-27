import XCTest
@testable import AIBible

final class CostWorksheetTests: XCTestCase {
    /// Fictional vector from the owner's brief.
    private func fictionalSheet() -> CostWorksheet {
        var sheet = CostWorksheet()
        sheet.title = "Fictional vector"
        sheet.tasks = 20
        sheet.manualMinutesPerTask = 12
        sheet.wholeJobMinutesPerTask = 8
        sheet.oneTimeSetupMinutes = 90
        sheet.monthlyPrice = 20
        sheet.priceNote = "hypothetical"
        return sheet
    }

    func testFictionalVector() {
        let sheet = fictionalSheet()
        XCTAssertEqual(sheet.manualMinutes, 240)       // 20 × 12
        XCTAssertEqual(sheet.firstTrialMinutes, 250)   // 20 × 8 + 90
        XCTAssertEqual(sheet.laterMinutes, 160)        // 20 × 8
        XCTAssertEqual(sheet.firstPeriodCapacityChange, -10)
        XCTAssertEqual(sheet.laterCapacityChange, 80)
    }

    func testPriceDoesNotChangeTimeFigures() {
        var sheet = fictionalSheet()
        let before = (sheet.manualMinutes, sheet.firstTrialMinutes, sheet.laterMinutes)
        sheet.monthlyPrice = 999
        XCTAssertEqual(sheet.manualMinutes, before.0)
        XCTAssertEqual(sheet.firstTrialMinutes, before.1)
        XCTAssertEqual(sheet.laterMinutes, before.2)
    }

    func testCapacityWordingIsNeverCash() {
        XCTAssertEqual(MinutesFormat.capacityChange(80), "80 min (1 h 20 min) of time freed (time, not cash)")
        XCTAssertEqual(MinutesFormat.capacityChange(-10), "10 min of extra time needed")
        XCTAssertEqual(MinutesFormat.capacityChange(0), "No change in time")
    }

    func testExportKeepsMoneySeparateAndAvoidsSavingsLanguage() {
        let text = ToolExport.text(fictionalSheet())
        XCTAssertTrue(text.contains("Manual: 20 tasks × 12 min = 240 min (4 h)"))
        XCTAssertTrue(text.contains("= 250 min (4 h 10 min)"))
        XCTAssertTrue(text.contains("Later periods: 20 tasks × 8 min whole-job = 160 min (2 h 40 min)"))
        XCTAssertTrue(text.contains("Tool price per month, as entered: 20 (hypothetical)"))
        XCTAssertTrue(text.contains("Money (kept separate from time)"))
        XCTAssertFalse(text.lowercased().contains("saving"))
        XCTAssertFalse(text.lowercased().contains("saved you"))
    }

    func testNegativeInputsAreClamped() {
        var sheet = CostWorksheet()
        sheet.tasks = -3
        sheet.manualMinutesPerTask = -1
        sheet.wholeJobMinutesPerTask = .nan
        sheet.oneTimeSetupMinutes = -90
        sheet.monthlyPrice = -5
        let clean = sheet.sanitized()
        XCTAssertEqual(clean.tasks, 0)
        XCTAssertEqual(clean.manualMinutesPerTask, 0)
        XCTAssertEqual(clean.wholeJobMinutesPerTask, 0)
        XCTAssertEqual(clean.oneTimeSetupMinutes, 0)
        XCTAssertEqual(clean.monthlyPrice, 0)
    }

    func testMinutesFormat() {
        XCTAssertEqual(MinutesFormat.string(45), "45 min")
        XCTAssertEqual(MinutesFormat.string(60), "60 min (1 h)")
        XCTAssertEqual(MinutesFormat.string(7.5), "7.5 min")
    }
}
