import Foundation

public enum GoalTarget: String, Codable, Sendable, CaseIterable { case door, exitSign, elevatorIndicator, handrail, savedLandmark }
public enum ObservationSource: String, Codable, Sendable { case currentCamera, rememberedLandmark, map, remoteHypothesis }
public enum InputQuarterTurn: String, Codable, Sendable { case up, right, down, left }
public enum ModelRuntime: String, Codable, Sendable { case appleVisionOCR, coreML }
public struct DetectorManifest: Codable, Sendable, Equatable {
    public let id: String
    public let version: String
    public let sourceURL: String
    public let license: String
    /// Apple OS-managed OCR does not expose model weight bytes; nil must not be represented as verified weights.
    public let sha256: String?
    public let runtime: ModelRuntime
    public let classMap: [String: GoalTarget]
    public let imageTransform: String
    public let trainingDomain: String
    public let heldOutEvaluation: String?
    public init(id: String, version: String, sourceURL: String, license: String, sha256: String?, runtime: ModelRuntime,
                classMap: [String: GoalTarget], imageTransform: String, trainingDomain: String, heldOutEvaluation: String?) {
        self.id = id; self.version = version; self.sourceURL = sourceURL; self.license = license; self.sha256 = sha256
        self.runtime = runtime; self.classMap = classMap; self.imageTransform = imageTransform
        self.trainingDomain = trainingDomain; self.heldOutEvaluation = heldOutEvaluation
    }
    public func validate() throws {
        guard !id.isEmpty, !version.isEmpty, URL(string: sourceURL)?.scheme == "https", !license.isEmpty,
              !imageTransform.isEmpty, !trainingDomain.isEmpty, !classMap.isEmpty,
              runtime != .coreML || (sha256?.count == 64 && sha256?.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) == true)
        else { throw ContractError.invalidValue("modelManifest") }
    }
    public static let systemOCR = DetectorManifest(id: "apple.vision.text",version: "VNRecognizeTextRequest.revision3",
        sourceURL: "https://developer.apple.com/documentation/vision/vnrecognizetextrequest",
        license: "Apple platform framework; governed by installed SDK/OS terms; weights not redistributed",
        sha256: nil,runtime: .appleVisionOCR,classMap: ["EXIT": .exitSign],
        imageTransform: "explicit quarter-turn; full image; inverse rotation to original top-left normalized bounds",
        trainingDomain: "Apple-managed; not disclosed as application training data",heldOutEvaluation: nil)
}
public struct TargetCapability: Sendable {
    public let target: GoalTarget
    public let modelIDs: [String]
    public let researchAvailable: Bool
    public let ordinaryLiveAvailable: Bool
    public let reason: String
    public init(target: GoalTarget, modelIDs: [String], researchAvailable: Bool, ordinaryLiveAvailable: Bool, reason: String) {
        self.target = target; self.modelIDs = modelIDs; self.researchAvailable = researchAvailable
        self.ordinaryLiveAvailable = ordinaryLiveAvailable; self.reason = reason
    }
}
public struct EncodedSemanticImage: Sendable {
    public let frame: FrameDescriptor
    public let data: Data
    public let quarterTurn: InputQuarterTurn
    public init(frame: FrameDescriptor, data: Data, quarterTurn: InputQuarterTurn) throws {
        try frame.validate()
        guard !data.isEmpty, data.count <= 4_194_304 else { throw ContractError.invalidValue("semanticImageBudget") }
        self.frame = frame; self.data = data; self.quarterTurn = quarterTurn
    }
}
public struct SemanticObservation: Codable, Sendable {
    public let id: UUID
    public let envelope: ObservationEnvelope
    public let modelID: String
    public let modelVersion: String
    public let target: GoalTarget?
    public let text: String?
    public let labelScore: Double
    public let imageBounds: NormalizedBounds
    public let source: ObservationSource
    public let visualContextConfirmed: Bool
    public init(id: UUID = UUID(), envelope: ObservationEnvelope, modelID: String, modelVersion: String,
                target: GoalTarget?, text: String? = nil, labelScore: Double, imageBounds: NormalizedBounds,
                source: ObservationSource = .currentCamera, visualContextConfirmed: Bool = false) {
        self.id = id; self.envelope = envelope; self.modelID = modelID; self.modelVersion = modelVersion
        self.target = target; self.text = text; self.labelScore = labelScore; self.imageBounds = imageBounds
        self.source = source; self.visualContextConfirmed = visualContextConfirmed
    }
}
public struct SemanticBatch: Codable, Sendable {
    public let schemaVersion: Int
    public let frame: FrameDescriptor
    public let observations: [SemanticObservation]
    public let inferenceDuration: Double
    public let modelID: String
    public let modelVersion: String
    public init(frame: FrameDescriptor, observations: [SemanticObservation], inferenceDuration: Double, modelID: String, modelVersion: String) {
        schemaVersion = 1; self.frame = frame; self.observations = observations; self.inferenceDuration = inferenceDuration
        self.modelID = modelID; self.modelVersion = modelVersion
    }
}
public struct DepthAssociation: Codable, Sendable {
    public let observationID: UUID
    public let frameID: FrameID
    public let rangeMeters: Double?
    public let axialDepthMeters: Double?
    public let bearingRadians: Double?
    public let associationSupport: Double?
    public let uncertaintyMeters: Double?
    public let reasons: [String]
    public init(observationID: UUID, frameID: FrameID, rangeMeters: Double?, axialDepthMeters: Double?, bearingRadians: Double?,
                associationSupport: Double?, uncertaintyMeters: Double?, reasons: [String]) {
        self.observationID = observationID; self.frameID = frameID; self.rangeMeters = rangeMeters
        self.axialDepthMeters = axialDepthMeters; self.bearingRadians = bearingRadians
        self.associationSupport = associationSupport; self.uncertaintyMeters = uncertaintyMeters; self.reasons = reasons
    }
}

/// A handrail detector box alone is insufficient; producer must also supply current 3D/temporal structure.
public struct HandrailStructureEvidence: Sendable {
    public let observationID: UUID
    public let envelope: ObservationEnvelope
    public let lengthMeters: Double
    public let maximumResidualMeters: Double
    public let supportedFrames: Int
    public let duration: Double
    public init(observationID: UUID, envelope: ObservationEnvelope, lengthMeters: Double,
                maximumResidualMeters: Double, supportedFrames: Int, duration: Double) {
        self.observationID = observationID; self.envelope = envelope; self.lengthMeters = lengthMeters
        self.maximumResidualMeters = maximumResidualMeters; self.supportedFrames = supportedFrames; self.duration = duration
    }
    public func supports(_ observation: SemanticObservation, context: CaptureContext, at now: Double) -> Bool {
        observationID == observation.id && envelope == observation.envelope && envelope.isCurrent(in: context,at: now)
        && lengthMeters.isFinite && lengthMeters >= 0.5 && maximumResidualMeters.isFinite
        && (0...0.04).contains(maximumResidualMeters) && supportedFrames >= 3 && duration.isFinite && duration >= 0.5
    }
}
