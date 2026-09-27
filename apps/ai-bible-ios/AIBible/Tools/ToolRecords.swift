import Foundation

enum ToolKind: String, Codable, Sendable, CaseIterable {
    case filter
    case rollout
    case cost

    /// The Filter is free along with Chapter 1. The other tools come with the full unlock.
    var isFree: Bool { self == .filter }
}

enum FilterAnswer: String, Codable, Sendable, CaseIterable, Identifiable {
    case unanswered
    case yes
    case no
    case unsure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unanswered: "Not answered"
        case .yes: "Yes"
        case .no: "No"
        case .unsure: "Not sure"
        }
    }
}

/// One saved run of the Five-Question Filter for a task and a tool.
/// The app records answers; it does not score them or recommend a decision.
struct FilterRecord: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var taskName = ""
    var toolName = ""
    var createdAt = Date()
    var updatedAt = Date()
    /// Question ID → answer.
    var answers: [String: FilterAnswer] = [:]
    /// Question ID → optional note.
    var notes: [String: String] = [:]

    struct Tally: Equatable {
        var yes = 0
        var no = 0
        var unsure = 0
        var unanswered = 0
    }

    func tally(questions: [ToolPrompt]) -> Tally {
        var tally = Tally()
        for question in questions {
            switch answers[question.id] ?? .unanswered {
            case .yes: tally.yes += 1
            case .no: tally.no += 1
            case .unsure: tally.unsure += 1
            case .unanswered: tally.unanswered += 1
            }
        }
        return tally
    }

    var displayName: String {
        let parts = [toolName, taskName].filter { !$0.isEmpty }
        return parts.isEmpty ? "Untitled Filter check" : parts.joined(separator: " · ")
    }
}

/// A probation period for one tool, tracked against the rollout checklist.
struct RolloutRecord: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var toolName = ""
    var startDate = Date()
    var reviewDate: Date?
    var createdAt = Date()
    var updatedAt = Date()
    /// IDs of checklist items marked done.
    var done: Set<String> = []
    var notes = ""

    func progress(items: [ToolPrompt]) -> (done: Int, total: Int) {
        (items.filter { done.contains($0.id) }.count, items.count)
    }

    var displayName: String {
        toolName.isEmpty ? "Untitled rollout" : toolName
    }
}

