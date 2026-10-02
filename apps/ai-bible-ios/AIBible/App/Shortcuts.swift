import AppIntents
import Observation

/// Hands a Siri / Shortcuts request to the running app. The intent only sets a flag; the
/// Decisions tab reacts by starting a new evaluation, exactly as its own button does.
@MainActor
@Observable
final class IntentRouter {
    static let shared = IntentRouter()
    var pendingNewEvaluation = false
}

struct StartEvaluationIntent: AppIntent {
    static let title: LocalizedStringResource = "Evaluate an AI tool"
    static let description = IntentDescription("Start deciding about a new AI tool in AI Bible.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pendingNewEvaluation = true
        return .result()
    }
}

struct AIBibleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartEvaluationIntent(),
            phrases: ["Evaluate an AI tool in \(.applicationName)",
                      "Start an AI tool decision in \(.applicationName)"],
            shortTitle: "Evaluate a tool",
            systemImageName: "checkmark.seal")
    }
}
