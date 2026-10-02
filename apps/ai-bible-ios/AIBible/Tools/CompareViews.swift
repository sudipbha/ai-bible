import SwiftUI

/// Every tool still being decided or kept, side by side: Filter answers, whole-job time, monthly
/// price as entered, and trial progress. The app shows the figures; it doesn't rank the tools.
struct CompareView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: [DecisionRoute]

    var body: some View {
        let summaries = model.evaluations.filter { $0.status != .dropped }.map { DecisionSummary($0, model: model) }
        List {
            if summaries.isEmpty {
                ContentUnavailableView("Nothing to compare yet", systemImage: "rectangle.split.3x1",
                                       description: Text("Tools you're considering, trialling or keeping appear here."))
            }
            ForEach(summaries) { summary in
                Section {
                    row("Status", summary.evaluation.status.title)
                    row("Filter", summary.filterAnswered.map { "Yes \(summary.filterYes ?? 0) · \($0) of \(summary.filterTotal) answered" } ?? "Not started")
                    if let cost = summary.cost {
                        row("By hand, per period", MinutesFormat.string(cost.manualMinutes))
                        row("With the tool, later periods", MinutesFormat.string(cost.laterMinutes))
                    } else {
                        row("Whole-job cost", "Not worked out")
                    }
                    row("Price per month", summary.monthlyPrice.map { price in
                        summary.priceNote.isEmpty ? "\(price) (as entered)" : "\(price) \(summary.priceNote)"
                    } ?? "Not entered")
                    row("Trial checklist", summary.checklistDone.map { "\($0) of \(summary.checklistTotal) done" } ?? "Not started")
                } header: {
                    Button {
                        path.append(.evaluation(summary.id))
                    } label: {
                        Text(summary.evaluation.displayName).font(.headline)
                    }
                    .textCase(nil)
                }
            }
        }
        .navigationTitle("Compare tools")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("compare.list")
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }
}

/// Chapter 13's "software payroll": the tools you decided to keep, what each costs per month, and
/// which are due another look.
struct PayrollView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let payroll = SoftwarePayroll(model.evaluations.map { DecisionSummary($0, model: model) })
        List {
            if payroll.rows.isEmpty {
                ContentUnavailableView("No kept tools yet", systemImage: "creditcard",
                                       description: Text("When you mark a tool as Kept, it appears here with its monthly price."))
            } else {
                Section {
                    ForEach(payroll.rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent(row.name, value: row.monthlyPrice.map { "\($0)" } ?? "No price entered")
                            if !row.priceNote.isEmpty {
                                Text(row.priceNote).font(.footnote).foregroundStyle(.secondary)
                            }
                            if row.reviewSuggested {
                                Label("Kept for over \(SoftwarePayroll.reviewAfterDays) days: worth a fresh look",
                                      systemImage: "clock.arrow.circlepath")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } footer: {
                    Text("Prices come from each tool's cost worksheet, exactly as you entered them.")
                }
                Section {
                    if let total = payroll.total {
                        LabeledContent("Total per month", value: payroll.totalNote.isEmpty ? "\(total)" : "\(total) \(payroll.totalNote)")
                            .accessibilityIdentifier("payroll.total")
                    } else {
                        Text("No total: some prices are missing or were entered with different notes (for example, different currencies).")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Software payroll")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("payroll.list")
    }
}
