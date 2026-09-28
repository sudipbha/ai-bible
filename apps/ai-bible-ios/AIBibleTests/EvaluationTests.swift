import XCTest
@testable import AIBible

/// AI tool decisions: one evaluation ties a tool's Filter, cost and trial records together,
/// records its status history, and plans review-date reminders. No notification center is used.
final class EvaluationTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_790_000_000)   // a fixed instant, not "now"

    @MainActor
    private func unlockedModel(store: FileStore? = nil) async -> AppModel {
        let provider = FakePurchaseProvider()
        provider.entitlement = .active
        let model = AppModel(book: TestBooks.small(), store: store, provider: provider)
        await model.entitlements.start()
        return model
    }

    @MainActor
    func testNewEvaluationStartsConsideringWithItsOwnFilterCheck() throws {
        let model = AppModel(book: TestBooks.small(), store: nil, provider: FakePurchaseProvider())
        let id = model.newEvaluation(now: start)
        let evaluation = try XCTUnwrap(model.evaluations.first { $0.id == id })
        XCTAssertEqual(evaluation.status, .considering)
        XCTAssertEqual(evaluation.history, [StatusChange(status: .considering, date: start)])
        XCTAssertNotNil(evaluation.filterID)
        XCTAssertTrue(model.filters.contains { $0.id == evaluation.filterID }, "the Filter is free, so it is attached at once")
        XCTAssertNil(evaluation.costID)
        XCTAssertNil(evaluation.rolloutID)
    }

    @MainActor
    func testNamesAreCopiedToLinkedRecords() async throws {
        let model = await unlockedModel()
        let id = model.newEvaluation(now: start)
        let costID = try XCTUnwrap(model.attachCostWorksheet(to: id))
        let rolloutID = try XCTUnwrap(model.startTrial(for: id, now: start))
        var evaluation = try XCTUnwrap(model.evaluations.first { $0.id == id })
        evaluation.toolName = "Draftly"
        evaluation.taskName = "Customer emails"
        model.update(evaluation, now: start + day)

        let filter = try XCTUnwrap(model.filters.first { $0.id == evaluation.filterID })
        XCTAssertEqual(filter.toolName, "Draftly")
        XCTAssertEqual(filter.taskName, "Customer emails")
        XCTAssertEqual(model.rollouts.first { $0.id == rolloutID }?.toolName, "Draftly")
        XCTAssertEqual(model.costs.first { $0.id == costID }?.title, "Draftly · Customer emails")
        XCTAssertEqual(model.evaluation(linkedTo: costID)?.id, id)
    }

    @MainActor
    func testStartingATrialSetsStatusReviewDateAndRollout() async throws {
        let model = await unlockedModel()
        let id = model.newEvaluation(now: start)
        let rolloutID = try XCTUnwrap(model.startTrial(for: id, now: start))
        let evaluation = try XCTUnwrap(model.evaluations.first { $0.id == id })
        XCTAssertEqual(evaluation.status, .inTrial)
        XCTAssertEqual(evaluation.history.map(\.status), [.considering, .inTrial])
        XCTAssertEqual(evaluation.rolloutID, rolloutID)
        let review = try XCTUnwrap(evaluation.reviewDate)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: start, to: review).day, 14)
        let rollout = try XCTUnwrap(model.rollouts.first { $0.id == rolloutID })
        XCTAssertEqual(rollout.startDate, start)
        XCTAssertEqual(rollout.reviewDate, review)
    }

    @MainActor
    func testPaidStepsNeedTheUnlockButTheDecisionItselfIsFree() throws {
        let model = AppModel(book: TestBooks.small(), store: nil, provider: FakePurchaseProvider())
        let id = model.newEvaluation(now: start)
        XCTAssertNil(model.attachCostWorksheet(to: id))
        XCTAssertNil(model.startTrial(for: id, now: start))
        XCTAssertTrue(model.costs.isEmpty)
        XCTAssertTrue(model.rollouts.isEmpty)

        var evaluation = try XCTUnwrap(model.evaluations.first)
        evaluation.toolName = "Draftly"
        evaluation.status = .dropped
        evaluation.decisionNote = "Too much checking needed"
        model.update(evaluation, now: start + day)
        let saved = try XCTUnwrap(model.evaluations.first)
        XCTAssertEqual(saved.status, .dropped)
        XCTAssertEqual(saved.decisionNote, "Too much checking needed")
    }

    @MainActor
    func testStatusHistoryIsKeptByTheModelNotTheCaller() throws {
        let model = AppModel(book: TestBooks.small(), store: nil, provider: FakePurchaseProvider())
        let id = model.newEvaluation(now: start)
        let stale = try XCTUnwrap(model.evaluations.first { $0.id == id })

        var kept = stale
        kept.status = .kept
        model.update(kept, now: start + day)
        // An out-of-date copy (without the Kept entry) changes only the note.
        var edit = stale
        edit.status = .kept
        edit.decisionNote = "Saves an hour a week"
        model.update(edit, now: start + 2 * day)
        // Setting the same status again records nothing.
        model.update(edit, now: start + 3 * day)

        let saved = try XCTUnwrap(model.evaluations.first { $0.id == id })
        XCTAssertEqual(saved.history, [StatusChange(status: .considering, date: start),
                                       StatusChange(status: .kept, date: start + day)])
        XCTAssertEqual(saved.decisionNote, "Saves an hour a week")
    }

    @MainActor
    func testDeletingADecisionKeepsItsRecordsAndDeleteMyDataClearsAll() async throws {
        let model = await unlockedModel()
        let id = model.newEvaluation(now: start)
        _ = model.attachCostWorksheet(to: id)
        model.deleteEvaluations(ids: [id])
        XCTAssertTrue(model.evaluations.isEmpty)
        XCTAssertEqual(model.filters.count, 1)
        XCTAssertEqual(model.costs.count, 1)

        model.newEvaluation(now: start)
        XCTAssertTrue(model.deleteAllUserData())
        XCTAssertTrue(model.evaluations.isEmpty)
        XCTAssertTrue(model.filters.isEmpty)
    }

    @MainActor
    func testEvaluationsPersistAcrossRelaunch() async throws {
        let store = TestBooks.temporaryStore()
        let model = await unlockedModel(store: store)
        let id = model.newEvaluation(now: start)
        _ = model.startTrial(for: id, now: start)
        var evaluation = try XCTUnwrap(model.evaluations.first)
        evaluation.toolName = "Draftly"
        evaluation.remindMe = true
        model.update(evaluation, now: start)
        model.flush()

        let relaunched = AppModel(book: TestBooks.small(), store: store, provider: FakePurchaseProvider())
        let saved = try XCTUnwrap(relaunched.evaluations.first)
        XCTAssertEqual(saved.id, id)
        XCTAssertEqual(saved.toolName, "Draftly")
        XCTAssertEqual(saved.status, .inTrial)
        XCTAssertTrue(saved.remindMe)
        XCTAssertEqual(saved.rolloutID, evaluation.rolloutID)
    }

    func testSavedDataWithoutEvaluationsStillLoads() throws {
        let json = Data(#"{"schemaVersion":1,"bookmarks":[],"filters":[]}"#.utf8)
        let data = try FileStore.decoder.decode(UserData.self, from: json)
        XCTAssertEqual(data.evaluations, [])
        let partial = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","toolName":"Draftly"}"#.utf8)
        let evaluation = try FileStore.decoder.decode(ToolEvaluation.self, from: partial)
        XCTAssertEqual(evaluation.status, .considering)
        XCTAssertFalse(evaluation.remindMe)
    }

    func testRemindersArePlannedOnlyForOpenFutureReviewsWithRemindersOn() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        var trial = ToolEvaluation(now: start)
        trial.toolName = "Draftly"
        trial.status = .inTrial
        trial.reviewDate = start + 3 * day
        trial.remindMe = true
        var off = trial
        off.id = UUID()
        off.remindMe = false
        var kept = trial
        kept.id = UUID()
        kept.status = .kept
        var past = trial
        past.id = UUID()
        past.reviewDate = start - 2 * day
        var noDate = trial
        noDate.id = UUID()
        noDate.reviewDate = nil

        let plan = PlannedReminder.plan([trial, off, kept, past, noDate], now: start, calendar: calendar)
        XCTAssertEqual(plan.count, 1)
        let reminder = try XCTUnwrap(plan.first)
        XCTAssertEqual(reminder.identifier, PlannedReminder.identifierPrefix + trial.id.uuidString)
        XCTAssertEqual(reminder.title, "Review Draftly")
        XCTAssertTrue(reminder.body.contains("trial"))
        let expected = calendar.dateComponents([.year, .month, .day], from: start + 3 * day)
        XCTAssertEqual(reminder.fireDate.year, expected.year)
        XCTAssertEqual(reminder.fireDate.month, expected.month)
        XCTAssertEqual(reminder.fireDate.day, expected.day)
        XCTAssertEqual(reminder.fireDate.hour, PlannedReminder.hour)
    }

    @MainActor
    func testModelKeepsScheduledRemindersInStep() async throws {
        let scheduler = RecordingReminders()
        let model = await unlockedModel()
        model.reminders = scheduler
        let id = model.newEvaluation(now: start)
        _ = model.startTrial(for: id, now: start)
        var evaluation = try XCTUnwrap(model.evaluations.first)
        evaluation.remindMe = true
        model.update(evaluation, now: start)
        XCTAssertEqual(scheduler.last?.count, 1)

        evaluation = try XCTUnwrap(model.evaluations.first)
        evaluation.status = .kept
        model.update(evaluation, now: start + day)
        XCTAssertEqual(scheduler.last?.count, 0, "a settled decision has no reminder")

        _ = model.deleteAllUserData()
        XCTAssertEqual(scheduler.last?.count, 0)
    }

    func testReviewIsDueOnItsDateOnlyWhileOpen() {
        var evaluation = ToolEvaluation(now: start)
        XCTAssertFalse(evaluation.isReviewDue(now: start))
        evaluation.reviewDate = start
        XCTAssertTrue(evaluation.isReviewDue(now: start))
        XCTAssertFalse(evaluation.isReviewDue(now: start - day))
        evaluation.status = .dropped
        XCTAssertFalse(evaluation.isReviewDue(now: start + day))
    }

    @MainActor
    func testSummaryAndPayrollUseLinkedRecordsAndOnlyAddMatchingPrices() async throws {
        let model = await unlockedModel()
        func keep(_ name: String, price: Decimal?, note: String, keptAt: Date) throws -> UUID {
            let id = model.newEvaluation(now: keptAt)
            let costID = try XCTUnwrap(model.attachCostWorksheet(to: id))
            var sheet = try XCTUnwrap(model.costs.first { $0.id == costID })
            sheet.monthlyPrice = price
            sheet.priceNote = note
            model.update(sheet)
            var evaluation = try XCTUnwrap(model.evaluations.first { $0.id == id })
            evaluation.toolName = name
            evaluation.status = .kept
            model.update(evaluation, now: keptAt)
            return id
        }
        let now = start + 200 * day
        _ = try keep("Draftly", price: 20, note: "USD", keptAt: start)            // kept 200 days ago
        _ = try keep("Sortwise", price: Decimal(string: "12.50"), note: "USD", keptAt: now - day)
        let considering = model.newEvaluation(now: now)

        let summaries = model.evaluations.map { DecisionSummary($0, model: model) }
        let pending = try XCTUnwrap(summaries.first { $0.id == considering })
        XCTAssertEqual(pending.filterAnswered, 0)
        XCTAssertEqual(pending.filterTotal, model.book.tools.filterQuestions.count)
        XCTAssertNil(pending.cost)
        XCTAssertNil(pending.checklistDone)

        var payroll = SoftwarePayroll(summaries, now: now)
        XCTAssertEqual(payroll.rows.map(\.name).sorted(), ["Draftly", "Sortwise"])
        XCTAssertEqual(payroll.total, Decimal(string: "32.50"))
        XCTAssertEqual(payroll.totalNote, "USD")
        XCTAssertEqual(payroll.rows.first { $0.name == "Draftly" }?.reviewSuggested, true)
        XCTAssertEqual(payroll.rows.first { $0.name == "Sortwise" }?.reviewSuggested, false)

        // A different note (another currency) means no total rather than a wrong one.
        _ = try keep("Ledgerly", price: 9, note: "GBP", keptAt: now)
        payroll = SoftwarePayroll(model.evaluations.map { DecisionSummary($0, model: model) }, now: now)
        XCTAssertEqual(payroll.rows.count, 3)
        XCTAssertNil(payroll.total)
    }

    func testTrialReviewAnswersDecodeWithDefaults() throws {
        var evaluation = ToolEvaluation(now: start)
        evaluation.reviewSavedTime = .yes
        evaluation.reviewRework = .sometimes
        let data = try FileStore.encoder.encode(evaluation)
        let decoded = try FileStore.decoder.decode(ToolEvaluation.self, from: data)
        XCTAssertEqual(decoded, evaluation)
        XCTAssertEqual(decoded.lastStatusDate, start)
    }
}

@MainActor
private final class RecordingReminders: ReviewReminderScheduling {
    private(set) var last: [PlannedReminder]?
    func requestPermission() async -> Bool { true }
    func replaceAll(with reminders: [PlannedReminder]) { last = reminders }
}
