import SwiftUI

enum ToolRoute: Hashable {
    case filter(UUID)
    case rollout(UUID)
    case cost(UUID)
}

struct ToolsTab: View {
    @Environment(AppModel.self) private var model
    @State private var path: [ToolRoute] = []
    @State private var unlockPresented = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(model.filters) { record in
                        NavigationLink(value: ToolRoute.filter(record.id)) {
                            recordRow(record.displayName, detail: filterSummary(record))
                        }
                    }
                    .onDelete { offsets in
                        model.delete(.filter, ids: Set(offsets.map { model.filters[$0].id }))
                    }
                    Button("New Filter check", systemImage: "plus") {
                        path.append(.filter(model.newFilter()))
                    }
                } header: {
                    Text("Five-Question Filter")
                } footer: {
                    Text("Free. Save your answers for each task and tool you're considering.")
                }

                Section {
                    ForEach(model.rollouts) { record in
                        NavigationLink(value: ToolRoute.rollout(record.id)) {
                            let progress = record.progress(items: model.book.tools.rolloutItems)
                            recordRow(record.displayName, detail: "\(progress.done) of \(progress.total) steps done")
                        }
                    }
                    .onDelete { offsets in
                        model.delete(.rollout, ids: Set(offsets.map { model.rollouts[$0].id }))
                    }
                    newButton("New rollout", tool: .rollout) { model.newRollout().map(ToolRoute.rollout) }
                } header: {
                    Text("Rollout tracker")
                } footer: {
                    lockedFooter(.rollout, "Track a tool's trial period against the rollout checklist.")
                }

                Section {
                    ForEach(model.costs) { sheet in
                        NavigationLink(value: ToolRoute.cost(sheet.id)) {
                            recordRow(sheet.displayName, detail: sheet.results.map {
                                "Later periods: \(MinutesFormat.string($0.laterMinutes))"
                            } ?? "Some entries need fixing")
                        }
                    }
                    .onDelete { offsets in
                        model.delete(.cost, ids: Set(offsets.map { model.costs[$0].id }))
                    }
                    newButton("New cost worksheet", tool: .cost) { model.newCostWorksheet().map(ToolRoute.cost) }
                } header: {
                    Text("Whole-job cost worksheet")
                } footer: {
                    lockedFooter(.cost, "Compare manual time with whole-job time. Money is kept separate.")
                }
            }
            .navigationTitle("Tools")
            .navigationDestination(for: ToolRoute.self) { route in
                switch route {
                case .filter(let id):
                    if let record = model.filters.first(where: { $0.id == id }) {
                        FilterDetailView(record: record)
                    } else {
                        deletedView
                    }
                case .rollout(let id):
                    if let record = model.rollouts.first(where: { $0.id == id }) {
                        RolloutDetailView(record: record)
                    } else {
                        deletedView
                    }
                case .cost(let id):
                    if let sheet = model.costs.first(where: { $0.id == id }) {
                        CostDetailView(sheet: sheet)
                    } else {
                        deletedView
                    }
                }
            }
        }
        .sheet(isPresented: $unlockPresented) { UnlockSheet() }
    }

    private var deletedView: some View {
        ContentUnavailableView("This record was deleted", systemImage: "trash")
    }

    private func recordRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func filterSummary(_ record: FilterRecord) -> String {
        let tally = record.tally(questions: model.book.tools.filterQuestions)
        return "Yes \(tally.yes) · No \(tally.no) · Not sure \(tally.unsure)"
    }

    private func newButton(_ title: String, tool: ToolKind, create: @escaping () -> ToolRoute?) -> some View {
        Button {
            if let route = create() {
                path.append(route)
            } else {
                unlockPresented = true
            }
        } label: {
            Label(title, systemImage: model.canEdit(tool) ? "plus" : "lock")
        }
    }

    private func lockedFooter(_ tool: ToolKind, _ text: String) -> Text {
        model.canEdit(tool)
            ? Text(text)
            : Text("\(text) Included with the full book. Anything you saved earlier stays readable and can be shared.")
    }
}

/// Shown on paid tools after a refund or revocation.
struct ReadOnlyBanner: View {
    let unlock: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Read-only").font(.headline)
                Text("Editing this tool needs the full book. Your saved work is kept, and you can still share it.")
                Button("See the full book", action: unlock)
            }
        }
    }
}
