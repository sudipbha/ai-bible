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
    }

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
