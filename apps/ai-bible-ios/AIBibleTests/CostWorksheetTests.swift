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

    func testFictionalVectorIsValidAndResultsMatch() {
        let sheet = fictionalSheet()
        XCTAssertTrue(sheet.isValid)
        XCTAssertEqual(sheet.results, CostWorksheet.Results(
            manualMinutes: 240, firstTrialMinutes: 250, laterMinutes: 160,
            firstPeriodCapacityChange: -10, laterCapacityChange: 80))
    }

    func testInvalidEntriesAreReportedNotTurnedIntoZero() {
        var sheet = CostWorksheet()
        sheet.tasks = -3
        sheet.manualMinutesPerTask = -1
        sheet.wholeJobMinutesPerTask = .nan
        sheet.oneTimeSetupMinutes = .infinity
        sheet.monthlyPrice = -5

        XCTAssertNil(sheet.results)
        let issues = sheet.validationIssues
        XCTAssertEqual(issues.count, 5)
        XCTAssertTrue(issues.contains("Tasks per period can't be negative."))
        XCTAssertTrue(issues.contains("Manual minutes per task can't be negative."))
        XCTAssertTrue(issues.contains("Whole-job minutes per task isn't a valid number."))
        XCTAssertTrue(issues.contains("One-time setup minutes isn't a valid number."))
        XCTAssertTrue(issues.contains("The monthly price can't be negative."))
        // The entered values are kept as typed.
        XCTAssertEqual(sheet.tasks, -3)
        XCTAssertTrue(sheet.wholeJobMinutesPerTask.isNaN)
    }

    func testFiniteButHugeValuesAreRejectedWithoutCrashing() {
        var sheet = fictionalSheet()
        sheet.manualMinutesPerTask = 1e20          // finite, but not representable as Int
        XCTAssertNil(sheet.results)
        XCTAssertEqual(sheet.validationIssues, ["Manual minutes per task must be 100,000 or fewer."])

        var overflowing = fictionalSheet()
        overflowing.tasks = Int.max
        overflowing.wholeJobMinutesPerTask = 1e308  // tasks × minutes overflows to infinity
        XCTAssertNil(overflowing.results)
        XCTAssertFalse(overflowing.validationIssues.isEmpty)

        // Both export without crashing and without made-up figures.
        for bad in [sheet, overflowing] {
            let text = ToolExport.text(bad)
            XCTAssertTrue(text.contains("Results aren't shown until these entries are fixed:"))
            XCTAssertFalse(text.contains("Manual: "))
        }
    }

    func testLimitsAreInclusive() {
        var sheet = CostWorksheet()
        sheet.tasks = CostWorksheet.maxTasks
        sheet.manualMinutesPerTask = CostWorksheet.maxMinutesPerTask
        sheet.wholeJobMinutesPerTask = CostWorksheet.maxMinutesPerTask
        sheet.oneTimeSetupMinutes = CostWorksheet.maxSetupMinutes
        XCTAssertNotNil(sheet.results)
        XCTAssertFalse(ToolExport.text(sheet).contains(MinutesFormat.outOfRange))
    }

    func testFormattingNeverTrapsOnExtremeValues() {
        for value in [1e20, -1e20, .infinity, -.infinity, .nan, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(MinutesFormat.string(value), MinutesFormat.outOfRange)
            XCTAssertEqual(MinutesFormat.capacityChange(value), MinutesFormat.outOfRange)
            XCTAssertEqual(ToolExport.number(value), "invalid")
        }
        XCTAssertEqual(MinutesFormat.string(MinutesFormat.maxFormattable), "1000000000000 min (16666666666 h 40 min)")
    }

    func testInvalidRecordSavesAndReopensWithValidationIntact() throws {
        let store = TestBooks.temporaryStore()
        var sheet = fictionalSheet()
        sheet.manualMinutesPerTask = .nan
        sheet.wholeJobMinutesPerTask = .infinity
        sheet.oneTimeSetupMinutes = 1e20
        var data = UserData()
        data.costs = [sheet]
        try store.save(data)

        guard case .loaded(let reopened) = store.load(), let saved = reopened.costs.first else {
            return XCTFail("Expected the worksheet to reopen")
        }
        XCTAssertTrue(saved.manualMinutesPerTask.isNaN)
        XCTAssertEqual(saved.wholeJobMinutesPerTask, .infinity)
        XCTAssertEqual(saved.oneTimeSetupMinutes, 1e20)
        XCTAssertNil(saved.results)
        XCTAssertEqual(saved.validationIssues.count, 3)
        XCTAssertTrue(ToolExport.text(saved).contains("Results aren't shown"))
    }

    func testMinutesFormat() {
        XCTAssertEqual(MinutesFormat.string(45), "45 min")
        XCTAssertEqual(MinutesFormat.string(60), "60 min (1 h)")
        XCTAssertEqual(MinutesFormat.string(7.5), "7.5 min")
    }
}
