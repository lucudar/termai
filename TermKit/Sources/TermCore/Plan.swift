import Foundation

/// One step of the agent's plan for a long task.
public struct PlanStep: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var step: String
    public var status: Status

    public init(_ step: String, _ status: Status = .pending) {
        self.step = step
        self.status = status
    }
}

/// The update_plan tool. For multi-step work the model keeps a short checklist, which the app shows as
/// the plan of the run. It changes nothing outside the conversation, so it never asks for approval, and
/// the agent answers it itself whatever tool box it runs with.
public enum Plan {
    public static let toolName = "update_plan"

    public static let spec = ToolSpec(
        name: toolName,
        description: "Keep a short plan for work that takes several steps: a feature, a refactor, a bug hunt across files. Send the whole list each time, 3 to 7 short steps, with exactly one in_progress while you work on it and completed as soon as it is done. Call it again whenever a step finishes or the plan changes. Skip it for quick questions and single edits.",
        parametersJSON: #"{"type":"object","properties":{"explanation":{"type":"string","description":"Optional: why the plan changed"},"plan":{"type":"array","items":{"type":"object","properties":{"step":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["step","status"]}}},"required":["plan"]}"#)

    /// The steps of an update_plan call, or nil when its arguments hold none.
    public static func steps(fromArguments arguments: String) -> [PlanStep]? {
        guard let data = arguments.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = (object["plan"] ?? object["steps"] ?? object["todos"]) as? [Any]
        else { return nil }
        let parsed = list.compactMap { entry -> PlanStep? in
            if let text = entry as? String { return makeStep(text, rawStatus: nil) }
            guard let fields = entry as? [String: Any] else { return nil }
            let text = (fields["step"] ?? fields["content"] ?? fields["title"] ?? fields["text"]) as? String
            return text.flatMap { makeStep($0, rawStatus: fields["status"] as? String) }
        }
        return parsed.isEmpty ? nil : parsed
    }

    static func makeStep(_ text: String, rawStatus: String?) -> PlanStep? {
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : PlanStep(line, parseStatus(rawStatus))
    }

    /// Lenient about how models spell a status: `in-progress`, `doing`, `done` and so on.
    static func parseStatus(_ raw: String?) -> PlanStep.Status {
        let key = (raw ?? "").lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch key {
        case "in_progress", "inprogress", "active", "doing", "started", "current", "working": return .inProgress
        case "completed", "complete", "done", "finished": return .completed
        default: return .pending
        }
    }

    static func mark(_ status: PlanStep.Status) -> String {
        switch status {
        case .completed: return "[x]"
        case .inProgress: return "[>]"
        case .pending: return "[ ]"
        }
    }

    /// One line per step, `[x] done`, `[>] doing`, `[ ] to do`: what the model gets back, what the
    /// transcript keeps, and what `parse` reads.
    public static func render(_ steps: [PlanStep]) -> String {
        steps.map { mark($0.status) + " " + $0.step }.joined(separator: "\n")
    }

    /// The steps back from `render`'s text.
    public static func parse(_ text: String) -> [PlanStep] {
        text.split(separator: "\n").compactMap { piece -> PlanStep? in
            let line = String(piece)
            for status in [PlanStep.Status.completed, .inProgress, .pending] where line.hasPrefix(mark(status) + " ") {
                return PlanStep(String(line.dropFirst(4)), status)
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : PlanStep(text)
        }
    }

    /// `plan 2/5`
    public static func summary(_ steps: [PlanStep]) -> String {
        "plan \(steps.filter { $0.status == .completed }.count)/\(steps.count)"
    }

    /// Runs an update_plan call: the plan as checklist text, or an error that says what was wrong.
    public static func run(_ call: ToolCall) -> ToolResult {
        guard let parsed = steps(fromArguments: call.arguments) else {
            return ToolResult(
                text: "update_plan needs plan: a list of {step, status} with status pending, in_progress or completed",
                isError: true)
        }
        return ToolResult(text: render(parsed))
    }
}
