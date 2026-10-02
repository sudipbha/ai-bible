import SwiftUI

enum DecisionRoute: Hashable {
    case evaluation(UUID)
    case filter(UUID)
    case rollout(UUID)
    case cost(UUID)
    case compare
    case payroll
}

/// "My AI tool decisions": every AI tool the owner is deciding about, grouped by where it
/// stands, with its next review date. The book's method is run here on the owner's own tools.
struct DecisionsTab: View {
    @Environment(AppModel.self) private var model
    @State private var path: [DecisionRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.evaluations.isEmpty {
                    onboarding
                } else {
                    list
                }
            }
            .navigationTitle("My AI tool decisions")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: IntentRouter.shared.pendingNewEvaluation, initial: true) { _, pending in
                // "Evaluate an AI tool" from Siri or Shortcuts.
                guard pending else { return }
                IntentRouter.shared.pendingNewEvaluation = false
                path = [.evaluation(model.newEvaluation())]
            }
            .navigationDestination(for: DecisionRoute.self) { route in
                switch route {
                case .evaluation(let id):
                    if let evaluation = model.evaluations.first(where: { $0.id == id }) {
                        EvaluationDetailView(evaluation: evaluation, path: $path)
                    } else {
                        deletedView
                    }
                case .filter(let id):
                    if let record = model.filters.first(where: { $0.id == id }) { FilterDetailView(record: record) } else { deletedView }
                case .rollout(let id):
                    if let record = model.rollouts.first(where: { $0.id == id }) { RolloutDetailView(record: record) } else { deletedView }
                case .cost(let id):
                    if let sheet = model.costs.first(where: { $0.id == id }) { CostDetailView(sheet: sheet) } else { deletedView }
                case .compare:
                    CompareView(path: $path)
                case .payroll:
                    PayrollView()
                }
            }
        }
    }

    private var onboarding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Decide about an AI tool in three steps")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                step(1, "Run the Five-Question Filter", "Check the tool against the task you want help with.")
                step(2, "Work out the whole-job cost", "Include setup, checking and rework, not just the tool's price.")
                step(3, "Try it with a review date", "Follow the rollout checklist, then record whether you keep it or drop it.")
                Button {
                    path.append(.evaluation(model.newEvaluation()))
                } label: {
                    Label("Evaluate my first AI tool", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("decisions.start")
                Text("Everything stays on this iPhone. Each step links to the chapter that explains it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(minWidth: 28, minHeight: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title). \(detail)")
    }

    private var list: some View {
        List {
            Section {
                NavigationLink(value: DecisionRoute.compare) {
                    Label("Compare tools side by side", systemImage: "rectangle.split.3x1")
                }
                .accessibilityIdentifier("decisions.compare")
                NavigationLink(value: DecisionRoute.payroll) {
                    Label("Software payroll", systemImage: "creditcard")
                }
                .accessibilityIdentifier("decisions.payroll")
            }
            ForEach(EvaluationStatus.allCases.sorted(by: Self.listOrder)) { status in
                let group = model.evaluations.filter { $0.status == status }
                if !group.isEmpty {
                    Section(status.title) {
                        ForEach(group) { evaluation in
                            NavigationLink(value: DecisionRoute.evaluation(evaluation.id)) {
                                EvaluationRow(evaluation: evaluation)
                            }
                            .accessibilityIdentifier("decisions.row.\(evaluation.id.uuidString)")
                        }
                        .onDelete { offsets in
                            model.deleteEvaluations(ids: Set(offsets.map { group[$0].id }))
                        }
                    }
                }
            }
            Section {
                Button("Evaluate another AI tool", systemImage: "plus") {
                    path.append(.evaluation(model.newEvaluation()))
                }
                .accessibilityIdentifier("decisions.new")
            } footer: {
                Text("Deleting a decision keeps its Filter, cost and trial records in Tools.")
            }
        }
        .accessibilityIdentifier("decisions.list")
    }

    /// Open decisions first, then settled ones.
    private static func listOrder(_ a: EvaluationStatus, _ b: EvaluationStatus) -> Bool {
        let order: [EvaluationStatus] = [.inTrial, .considering, .kept, .dropped]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }

    private var deletedView: some View {
        ContentUnavailableView("This record was deleted", systemImage: "trash")
    }
}

