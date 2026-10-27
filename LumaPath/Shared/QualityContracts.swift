import Foundation

/// Versioned engineering hypotheses. Coverage is not a probability of safety.
public struct QualityConfiguration: Sendable, Equatable {
    public static let current = QualityConfiguration()
    public let configurationVersion = 2
    public let highCoverage = 0.70
    public let limitedCoverage = 0.30
    public let darkLuma: UInt8 = 24
    public let clippedLuma: UInt8 = 245
    public let affectedImageFraction = 0.50
    public let minimumContrast = 0.05
    public let limitationEventLifetime: TimeInterval = 1.0
    public let recoveryFrames = 2
    public let temporalRangeChange = 0.50
    public let maximumImageSamples = 16_384
    public init() {}
}

/// Display bands describe image position, not measured floor or overhead geometry.
public enum ImageBand: String, Codable, Sendable, CaseIterable { case upper, middle, lower }
public enum CoverageCategory: String, Codable, Sendable { case unknown, sparse, limited, high }
public struct ImageConditionMetrics: Codable, Sendable, Equatable {
    public let sampleCount: Int
    public let darkFraction: Double
    public let clippedFraction: Double
    /// Mean absolute horizontal-neighbor difference, normalized to 0...1.
    public let localContrast: Double?
    public init(sampleCount: Int, darkFraction: Double, clippedFraction: Double, localContrast: Double?) {
        self.sampleCount = sampleCount; self.darkFraction = darkFraction
        self.clippedFraction = clippedFraction; self.localContrast = localContrast
    }
}
public struct RegionalQuality: Codable, Sendable, Equatable {
    public let region: ViewRegion
    public let band: ImageBand
    public let sampledDepthPixels: Int
    public let usableDepthPixels: Int
    public let confidenceKnown: Bool
    public let mediumConfidencePixels: Int?
    public let highConfidencePixels: Int?
    public let lowConfidencePixels: Int?
    public let invalidConfidencePixels: Int?
    public let coverage: CoverageCategory
    public let image: ImageConditionMetrics?
    /// Change in same display cell's nearest depth; not an object association or motion estimate.
    public let temporalRangeChanged: Bool?
    public init(region: ViewRegion, band: ImageBand, sampledDepthPixels: Int, usableDepthPixels: Int,
                confidenceKnown: Bool, lowConfidencePixels: Int?, mediumConfidencePixels: Int?, highConfidencePixels: Int?, invalidConfidencePixels: Int?,
                coverage: CoverageCategory, image: ImageConditionMetrics?, temporalRangeChanged: Bool?) {
        self.region = region; self.band = band; self.sampledDepthPixels = sampledDepthPixels
        self.usableDepthPixels = usableDepthPixels; self.confidenceKnown = confidenceKnown
        self.mediumConfidencePixels = mediumConfidencePixels; self.highConfidencePixels = highConfidencePixels
        self.lowConfidencePixels = lowConfidencePixels; self.invalidConfidencePixels = invalidConfidencePixels
        self.coverage = coverage; self.image = image; self.temporalRangeChanged = temporalRangeChanged
    }
    public var usableDepthFraction: Double? {
        sampledDepthPixels > 0 ? Double(usableDepthPixels)/Double(sampledDepthPixels) : nil
    }
}
public struct QualityDetails: Codable, Sendable, Equatable {
    public let configurationVersion: Int
    public let frameID: FrameID
    public let sampleAge: TimeInterval
    public let tracking: TrackingQuality
    public let regions: [RegionalQuality]
    public let worldDependentFunctionsSupported: Bool
    public let reasons: [String]
    public init(configurationVersion: Int, frameID: FrameID, sampleAge: TimeInterval, tracking: TrackingQuality,
                regions: [RegionalQuality], worldDependentFunctionsSupported: Bool, reasons: [String]) {
        self.configurationVersion = configurationVersion; self.frameID = frameID; self.sampleAge = sampleAge
        self.tracking = tracking; self.regions = regions
        self.worldDependentFunctionsSupported = worldDependentFunctionsSupported; self.reasons = reasons
    }
}

/// Owned, bounded subsampling of original image luma; never persisted automatically.
public struct LumaImage: Sendable {
    public let frame: FrameDescriptor
    public let size: PixelSize
    public let values: [UInt8]
    public init(frame: FrameDescriptor, size: PixelSize, values: [UInt8]) throws {
        try frame.validate()
        let (count, overflow) = size.width.multipliedReportingOverflow(by: size.height)
        guard size.isValid, !overflow, count <= QualityConfiguration.current.maximumImageSamples,
              values.count == count else { throw ContractError.invalidValue("lumaShapeOrBudget") }
        self.frame = frame; self.size = size; self.values = values
    }
}

