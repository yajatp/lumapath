import Foundation

public enum LiveVoiceAction: Equatable, Sendable {
    case pause, resume, end, help, describe, distance(String)
    public var reviewText: String {
        switch self {
        case .pause: "Pause the camera"
        case .resume: "Resume the camera with fresh images"
        case .end: "End live view"
        case .help: "Pause and open Help"
        case .describe: "Start or resume the camera and describe a current Research object"
        case .distance(let label): "Start or resume the camera and check the current distance to \(label)"
        }
    }
}
/// Reviewed, bounded English assistant commands. Scene/model text never enters this parser.
public enum LiveVoiceCommandParser {
    public static func parse(_ input: String) -> LiveVoiceAction? {
        guard input.count <= 160 else { return nil }
        let normalized = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        switch normalized {
        case "pause", "pause camera", "pause live view": return .pause
        case "resume", "resume camera", "start camera", "resume live view": return .resume
        case "stop", "end", "end live view", "stop camera": return .end
        case "help", "open help": return .help
        case "describe", "describe scene", "what is ahead", "what's ahead", "what is in front of me", "what objects do you see": return .describe
        default: break
        }
        for prefix in ["how far is the ", "how far is ", "distance to the ", "distance to "] where normalized.hasPrefix(prefix) {
            let label = String(normalized.dropFirst(prefix.count))
            let words = Set(label.split(separator: " ").map(String.init))
            guard !label.isEmpty, label.count <= 40,
                  label.unicodeScalars.allSatisfy({ (97...122).contains($0.value) || $0.value == 32 }),
                  words.isDisjoint(with: ["and", "then", "or", "please", "call", "send", "walk", "turn", "ignore"]) else { return nil }
            return .distance(label)
        }
        return nil
    }
}
