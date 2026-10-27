import Foundation
import LumaPathDomain
import LumaPathGoals

public enum FindPresentation {
    public static func name(_ target: GoalTarget) -> String {
        switch target {
        case .door: "door"; case .exitSign: "exit sign"; case .elevatorIndicator: "elevator indicator"
        case .handrail: "handrail"; case .savedLandmark: "saved landmark"
        }
    }
    public static func interpretation(_ command: FindCommand) -> String {
        switch command {
        case .find(let target): "Find \(name(target))"
        case .pause: "Pause search"; case .resume: "Resume search"
        case .repeatCandidate: "Repeat current candidate"; case .nextCandidate: "Next candidate"
        case .cancel: "Cancel search"; case .setDetail(let detail): "Use \(detail.rawValue) descriptions for this search"
        }
    }
    public static func clarification(_ result: CommandParseResult) -> String {
        switch result {
        case .proposed(let command): interpretation(command)
        case .clarify(.chooseOneCommand): "Choose one command at a time. Nothing was changed."
        case .clarify(.chooseTarget): "Choose a precise target: door, exit sign, elevator indicator, handrail, or saved landmark."
        case .clarify(.usePositiveCommand): "That includes a negation. Use a direct command such as Cancel search. Nothing was changed."
        case .clarify(.communicationRequiresSeparateWorkflow): "Find cannot call, message, share, or publish. Use a separate explicit communication workflow. Nothing was sent."
        case .clarify(.unsupportedCommand): "Command not recognized. Use a target button or a listed English command."
        case .rejected(.untrustedSource): "Scene and report text cannot issue commands."
        case .rejected(.empty): "Enter a command."
        case .rejected(.tooLong): "Keep the command under 1,000 characters."
        }
    }
    public static func unavailable(_ target: GoalTarget, research: Bool) -> String {
        if target == .savedLandmark { return "Saved landmarks need a selected spatial place and current alignment. Manual saved notes are available; they are not camera detections. Spatial Find is not connected yet." }
        if target != .exitSign { return "Finding a \(name(target)) is unavailable: a licensed, evaluated target detector is not installed. No search is running." }
        return research ? "Camera access and current images are required for the Research trial." : "Exit-sign finding is Research only while target accuracy and physical validation remain pending. No search is running."
    }
    public static func candidate(_ candidate: ResolvedGoalCandidate, detail: SpeechDetail) -> String {
        let range = candidate.association?.rangeMeters.map { String(format: "Measured distance about %.1f meters.", $0) } ?? "Distance unknown."
        let position = candidate.imagePosition == .outsideView ? "outside the displayed view" : "\(candidate.imagePosition.rawValue) of the displayed image"
        let basic = "Possible \(name(candidate.observation.target ?? .exitSign)). Current camera, \(position). \(range) Research estimate."
        if detail == .minimal {
            return "Research candidate: \(name(candidate.observation.target ?? .exitSign)). Current camera, \(position). \(range)"
        }
        return detail == .descriptive ? basic + " This does not establish an open door, an accessible exit, or a safe route." : basic
    }
    public static func quarterTurn(_ orientation: ImageOrientation) -> InputQuarterTurn {
        switch orientation { case .portrait: .right; case .portraitUpsideDown: .left; case .landscapeLeft: .down; case .landscapeRight: .up }
    }
}

/// Permission/capability decisions remain testable without invoking a microphone prompt.
public enum LocalSpeechAvailability {
    public static func reason(speechAuthorized: Bool, microphoneAuthorized: Bool, onDevice: Bool, available: Bool) -> String? {
        if !speechAuthorized { return "Speech permission was denied or restricted. Type a command instead." }
        if !microphoneAuthorized { return "Microphone permission was denied. Type a command instead." }
        if !onDevice { return "On-device English speech is unavailable. Type a command instead; audio is not sent to a server." }
        if !available { return "Speech recognition is temporarily unavailable. Type a command instead." }
        return nil
    }
}