private struct EvaluationRow: View {
    let evaluation: ToolEvaluation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: evaluation.status.systemImage)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(evaluation.displayName)
                if !evaluation.taskName.isEmpty {
                    Text(evaluation.taskName).font(.subheadline).foregroundStyle(.secondary)
                }
                if evaluation.status.isOpen, let date = evaluation.reviewDate {
                    Text(evaluation.isReviewDue() ? "Review due" : "Review \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.subheadline)
                        .foregroundStyle(evaluation.isReviewDue() ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
        }
    }
}

/// One tool's decision: its names, the three guided steps, the review date and reminder,
/// and the recorded status with its history.
struct EvaluationDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var draft: ToolEvaluation
    @Binding var path: [DecisionRoute]
    @State private var unlockPresented = false
    @State private var chapterToShow: ChapterLink?
    @State private var notificationsDenied = false

    init(evaluation: ToolEvaluation, path: Binding<[DecisionRoute]>) {
        _draft = State(initialValue: evaluation)
        _path = path
    }

    var body: some View {
        Form {
            Section("Which tool, for which task?") {
                TextField("AI tool", text: $draft.toolName)
                    .accessibilityIdentifier("evaluation.tool")
                TextField("Task you want help with", text: $draft.taskName)
                    .accessibilityIdentifier("evaluation.task")
            }

            Section {
                filterStep
                costStep
                trialStep
            } header: {
                Text("Steps")
            } footer: {
                Text("The app records your answers and figures. The decision is yours.")
            }

            Section("Decision") {
                Picker("Status", selection: $draft.status) {
                    ForEach(EvaluationStatus.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                .accessibilityIdentifier("evaluation.status")
                if !draft.status.isOpen {
                    TextField("Why? (optional)", text: $draft.decisionNote, axis: .vertical)
                        .accessibilityIdentifier("evaluation.decisionNote")
                }
                ForEach(Array(draft.history.enumerated().reversed()), id: \.offset) { _, change in
                    LabeledContent(change.status.title, value: change.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if draft.status == .inTrial {
                Section {
                    Picker("Did the whole job take less time?", selection: $draft.reviewSavedTime) {
                        ForEach(FilterAnswer.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("evaluation.review.savedTime")
                    Picker("How often did you fix its output?", selection: $draft.reviewRework) {
                        ForEach(ReworkLevel.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("evaluation.review.rework")
                    HStack {
                        Button("Keep it") { draft.status = .kept }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("evaluation.keep")
                        Spacer()
                        Button("Drop it", role: .destructive) { draft.status = .dropped }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("evaluation.drop")
                    }
                } header: {
                    Text(draft.isReviewDue() ? "Trial review — due" : "Trial review")
                } footer: {
                    Text("Re-run the cost worksheet with what really happened before you decide.")
                }
            }

            if draft.status.isOpen {
                Section {
                    Toggle("Set a review date", isOn: hasReviewDate)
                        .accessibilityIdentifier("evaluation.hasReviewDate")
                    if let date = draft.reviewDate {
                        DatePicker("Review on", selection: Binding(get: { date }, set: { draft.reviewDate = $0 }),
                                   displayedComponents: .date)
                        Toggle("Remind me that morning", isOn: remindMe)
                            .accessibilityIdentifier("evaluation.remindMe")
                    }
                } header: {
                    Text("Review")
                } footer: {
                    if notificationsDenied {
                        Text("Notifications are off for this app. You can turn them on in the iPhone's Settings.")
                    } else {
                        Text("The reminder is a notification on this iPhone at \(PlannedReminder.hour):00. Nothing is sent anywhere.")
                    }
                }
            }
        }
        .navigationTitle(draft.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: ToolExport.text(draft, model: model)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .onChange(of: draft) { _, new in model.update(new) }
        .onChange(of: model.evaluations) { _, all in
            // The model records status history and attaches steps (cost, trial); show what it saved.
            if let saved = all.first(where: { $0.id == draft.id }), saved != draft {
                draft = saved
            }
        }
        .sheet(isPresented: $unlockPresented) { UnlockSheet() }
        .sheet(item: $chapterToShow) { link in
            NavigationStack {
                ReaderView(position: ReaderPosition(chapterID: link.id, blockID: nil), open: { _ in })
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { chapterToShow = nil }
                        }
                    }
            }
        }
    }

    // MARK: Steps

    private var filterStep: some View {
        let questions = model.book.tools.filterQuestions
        let tally = draft.filterID.flatMap { id in model.filters.first { $0.id == id } }?.tally(questions: questions)
        let answered = tally.map { questions.count - $0.unanswered } ?? 0
        return stepRow(
            number: 1, title: "Five-Question Filter",
            detail: "\(answered) of \(questions.count) answered",
            done: !questions.isEmpty && answered == questions.count,
            chapter: model.book.tools.filterChapterID,
            identifier: "evaluation.step.filter"
        ) {
            if let id = draft.filterID { path.append(.filter(id)) }
        }
    }

    private var costStep: some View {
        let sheet = draft.costID.flatMap { id in model.costs.first { $0.id == id } }
        let detail: String
        if let sheet {
            detail = sheet.results.map { "Later periods: \(MinutesFormat.string($0.laterMinutes))" } ?? "Some entries need fixing"
        } else {
            detail = model.canEdit(.cost) ? "Not started" : "Included with the full book"
        }
        return stepRow(
            number: 2, title: "Whole-job cost", detail: detail, done: sheet?.results != nil,
            chapter: model.book.tools.costChapterID, identifier: "evaluation.step.cost"
        ) {
            if let id = draft.costID {
                path.append(.cost(id))
            } else if let id = model.attachCostWorksheet(to: draft.id) {
                path.append(.cost(id))
            } else {
                unlockPresented = true
            }
        }
    }

    private var trialStep: some View {
        let items = model.book.tools.rolloutItems
        let rollout = draft.rolloutID.flatMap { id in model.rollouts.first { $0.id == id } }
        let detail: String
        if let rollout {
            let progress = rollout.progress(items: items)
            detail = "\(progress.done) of \(progress.total) checklist steps done"
        } else {
            detail = model.canEdit(.rollout) ? "Not started" : "Included with the full book"
        }
        return stepRow(
            number: 3, title: rollout == nil ? "Start a trial" : "Trial checklist", detail: detail,
            done: rollout.map { $0.progress(items: items).done == items.count && !items.isEmpty } ?? false,
            chapter: model.book.tools.rolloutChapterID, identifier: "evaluation.step.trial"
        ) {
            if let id = draft.rolloutID {
                path.append(.rollout(id))
            } else if let id = model.startTrial(for: draft.id) {
                path.append(.rollout(id))
            } else {
                unlockPresented = true
            }
        }
    }

    private func stepRow(number: Int, title: String, detail: String, done: Bool, chapter: String?,
                         identifier: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                        .font(.title2)
                        .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).foregroundStyle(.primary)
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Step \(number): \(title). \(detail)\(done ? ". Done" : "")")
            .accessibilityIdentifier(identifier)
            if let chapter, model.book.chapter(chapter) != nil {
                Button {
                    chapterToShow = ChapterLink(id: chapter)
                } label: {
                    Label("Why?", systemImage: "book")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Why this step? Read the chapter")
                .accessibilityIdentifier("\(identifier).why")
            }
        }
    }

    // MARK: Review bindings

    private var hasReviewDate: Binding<Bool> {
        Binding(
            get: { draft.reviewDate != nil },
            set: { on in
                draft.reviewDate = on ? (Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()) : nil
                if !on { draft.remindMe = false }
            })
    }

    private var remindMe: Binding<Bool> {
        Binding(
            get: { draft.remindMe },
            set: { on in
                guard on else { draft.remindMe = false; return }
                Task {
                    let allowed = await model.reminders?.requestPermission() ?? true
                    notificationsDenied = !allowed
                    draft.remindMe = allowed
                }
            })
    }
}

struct ChapterLink: Identifiable {
    var id: String
}