/// The whole-job cost worksheet. Time capacity and money are kept separate on
/// purpose: the worksheet never converts minutes into money or calls time a saving.
///
/// "Whole-job" minutes per task already include preparing, checking, correcting
/// and approving the work, not only the time the tool runs.
struct CostWorksheet: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var title = ""
    var createdAt = Date()
    var updatedAt = Date()

    var tasks = 0
    var manualMinutesPerTask: Double = 0
    var wholeJobMinutesPerTask: Double = 0
    var oneTimeSetupMinutes: Double = 0

    /// Entered by the owner, shown as entered. Never combined with the time figures.
    var monthlyPrice: Decimal?
    /// Free text such as "USD, before tax" — the app does not assume a currency.
    var priceNote = ""

    /// tasks × manual minutes
    var manualMinutes: Double {
        Double(tasks) * manualMinutesPerTask
    }

    /// tasks × whole-job minutes + one-time setup
    var firstTrialMinutes: Double {
        Double(tasks) * wholeJobMinutesPerTask + oneTimeSetupMinutes
    }

    /// tasks × whole-job minutes (setup already done)
    var laterMinutes: Double {
        Double(tasks) * wholeJobMinutesPerTask
    }

    /// Positive: time capacity freed. Negative: the trial period takes more time than doing it by hand.
    var firstPeriodCapacityChange: Double {
        manualMinutes - firstTrialMinutes
    }

    var laterCapacityChange: Double {
        manualMinutes - laterMinutes
    }

    // Input limits. They are far above any real small-business figure and keep every
    // product well inside the range that can be formatted safely.
    static let maxTasks = 1_000_000
    static let maxMinutesPerTask: Double = 100_000
    static let maxSetupMinutes: Double = 10_000_000

    /// Plain-language problems with the entered numbers. Results are shown only when
    /// this is empty; an invalid entry is never quietly turned into zero.
    var validationIssues: [String] {
        var issues: [String] = []
        if tasks < 0 {
            issues.append("Tasks per period can't be negative.")
        } else if tasks > Self.maxTasks {
            issues.append("Tasks per period must be \(Self.maxTasks.formatted()) or fewer.")
        }
        issues += Self.minuteIssues("Manual minutes per task", manualMinutesPerTask, limit: Self.maxMinutesPerTask)
        issues += Self.minuteIssues("Whole-job minutes per task", wholeJobMinutesPerTask, limit: Self.maxMinutesPerTask)
        issues += Self.minuteIssues("One-time setup minutes", oneTimeSetupMinutes, limit: Self.maxSetupMinutes)
        if let price = monthlyPrice {
            if price.isNaN {
                issues.append("The monthly price isn't a valid number.")
            } else if price < 0 {
                issues.append("The monthly price can't be negative.")
            }
        }
        return issues
    }

    var isValid: Bool { validationIssues.isEmpty }

    struct Results: Equatable {
        var manualMinutes: Double
        var firstTrialMinutes: Double
        var laterMinutes: Double
        var firstPeriodCapacityChange: Double
        var laterCapacityChange: Double
    }

    /// The worksheet's time figures, or nil when an entry is invalid.
    var results: Results? {
        guard isValid else { return nil }
        let results = Results(
            manualMinutes: manualMinutes,
            firstTrialMinutes: firstTrialMinutes,
            laterMinutes: laterMinutes,
            firstPeriodCapacityChange: firstPeriodCapacityChange,
            laterCapacityChange: laterCapacityChange
        )
        let all = [results.manualMinutes, results.firstTrialMinutes, results.laterMinutes,
                   results.firstPeriodCapacityChange, results.laterCapacityChange]
        return all.allSatisfy { $0.isFinite && abs($0) <= MinutesFormat.maxFormattable } ? results : nil
    }

    private static func minuteIssues(_ name: String, _ value: Double, limit: Double) -> [String] {
        if !value.isFinite { return ["\(name) isn't a valid number."] }
        if value < 0 { return ["\(name) can't be negative."] }
        if value > limit { return ["\(name) must be \(limit.formatted()) or fewer."] }
        return []
    }

    var displayName: String {
        title.isEmpty ? "Untitled worksheet" : title
    }
}

enum MinutesFormat {
    /// Largest magnitude formatted as minutes. Anything beyond it (or non-finite) is
    /// shown as out of range instead of being converted to an integer.
    static let maxFormattable: Double = 1_000_000_000_000
    static let outOfRange = "Out of range"

    /// "250 min (4 h 10 min)"; whole minutes are shown without decimals.
    static func string(_ minutes: Double) -> String {
        guard minutes.isFinite, abs(minutes) <= maxFormattable else { return outOfRange }
        let rounded = (minutes * 10).rounded() / 10
        let base = rounded == rounded.rounded()
            ? "\(Int(rounded)) min"
            : String(format: "%.1f min", rounded)
        let absolute = abs(rounded)
        guard absolute >= 60 else { return base }
        let total = Int(absolute.rounded())
        let hours = total / 60
        let rest = total % 60
        let clock = rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
        return "\(base) (\(clock))"
    }

    /// Signed change in capacity, worded so it is never read as cash.
    static func capacityChange(_ minutes: Double) -> String {
        guard minutes.isFinite, abs(minutes) <= maxFormattable else { return outOfRange }
        if minutes > 0 { return "\(string(minutes)) of time freed (time, not cash)" }
        if minutes < 0 { return "\(string(-minutes)) of extra time needed" }
        return "No change in time"
    }
}
