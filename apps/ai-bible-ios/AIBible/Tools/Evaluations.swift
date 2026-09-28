import Foundation

/// Where one AI tool stands in the owner's decision.
enum EvaluationStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case considering
    case inTrial
    case kept
    case dropped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .considering: "Considering"
        case .inTrial: "In trial"
        case .kept: "Kept"
        case .dropped: "Dropped"
        }
    }

    var systemImage: String {
        switch self {
        case .considering: "questionmark.circle"
        case .inTrial: "clock"
        case .kept: "checkmark.circle"
        case .dropped: "xmark.circle"
        }
    }

    /// Still being decided, so a review date and reminder still apply.
    var isOpen: Bool { self == .considering || self == .inTrial }
}

/// How often the tool's output needed fixing during the trial, as the owner judged it.
enum ReworkLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case unanswered
    case rarely
    case sometimes
    case often

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unanswered: "Not answered"
        case .rarely: "Rarely"
        case .sometimes: "Sometimes"
        case .often: "Often"
        }
    }
}

struct StatusChange: Codable, Sendable, Equatable {
    var status: EvaluationStatus
    var date: Date
}

/// One AI tool the owner is deciding about, for one task. It ties together that tool's
/// Filter check, cost worksheet and trial (rollout) record, and keeps a dated history of
/// the decision. The app records the owner's decision; it never makes or scores it.
struct ToolEvaluation: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var toolName = ""
    var taskName = ""
    var createdAt = Date()
    var updatedAt = Date()
    var status = EvaluationStatus.considering
    var history: [StatusChange] = []
    var filterID: UUID?
    var costID: UUID?
    var rolloutID: UUID?
    var reviewDate: Date?
    /// A local notification on the review date. Nothing leaves the device.
    var remindMe = false
    var decisionNote = ""
    /// Trial review: did the whole job take less time with the tool?
    var reviewSavedTime = FilterAnswer.unanswered
    /// Trial review: how often its output had to be fixed.
    var reviewRework = ReworkLevel.unanswered

    init(now: Date = Date()) {
        createdAt = now
        updatedAt = now
        history = [StatusChange(status: .considering, date: now)]
    }

    // Tolerant decoding, as for UserData: later fields fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName) ?? ""
        taskName = try c.decodeIfPresent(String.self, forKey: .taskName) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        status = try c.decodeIfPresent(EvaluationStatus.self, forKey: .status) ?? .considering
        history = try c.decodeIfPresent([StatusChange].self, forKey: .history) ?? []
        filterID = try c.decodeIfPresent(UUID.self, forKey: .filterID)
        costID = try c.decodeIfPresent(UUID.self, forKey: .costID)
        rolloutID = try c.decodeIfPresent(UUID.self, forKey: .rolloutID)
        reviewDate = try c.decodeIfPresent(Date.self, forKey: .reviewDate)
        remindMe = try c.decodeIfPresent(Bool.self, forKey: .remindMe) ?? false
        decisionNote = try c.decodeIfPresent(String.self, forKey: .decisionNote) ?? ""
        reviewSavedTime = try c.decodeIfPresent(FilterAnswer.self, forKey: .reviewSavedTime) ?? .unanswered
        reviewRework = try c.decodeIfPresent(ReworkLevel.self, forKey: .reviewRework) ?? .unanswered
    }

    /// When the decision last changed status.
    var lastStatusDate: Date { history.last?.date ?? createdAt }

    var displayName: String {
        toolName.isEmpty ? "Untitled tool" : toolName
    }

    /// Sets the status and records the change with its date. Setting the same status again
    /// records nothing.
    mutating func setStatus(_ new: EvaluationStatus, at date: Date = Date()) {
        guard new != status else { return }
        status = new
        history.append(StatusChange(status: new, date: date))
    }

    /// True when a review date is set, the decision is still open, and the date has passed.
    func isReviewDue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard status.isOpen, let reviewDate else { return false }
        return calendar.startOfDay(for: reviewDate) <= calendar.startOfDay(for: now)
    }
}

