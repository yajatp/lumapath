import Foundation
import LumaPathDomain

/// A short, explicit research capture. Not navigation evidence or a validated training set.
public struct ResearchRecording: Codable, Sendable {
    public struct Sample: Codable, Sendable {
        public let frame: FrameDescriptor
        public let jpeg: Data
        public let quarterTurn: InputQuarterTurn
        public let acquiredAtMonotonic: Double?
        /// Row-major Float32, little endian, axial meters. Nonfinite values remain invalid samples.
        public let depthFloat32LE: Data?
        public let confidenceUInt8: Data?
        public let quality: QualityAssessment?
    }
    public let schemaVersion: Int
    public let id: UUID
    public let context: CaptureContext
    public let environment: String
    public let targetLabel: String
    /// Independently measured optical range, not a sensor prediction. Nil means unlabelled.
    public let measuredRangeMeters: Double?
    public let poseSource: String
    public private(set) var samples: [Sample] = []
    public private(set) var payloadBytes = 0
    public static let maximumSamples = 12
    public static let maximumPayloadBytes = 24 * 1024 * 1024

    public init(context: CaptureContext, consent: Bool, environment: String, targetLabel: String,
                measuredRangeMeters: Double? = nil) throws {
        let environment = environment.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = targetLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard consent, !environment.isEmpty, environment.count <= 80, !label.isEmpty, label.count <= 80,
              measuredRangeMeters == nil || (measuredRangeMeters!.isFinite && (0.3...4).contains(measuredRangeMeters!))
        else { throw ContractError.invalidValue("recordingConsentOrLabels") }
        schemaVersion = 1; poseSource = "ARKit cameraToWorld when available; no independent raw IMU or audio"
        id = UUID(); self.context = context; self.environment = environment; self.targetLabel = label
        self.measuredRangeMeters = measuredRangeMeters
    }
    public var isFull: Bool { samples.count >= Self.maximumSamples || payloadBytes >= Self.maximumPayloadBytes }
    public func wantsSample(at time: Double) -> Bool {
        !isFull && time.isFinite && (samples.last.map { time - $0.frame.envelope.captureTimeMonotonic >= 1 } ?? true)
    }
    @discardableResult public mutating func append(image: EncodedSemanticImage, depth: DepthImage?,
                                                  quality: QualityAssessment?, at now: Double) throws -> Bool {
        guard image.frame.envelope.isCurrent(in: context, at: now),
              depth == nil || depth?.frame == image.frame,
              quality?.details == nil || quality?.details?.frameID == image.frame.envelope.frameID,
              samples.last.map({ image.frame.envelope.frameID.sequence > $0.frame.envelope.frameID.sequence }) ?? true
        else { throw ContractError.invalidValue("recordingFrameMismatchOrExpired") }
        guard wantsSample(at: image.frame.envelope.captureTimeMonotonic) else { return false }
        var packed: Data?
        if let depth {
            var bytes = Data(capacity: depth.values.count * 4)
            for value in depth.values {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
            packed = bytes
        }
        let confidence = depth?.confidence.map { Data($0) }
        let size = image.data.count + (packed?.count ?? 0) + (confidence?.count ?? 0)
        guard size <= 6 * 1024 * 1024, payloadBytes + size <= Self.maximumPayloadBytes else { return false }
        samples.append(Sample(frame: image.frame, jpeg: image.data, quarterTurn: image.quarterTurn,
                              acquiredAtMonotonic: now,
                              depthFloat32LE: packed, confidenceUInt8: confidence, quality: quality))
        payloadBytes += size
        return true
    }
    /// Attach only the assessment for this archived source frame; never a newer frame's quality.
    public mutating func attachQuality(_ quality: QualityAssessment, to frameID: FrameID) throws {
        guard quality.details == nil || quality.details?.frameID == frameID else {
            throw ContractError.invalidValue("recordingQualityFrameMismatch")
        }
        guard let index = samples.firstIndex(where: { $0.frame.envelope.frameID == frameID }) else { return }
        let old = samples[index]
        samples[index] = Sample(frame: old.frame, jpeg: old.jpeg, quarterTurn: old.quarterTurn,
            acquiredAtMonotonic: old.acquiredAtMonotonic, depthFloat32LE: old.depthFloat32LE,
            confidenceUInt8: old.confidenceUInt8, quality: quality)
    }
    public func exportData() throws -> Data {
        guard !samples.isEmpty else { throw ContractError.invalidValue("emptyRecording") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 36 * 1024 * 1024 else { throw ContractError.invalidValue("recordingExportBudget") }
        return data
    }
}
