import Foundation

/// User input is distinct from untrusted scene, report and provider content.
/// Callers must assign this provenance at the input boundary, never from text itself.
public enum CommandInputSource: Sendable {
    case typedUser, pushToTalkUser, sceneText, communityText, remoteHypothesis
}

/// Interpreting a target does not establish model availability or start sensing.
public enum FindCommand: Equatable, Sendable {
    case find(GoalTarget)
    case pause, resume, repeatCandidate, nextCandidate, cancel
    case setDetail(SpeechDetail)
}

public enum CommandClarification: Equatable, Sendable {
    case chooseOneCommand, chooseTarget, usePositiveCommand, unsupportedCommand
    case communicationRequiresSeparateWorkflow
}

public enum CommandRejection: Equatable, Sendable { case untrustedSource, empty, tooLong }
public enum CommandParseResult: Equatable, Sendable {
    case proposed(FindCommand)
    case clarify(CommandClarification)
    case rejected(CommandRejection)
}

/// Closed English grammar: never extract an executable substring from a larger request.
/// No command here can send messages, choose recipients, change sensing gates or call a provider.
public enum LocalCommandParser {
    public static func parse(_ text: String, source: CommandInputSource) -> CommandParseResult {
        switch source {
        case .typedUser, .pushToTalkUser: break
        case .sceneText, .communityText, .remoteHypothesis: return .rejected(.untrustedSource)
        }
        guard text.count <= 1_000 else { return .rejected(.tooLong) }
        let normalized = text.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .rejected(.empty) }
        // Only sentence-final punctuation and a single leading politeness marker are optional.
        var phrase = normalized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while let last = phrase.last, ".!?".contains(last) { phrase.removeLast() }
        if phrase.hasPrefix("please ") { phrase.removeFirst(7) }
        let words = Set(phrase.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init))
        if !words.isDisjoint(with: ["call", "text", "send", "message", "share", "contact", "email"]) {
            return .clarify(.communicationRequiresSeparateWorkflow)
        }
        if !words.isDisjoint(with: ["not", "no", "don't", "dont", "never", "cannot", "can't", "stop", "without"])
            && phrase != "stop" && phrase != "stop search" {
            return .clarify(.usePositiveCommand)
        }
        if !words.isDisjoint(with: ["and", "then", "or", "also"])
            || normalized.contains(";") || normalized.contains("&") || normalized.contains("\n") {
            return .clarify(.chooseOneCommand)
        }
        switch phrase {
        case "pause", "pause guidance": return .proposed(.pause)
        case "resume", "resume guidance": return .proposed(.resume)
        case "repeat", "repeat candidate": return .proposed(.repeatCandidate)
        case "next", "next candidate": return .proposed(.nextCandidate)
        case "cancel", "cancel search", "stop", "stop search": return .proposed(.cancel)
        case "minimal detail": return .proposed(.setDetail(.minimal))
        case "standard detail": return .proposed(.setDetail(.standard))
        case "descriptive detail": return .proposed(.setDetail(.descriptive))
        default: break
        }
        guard phrase.hasPrefix("find ") else { return .clarify(.unsupportedCommand) }
        var target = String(phrase.dropFirst(5))
        for article in ["a ", "an ", "the "] where target.hasPrefix(article) {
            target.removeFirst(article.count)
            break
        }
        switch target {
        case "door": return .proposed(.find(.door))
        case "exit sign": return .proposed(.find(.exitSign))
        case "elevator indicator": return .proposed(.find(.elevatorIndicator))
        case "handrail": return .proposed(.find(.handrail))
        case "saved landmark": return .proposed(.find(.savedLandmark))
        case "exit", "sign", "elevator", "place", "saved place", "landmark": return .clarify(.chooseTarget)
        default: return .clarify(.unsupportedCommand)
        }
    }
}

/// Bind reviews to the same generation, goal and preferences that produced them.
public struct CommandReviewContext: Equatable, Sendable {
    public let capture: CaptureContext
    public let goalRevision: UUID?
    public let profileRevision: UInt64
    public init(capture: CaptureContext, goalRevision: UUID?, profileRevision: UInt64) {
        self.capture = capture; self.goalRevision = goalRevision; self.profileRevision = profileRevision
    }
}

public struct CommandProposal: Equatable, Sendable {
    public let id: UUID
    public let context: CommandReviewContext
    public let command: FindCommand
}

/// Pure review state, with no camera, output, persistence or communication side effects.
/// The consumer displays clarification and confirms a proposal before dispatching it.
public struct CommandReviewSession: Sendable {
    public private(set) var context: CommandReviewContext?
    public private(set) var pending: CommandProposal?
    public init() {}

    public mutating func bind(to context: CommandReviewContext) {
        guard self.context != context else { return }
        pending = nil; self.context = context
    }

    @discardableResult public mutating func submit(_ text: String, source: CommandInputSource) -> CommandParseResult {
        let result = LocalCommandParser.parse(text, source: source)
        // Non-user content cannot replace a user's review, even with a valid-looking command.
        if case .rejected(.untrustedSource) = result { return result }
        pending = nil
        if let context, case .proposed(let command) = result {
            pending = CommandProposal(id: UUID(), context: context, command: command)
        }
        return result
    }

    /// Returns once only; a changed current context also invalidates any old proposal.
    public mutating func confirm(_ id: UUID, in current: CommandReviewContext) -> FindCommand? {
        bind(to: current)
        guard let pending, pending.id == id, pending.context == current, context == current else { return nil }
        self.pending = nil
        return pending.command
    }

    public mutating func cancelReview() { pending = nil }
    public mutating func end() { pending = nil; context = nil }
}