/// A reminder the app should have scheduled: one per open evaluation with a future review
/// date and reminders turned on. Pure planning, so it is tested without the notification center.
struct PlannedReminder: Equatable, Sendable {
    static let identifierPrefix = "aibible.review."
    static let hour = 9

    var identifier: String
    var title: String
    var body: String
    /// Year, month, day and hour in the owner's calendar.
    var fireDate: DateComponents

    static func plan(_ evaluations: [ToolEvaluation], now: Date = Date(),
                     calendar: Calendar = .current) -> [PlannedReminder] {
        evaluations.compactMap { evaluation in
            guard evaluation.remindMe, evaluation.status.isOpen, let reviewDate = evaluation.reviewDate else { return nil }
            var components = calendar.dateComponents([.year, .month, .day], from: reviewDate)
            components.hour = hour
            guard let fire = calendar.date(from: components), fire > now else { return nil }
            let what = evaluation.status == .inTrial ? "trial" : "decision"
            return PlannedReminder(
                identifier: identifierPrefix + evaluation.id.uuidString,
                title: "Review \(evaluation.displayName)",
                body: "Your \(what) review date is today. Record whether you keep it or drop it.",
                fireDate: components)
        }
    }
}

/// Everything the comparison and payroll views show for one tool, gathered from its linked records.
struct DecisionSummary: Equatable, Identifiable {
    var id: UUID { evaluation.id }
    var evaluation: ToolEvaluation
    var filterYes: Int?
    var filterAnswered: Int?
    var filterTotal: Int
    var cost: CostWorksheet.Results?
    var monthlyPrice: Decimal?
    var priceNote: String
    var checklistDone: Int?
    var checklistTotal: Int

    @MainActor
    init(_ evaluation: ToolEvaluation, model: AppModel) {
        self.evaluation = evaluation
        let questions = model.book.tools.filterQuestions
        filterTotal = questions.count
        if let id = evaluation.filterID, let filter = model.filters.first(where: { $0.id == id }) {
            let tally = filter.tally(questions: questions)
            filterYes = tally.yes
            filterAnswered = questions.count - tally.unanswered
        }
        let sheet = evaluation.costID.flatMap { id in model.costs.first { $0.id == id } }
        cost = sheet?.results
        monthlyPrice = sheet?.isValid == true ? sheet?.monthlyPrice : nil
        priceNote = sheet?.priceNote.trimmingCharacters(in: .whitespaces) ?? ""
        let items = model.book.tools.rolloutItems
        checklistTotal = items.count
        if let id = evaluation.rolloutID, let rollout = model.rollouts.first(where: { $0.id == id }) {
            checklistDone = rollout.progress(items: items).done
        }
    }
}

/// The tools the owner decided to keep, with the monthly price each worksheet records. Prices are
/// added up only when every one was entered with the same note (for example "USD, before tax"),
/// because the app never assumes or converts a currency.
struct SoftwarePayroll: Equatable {
    static let reviewAfterDays = 90

    struct Row: Equatable, Identifiable {
        var id: UUID
        var name: String
        var monthlyPrice: Decimal?
        var priceNote: String
        /// Kept for longer than `reviewAfterDays` without a newer decision.
        var reviewSuggested: Bool
    }

    var rows: [Row]
    /// Nil when a price is missing or the notes differ.
    var total: Decimal?
    var totalNote: String

    init(_ summaries: [DecisionSummary], now: Date = Date(), calendar: Calendar = .current) {
        rows = summaries.filter { $0.evaluation.status == .kept }.map { summary in
            let age = calendar.dateComponents([.day], from: summary.evaluation.lastStatusDate, to: now).day ?? 0
            return Row(id: summary.id, name: summary.evaluation.displayName, monthlyPrice: summary.monthlyPrice,
                       priceNote: summary.priceNote, reviewSuggested: age > Self.reviewAfterDays)
        }
        let notes = Set(rows.map(\.priceNote))
        if !rows.isEmpty, rows.allSatisfy({ $0.monthlyPrice != nil }), notes.count == 1 {
            total = rows.compactMap(\.monthlyPrice).reduce(0, +)
            totalNote = notes.first ?? ""
        } else {
            total = nil
            totalNote = ""
        }
    }
}
