import SwiftUI

// Each detail view edits a local draft and writes it back on every change,
// so work is saved without a Save button.

struct FilterDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var draft: FilterRecord

    init(record: FilterRecord) {
        _draft = State(initialValue: record)
    }

    var body: some View {
        let questions = model.book.tools.filterQuestions
        Form {
            Section("What are you checking?") {
                TextField("Task you want help with", text: $draft.taskName)
                    .accessibilityIdentifier("filter.task")
                TextField("Tool you're considering", text: $draft.toolName)
                    .accessibilityIdentifier("filter.tool")
            }
            ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                Section("Question \(index + 1) of \(questions.count)") {
                    Text(InlineText.attributed(question.text))
                    Picker("Answer", selection: answer(question.id)) {
                        ForEach(FilterAnswer.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("filter.answer.\(question.id)")
                    TextField("Note (optional)", text: note(question.id), axis: .vertical)
                }
            }
            Section("Summary") {
                let tally = draft.tally(questions: questions)
                Text("Yes \(tally.yes) · No \(tally.no) · Not sure \(tally.unsure) · Not answered \(tally.unanswered)")
                    .accessibilityIdentifier("filter.summary")
                Text("The app records your answers. The decision is yours.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Filter check")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: ToolExport.text(draft, questions: questions)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .onChange(of: draft) { _, new in model.update(new) }
    }

    private func answer(_ id: String) -> Binding<FilterAnswer> {
        Binding(get: { draft.answers[id] ?? .unanswered }, set: { draft.answers[id] = $0 })
    }

    private func note(_ id: String) -> Binding<String> {
        Binding(get: { draft.notes[id] ?? "" }, set: { draft.notes[id] = $0.isEmpty ? nil : $0 })
    }
}

struct RolloutDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var draft: RolloutRecord
    @State private var unlockPresented = false

    init(record: RolloutRecord) {
        _draft = State(initialValue: record)
    }

    var body: some View {
        let items = model.book.tools.rolloutItems
        let editable = model.canEdit(.rollout)
        Form {
            if !editable {
                ReadOnlyBanner { unlockPresented = true }
            }
            Group {
                Section("Tool on trial") {
                    TextField("Tool name", text: $draft.toolName)
                        .accessibilityIdentifier("rollout.toolName")
                    DatePicker("Started", selection: $draft.startDate, displayedComponents: .date)
                    Toggle("Set a review date", isOn: hasReviewDate)
                    if let review = draft.reviewDate {
                        DatePicker("Review on", selection: Binding(get: { review }, set: { draft.reviewDate = $0 }),
                                   displayedComponents: .date)
                    }
                }
                Section {
                    ForEach(items) { item in
                        Toggle(isOn: done(item.id)) {
                            Text(InlineText.attributed(item.text))
                        }
                        .accessibilityIdentifier("rollout.step.\(item.id)")
                    }
                } header: {
                    let progress = draft.progress(items: items)
                    Text("Checklist: \(progress.done) of \(progress.total) done")
                        .accessibilityIdentifier("rollout.progress")
                }
                Section("Notes") {
                    TextField("What's working, what isn't", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...12)
                }
            }
            .disabled(!editable)
        }
        .navigationTitle(draft.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: ToolExport.text(draft, items: items)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .onChange(of: draft) { _, new in model.update(new) }
        .sheet(isPresented: $unlockPresented) { UnlockSheet() }
    }

    private var hasReviewDate: Binding<Bool> {
        Binding(
            get: { draft.reviewDate != nil },
            set: { on in
                draft.reviewDate = on
                    ? Calendar.current.date(byAdding: .day, value: 14, to: draft.startDate)
                    : nil
            }
        )
    }

    private func done(_ id: String) -> Binding<Bool> {
        Binding(
            get: { draft.done.contains(id) },
            set: { isDone in
                if isDone { draft.done.insert(id) } else { draft.done.remove(id) }
            }
        )
    }
}

struct CostDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var draft: CostWorksheet
    @State private var unlockPresented = false

    init(sheet: CostWorksheet) {
        _draft = State(initialValue: sheet)
    }

    var body: some View {
        let editable = model.canEdit(.cost)
        let sheet = draft
        Form {
            if !editable {
                ReadOnlyBanner { unlockPresented = true }
            }
            Group {
                Section {
                    TextField("Worksheet name", text: $draft.title)
                        .accessibilityIdentifier("cost.title")
                    numberField("Tasks per period (for example, a month)", value: $draft.tasks, id: "cost.tasks")
                    numberField("Manual minutes per task", value: $draft.manualMinutesPerTask, id: "cost.manual")
                    numberField("Whole-job minutes per task with the tool", value: $draft.wholeJobMinutesPerTask, id: "cost.wholeJob")
                    numberField("One-time setup minutes", value: $draft.oneTimeSetupMinutes, id: "cost.setup")
                } header: {
                    Text("Your numbers")
                } footer: {
                    Text("Whole-job minutes include preparing, checking, correcting and approving each task, not just the time the tool runs.")
                }
            }
            .disabled(!editable)

            Section {
                if let results = sheet.results {
                    LabeledContent("Manual", value: MinutesFormat.string(results.manualMinutes))
                    LabeledContent("First trial period", value: MinutesFormat.string(results.firstTrialMinutes))
                    LabeledContent("Later periods", value: MinutesFormat.string(results.laterMinutes))
                    LabeledContent("First period", value: MinutesFormat.capacityChange(results.firstPeriodCapacityChange))
                    LabeledContent("Later periods", value: MinutesFormat.capacityChange(results.laterCapacityChange))
                } else {
                    Text("Results aren't shown until these entries are fixed:")
                    ForEach(sheet.validationIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle")
                    }
                }
            } header: {
                Text("Time per period")
            } footer: {
                Text("First trial = tasks × whole-job minutes + setup. Later = tasks × whole-job minutes. This is time capacity, not cash.")
            }

            Group {
                Section {
                    TextField("Monthly tool price (optional)", value: $draft.monthlyPrice, format: .number)
                        .keyboardType(.decimalPad)
                    TextField("Currency and notes, e.g. USD, before tax", text: $draft.priceNote)
                } header: {
                    Text("Money (kept separate)")
                } footer: {
                    Text("The price is shown as you enter it. The worksheet doesn't turn time into money or call freed time a saving.")
                }
            }
            .disabled(!editable)
        }
        .navigationTitle(draft.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: ToolExport.text(sheet)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .onChange(of: draft) { _, new in model.update(new) }
        .sheet(isPresented: $unlockPresented) { UnlockSheet() }
    }

    private func numberField(_ title: String, value: Binding<Int>, id: String) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(id)
        }
    }

    private func numberField(_ title: String, value: Binding<Double>, id: String) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(id)
        }
    }
}
