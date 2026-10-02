import Foundation

/// Plain-text exports for the share sheet. Built entirely on the device; nothing is uploaded.
enum ToolExport {
    static func text(_ record: FilterRecord, questions: [ToolPrompt]) -> String {
        var lines = ["Five-Question Filter", record.displayName, ""]
        for (index, question) in questions.enumerated() {
            let answer = record.answers[question.id] ?? .unanswered
            lines.append("\(index + 1). \(InlineText.plain(question.text))")
            lines.append("   Answer: \(answer.title)")
            if let note = record.notes[question.id], !note.isEmpty {
                lines.append("   Note: \(note)")
            }
        }
        let tally = record.tally(questions: questions)
        lines.append("")
        lines.append("Yes \(tally.yes) · No \(tally.no) · Not sure \(tally.unsure) · Not answered \(tally.unanswered)")
        lines.append(footer(updated: record.updatedAt))
        return lines.joined(separator: "\n")
    }

    static func text(_ record: RolloutRecord, items: [ToolPrompt]) -> String {
        var lines = ["Rollout tracker", record.displayName, ""]
        lines.append("Started: \(dateString(record.startDate))")
        if let review = record.reviewDate {
            lines.append("Review on: \(dateString(review))")
        }
        let progress = record.progress(items: items)
        lines.append("Done: \(progress.done) of \(progress.total)")
        lines.append("")
        for item in items {
            lines.append("[\(record.done.contains(item.id) ? "x" : " ")] \(InlineText.plain(item.text))")
        }
        if !record.notes.isEmpty {
            lines.append("")
            lines.append("Notes: \(record.notes)")
        }
        lines.append(footer(updated: record.updatedAt))
        return lines.joined(separator: "\n")
    }

    static func text(_ sheet: CostWorksheet) -> String {
        let tasks = sheet.tasks
        var lines = ["Whole-job cost worksheet", sheet.displayName, ""]
        lines.append("Time per period")
        if let results = sheet.results {
            lines.append("Manual: \(tasks) tasks × \(number(sheet.manualMinutesPerTask)) min = \(MinutesFormat.string(results.manualMinutes))")
            lines.append("First trial period: \(tasks) tasks × \(number(sheet.wholeJobMinutesPerTask)) min whole-job + \(number(sheet.oneTimeSetupMinutes)) min one-time setup = \(MinutesFormat.string(results.firstTrialMinutes))")
            lines.append("Later periods: \(tasks) tasks × \(number(sheet.wholeJobMinutesPerTask)) min whole-job = \(MinutesFormat.string(results.laterMinutes))")
            lines.append("First period: \(MinutesFormat.capacityChange(results.firstPeriodCapacityChange))")
            lines.append("Later periods: \(MinutesFormat.capacityChange(results.laterCapacityChange))")
        } else {
            lines.append("Results aren't shown until these entries are fixed:")
            lines.append(contentsOf: sheet.validationIssues.map { "- \($0)" })
        }
        lines.append("Whole-job minutes include preparing, checking, correcting and approving each task.")
        lines.append("")
        lines.append("Money (kept separate from time)")
        if let price = sheet.monthlyPrice {
            let note = sheet.priceNote.isEmpty ? "" : " (\(sheet.priceNote))"
            lines.append("Tool price per month, as entered: \(price)\(note)")
        } else {
            lines.append("Tool price per month: not entered")
        }
        lines.append(footer(updated: sheet.updatedAt))
        return lines.joined(separator: "\n")
    }

    /// A one-tool decision summary: status and history, review date, the owner's note, then the
    /// linked Filter, cost and trial records in full.
    @MainActor
    static func text(_ evaluation: ToolEvaluation, model: AppModel) -> String {
        var lines = ["AI tool decision", evaluation.displayName]
        if !evaluation.taskName.isEmpty { lines.append("Task: \(evaluation.taskName)") }
        lines.append("Status: \(evaluation.status.title)")
        for change in evaluation.history {
            lines.append("  \(change.status.title) since \(dateString(change.date))")
        }
        if evaluation.status.isOpen, let review = evaluation.reviewDate {
            lines.append("Review date: \(dateString(review))")
        }
        if evaluation.reviewSavedTime != .unanswered {
            lines.append("Trial review — whole job took less time: \(evaluation.reviewSavedTime.title)")
        }
        if evaluation.reviewRework != .unanswered {
            lines.append("Trial review — output needed fixing: \(evaluation.reviewRework.title)")
        }
        if !evaluation.decisionNote.isEmpty { lines.append("Note: \(evaluation.decisionNote)") }
        let tools = model.book.tools
        if let id = evaluation.filterID, let record = model.filters.first(where: { $0.id == id }) {
            lines += ["", "----", text(record, questions: tools.filterQuestions)]
        }
        if let id = evaluation.costID, let sheet = model.costs.first(where: { $0.id == id }) {
            lines += ["", "----", text(sheet)]
        }
        if let id = evaluation.rolloutID, let record = model.rollouts.first(where: { $0.id == id }) {
            lines += ["", "----", text(record, items: tools.rolloutItems)]
        }
        lines.append(footer(updated: evaluation.updatedAt))
        return lines.joined(separator: "\n")
    }

    static func number(_ value: Double) -> String {
        guard value.isFinite, abs(value) <= MinutesFormat.maxFormattable else { return "invalid" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func dateString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func footer(updated: Date) -> String {
        "\nLast updated \(dateString(updated)). Saved on this device in AI Bible."
    }
}