/// Opt-in future dataset row, not an active recorder. No image bytes, personal identity, or geographic location.
/// A12 must add consent, ground truth, dataset card and environment/session-disjoint splits.
public struct FusionEvaluationRecord: Codable, Sendable {
    public let schemaVersion: Int
    public let captureSessionID: UUID
    public let environmentSplitID: String
    public let quality: QualityDetails
    public let geometry: [GeometryObservation]
    public let modelVersion: String?
    public let labelScores: [String: Double]?
    public let associationScores: [String: Double]?
    public let disagreements: [String]
    public let groundTruth: String?
    public init(captureSessionID: UUID, environmentSplitID: String, quality: QualityDetails,
                geometry: [GeometryObservation], modelVersion: String? = nil,
                labelScores: [String: Double]? = nil, associationScores: [String: Double]? = nil,
                disagreements: [String], groundTruth: String?) {
        schemaVersion = 1; self.captureSessionID = captureSessionID; self.environmentSplitID = environmentSplitID
        self.quality = quality; self.geometry = geometry; self.modelVersion = modelVersion
        self.labelScores = labelScores; self.associationScores = associationScores
        self.disagreements = disagreements; self.groundTruth = groundTruth
    }
}

/// Closed sensing vocabulary. These messages never claim free space or traversability.
public enum SensingLimitation: String, Codable, Sendable, CaseIterable {
    case cameraOnlyNoDepth, depthUnavailable, partialDepthCoverage, confidenceUnknown
    case darkImage, clippedImage, lowImageContrast, imageConditionsUnknown
    case trackingDegraded, worldReferenceUnavailable, awaitingQualityRecovery
    case inputUnavailable, qualityRecovered
    public var message: String {
        switch self {
        case .cameraOnlyNoDepth: "Camera only. Depth and nearby obstacles are unknown."
        case .depthUnavailable: "Depth is unavailable. Nearby obstacles are unknown."
        case .partialDepthCoverage: "Depth coverage is limited. Unobserved areas remain unknown."
        case .confidenceUnknown: "Depth confidence is unknown."
        case .darkImage: "The camera image is dark."
        case .clippedImage: "Parts of the camera image are too bright."
        case .lowImageContrast: "Image contrast is limited."
        case .imageConditionsUnknown: "Image conditions are unknown."
        case .trackingDegraded, .worldReferenceUnavailable: "World position is uncertain."
        case .awaitingQualityRecovery: "Sensing is recovering."
        case .inputUnavailable: "Sensing is unavailable. Nearby obstacles are unknown."
        case .qualityRecovered: "Sensing conditions recovered. Unobserved areas remain unknown."
        }
    }
    public static func reasons(for quality: QualityAssessment) -> [Self] {
        var reasons = Set(quality.reasons.compactMap(Self.init(rawValue:)))
        // Expected camera-only limits already explain the absence of depth; avoid redundant cues.
        if reasons.contains(.cameraOnlyNoDepth) {
            reasons.subtract([.partialDepthCoverage, .confidenceUnknown])
        }
        if reasons.contains(.depthUnavailable) { reasons.subtract([.partialDepthCoverage, .confidenceUnknown]) }
        if reasons.count > 1 { reasons.remove(.awaitingQualityRecovery) }
        if quality.state == .unavailable && reasons.isEmpty { reasons.insert(.inputUnavailable) }
        return Self.allCases.filter { reasons.contains($0) }
    }
}

/// Acknowledged quality transition, independent of coalesced presentation and obstacle geometry.
/// Outages have no source frame; frame-backed events never outlive their original evidence.
public struct QualityLimitationEvent: Sendable, Equatable {
    public let id: UUID
    public let context: CaptureContext
    public let source: ObservationEnvelope?
    public let reasons: [SensingLimitation]
    public let createdAt: TimeInterval
    public let expiresAt: TimeInterval
    public init(id: UUID = UUID(), context: CaptureContext, source: ObservationEnvelope?, reasons: [SensingLimitation], at now: TimeInterval) {
        self.id = id; self.context = context; self.source = source; self.reasons = reasons; createdAt = now
        expiresAt = min(now + QualityConfiguration.current.limitationEventLifetime, source?.expiresAtMonotonic ?? .infinity)
    }
    public func isCurrent(in context: CaptureContext, at now: TimeInterval) -> Bool {
        self.context == context && now.isFinite && createdAt.isFinite && expiresAt.isFinite
        && now >= createdAt && now < expiresAt && expiresAt > createdAt
        && expiresAt-createdAt <= QualityConfiguration.current.limitationEventLifetime
        && !reasons.isEmpty && Set(reasons).count == reasons.count
        && (source != nil || reasons == [.inputUnavailable])
        && (source.map { $0.isCurrent(in: context, at: now) && expiresAt <= $0.expiresAtMonotonic } ?? true)
    }
}
