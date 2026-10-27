import Foundation
import Vision
import CoreML
import ImageIO
import CryptoKit
import LumaPathDomain

public enum SemanticImageTransform {
    /// Vision reports lower-left bounds in the request-oriented image. Return original-image top-left bounds.
    public static func originalBounds(_ bounds: NormalizedBounds, quarterTurn: InputQuarterTurn) -> NormalizedBounds? {
        let corners = [(bounds.minX,1-bounds.minY),(bounds.minX,1-bounds.maxY),
                       (bounds.maxX,1-bounds.minY),(bounds.maxX,1-bounds.maxY)]
        let points = corners.map { x,y -> SIMD2<Double> in
            switch quarterTurn {
            case .up: SIMD2(x,y)
            case .right: SIMD2(y,1-x)
            case .down: SIMD2(1-x,1-y)
            case .left: SIMD2(1-y,x)
            }
        }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return NormalizedBounds(minX: points.map(\.x).min()!,minY: points.map(\.y).min()!,
            maxX: points.map(\.x).max()!,maxY: points.map(\.y).max()!).clipped
    }
}
private func orientation(_ turn: InputQuarterTurn) -> CGImagePropertyOrientation {
    switch turn { case .up: .up; case .right: .right; case .down: .down; case .left: .left }
}
private func bounds(_ rect: CGRect) -> NormalizedBounds {
    NormalizedBounds(minX: rect.minX,minY: rect.minY,maxX: rect.maxX,maxY: rect.maxY)
}
private func validate(_ image: EncodedSemanticImage, context: CaptureContext, at time: Double) throws {
    guard image.frame.envelope.isCurrent(in: context,at: time),
          let source = CGImageSourceCreateWithData(image.data as CFData,nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, width <= 2048, height <= 2048, width*height <= 2_097_152,
          (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
          abs(Double(width)/Double(height)-Double(image.frame.imageSize.width)/Double(image.frame.imageSize.height)) < 0.01 else {
        throw ContractError.invalidValue("semanticRasterOrFreshness")
    }
}

/// Real local OCR and rectangle evidence. EXIT remains a candidate, never route access or clearance.
public actor VisionOCRAdapter {
    private let clock: any MonotonicClock
    public init(clock: any MonotonicClock = SystemMonotonicClock()) { self.clock = clock }
    public func recognize(_ image: EncodedSemanticImage, context: CaptureContext) throws -> SemanticBatch {
        try Task.checkCancellation(); try validate(image,context: context,at: clock.now())
        let started = ProcessInfo.processInfo.systemUptime
        let text = VNRecognizeTextRequest(); text.revision = VNRecognizeTextRequestRevision3
        text.recognitionLevel = .accurate; text.recognitionLanguages = ["en-US"]; text.usesLanguageCorrection = false
        let rectangles = VNDetectRectanglesRequest(); rectangles.maximumObservations = 32
        rectangles.minimumConfidence = 0.6; rectangles.minimumSize = 0.02
        rectangles.minimumAspectRatio = 0.15; rectangles.maximumAspectRatio = 1
        let handler = VNImageRequestHandler(data: image.data,orientation: orientation(image.quarterTurn),options: [:])
        try handler.perform([text,rectangles])
        try Task.checkCancellation()
        guard image.frame.envelope.isCurrent(in: context,at: clock.now()) else { throw ContractError.invalidValue("semanticInferenceExpired") }
        let manifest = DetectorManifest.systemOCR
        let observations = (text.results ?? []).prefix(64).compactMap { observation -> SemanticObservation? in
            guard let result = observation.topCandidates(1).first, result.confidence >= 0.5,
                  let original = SemanticImageTransform.originalBounds(bounds(observation.boundingBox),quarterTurn: image.quarterTurn) else { return nil }
            let value = String(result.string.prefix(256)), normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let box = observation.boundingBox
            let rectangularContext = (rectangles.results ?? []).contains { rectangle in
                let r = rectangle.boundingBox
                let areaRatio = r.width*r.height/max(1e-8,box.width*box.height)
                return r.width*r.height <= 0.4 && r.width/max(r.height,1e-8) >= 1.2
                    && r.insetBy(dx: -0.005,dy: -0.005).contains(box) && areaRatio >= 1.1 && areaRatio <= 20
            }
            let exitCandidate = normalized == "EXIT" && result.confidence >= 0.7 && rectangularContext
            return SemanticObservation(envelope: image.frame.envelope,modelID: manifest.id,modelVersion: manifest.version,
                target: exitCandidate ? .exitSign : nil,text: value,labelScore: Double(result.confidence),
                imageBounds: original,visualContextConfirmed: rectangularContext)
        }
        return SemanticBatch(frame: image.frame,observations: observations,inferenceDuration: ProcessInfo.processInfo.systemUptime-started,
            modelID: manifest.id,modelVersion: manifest.version)
    }
}

/// Loads only a checksum-matched model. Unknown outputs/classes remain unavailable instead of becoming invented boxes.
public actor CoreMLDetector {
    private let model: VNCoreMLModel
    private let manifest: DetectorManifest
    private let clock: any MonotonicClock
    public init(manifest: DetectorManifest, assetURL: URL, clock: any MonotonicClock = SystemMonotonicClock()) throws {
        try manifest.validate()
        guard manifest.runtime == .coreML, assetURL.isFileURL, assetURL.pathExtension == "mlmodel",
              manifest.imageTransform == "scaleFill.fullImage.explicitQuarterTurn" else { throw ContractError.invalidValue("unsupportedModelTransformOrAsset") }
        let metadata = try assetURL.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey])
        guard metadata.isRegularFile == true, let size = metadata.fileSize, size > 0, size <= 268_435_456 else { throw ContractError.invalidValue("modelAssetBudget") }
        let bytes = try Data(contentsOf: assetURL,options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined()
        guard digest == manifest.sha256 else { throw ContractError.invalidValue("modelChecksumMismatch") }
        let compiled = try MLModel.compileModel(at: assetURL)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let loaded = try MLModel(contentsOf: compiled)
        let outputs = loaded.modelDescription.outputDescriptionsByName
        guard outputs["coordinates"]?.type == .multiArray, outputs["confidence"]?.type == .multiArray,
              loaded.modelDescription.predictedProbabilitiesName == nil else {
            throw ContractError.invalidValue("modelMustExposeObjectDetectionCoordinatesAndConfidence")
        }
        model = try VNCoreMLModel(for: loaded)
        self.manifest = manifest; self.clock = clock
    }
    public func detect(_ image: EncodedSemanticImage, context: CaptureContext) throws -> SemanticBatch {
        try Task.checkCancellation(); try validate(image,context: context,at: clock.now())
        let started = ProcessInfo.processInfo.systemUptime
        let request = VNCoreMLRequest(model: model); request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(data: image.data,orientation: orientation(image.quarterTurn),options: [:]).perform([request])
        try Task.checkCancellation()
        guard image.frame.envelope.isCurrent(in: context,at: clock.now()) else { throw ContractError.invalidValue("semanticInferenceExpired") }
        guard let results = request.results as? [VNRecognizedObjectObservation] else { throw ContractError.invalidValue("modelDoesNotReturnObjectBoxes") }
        let observations = results.prefix(64).compactMap { object -> SemanticObservation? in
            guard let label = object.labels.first, label.confidence >= 0.6, let target = manifest.classMap[label.identifier],
                  let original = SemanticImageTransform.originalBounds(bounds(object.boundingBox),quarterTurn: image.quarterTurn) else { return nil }
            return SemanticObservation(envelope: image.frame.envelope,modelID: manifest.id,modelVersion: manifest.version,
                target: target,labelScore: Double(label.confidence),imageBounds: original,visualContextConfirmed: true)
        }
        return SemanticBatch(frame: image.frame,observations: observations,inferenceDuration: ProcessInfo.processInfo.systemUptime-started,
            modelID: manifest.id,modelVersion: manifest.version)
    }
}

public enum SceneDetectorPreset: String, CaseIterable, Sendable {
    case full, tiny
    public var title: String { self == .full ? "Full YOLOv3 (80 classes)" : "YOLOv3 Tiny (80 classes)" }
    public var assetName: String { self == .full ? "YOLOv3Int8LUT" : "YOLOv3TinyFP16" }
    public var byteCount: Int { self == .full ? 62_200_325 : 17_769_580 }
    public var sha256: String {
        self == .full ? "0e32f297ad9cfc0ea8e67276867956488c7ee10dc87c057da4debc939e20b76d"
            : "73406178d0f5793d0d5d1e38274acd146a744c2245c9b63a11998a5015925dda"
    }
    public var modelID: String { self == .full ? "darknet.yolov3.apple-int8lut" : "darknet.yolov3-tiny.apple-fp16" }
}

/// Bundled COCO detector for optional scene descriptions, separate from the Find target registry.
/// A class score is not a depth measurement, calibrated probability, or hazard assessment.
public actor SceneObjectDetector {
    public static let modelID = SceneDetectorPreset.full.modelID
    public static let version = "apple-catalog-2.0"
    public static let sha256 = SceneDetectorPreset.full.sha256
    private var model: VNCoreMLModel?
    private let clock: any MonotonicClock
    private let preset: SceneDetectorPreset
    public init(preset: SceneDetectorPreset = .full, clock: any MonotonicClock = SystemMonotonicClock()) {
        self.preset = preset; self.clock = clock
    }
    public func prepare() throws {
        guard model == nil else { return }
        guard let asset = Bundle.module.url(forResource: preset.assetName, withExtension: "mlmodel", subdirectory: "Assets") else {
            throw ContractError.invalidValue("bundledSceneModelMissing")
        }
        let bytes = try Data(contentsOf: asset, options: .mappedIfSafe)
        guard bytes.count == preset.byteCount,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == preset.sha256 else {
            throw ContractError.invalidValue("bundledSceneModelChecksum")
        }
        let compiled = try MLModel.compileModel(at: asset)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let configuration = MLModelConfiguration(); configuration.computeUnits = .all
        let loaded = try MLModel(contentsOf: compiled, configuration: configuration)
        let outputs = loaded.modelDescription.outputDescriptionsByName
        guard outputs["coordinates"]?.type == .multiArray, outputs["confidence"]?.type == .multiArray else {
            throw ContractError.invalidValue("sceneModelMustReturnBoxes")
        }
        model = try VNCoreMLModel(for: loaded)
    }
    public func detect(_ image: EncodedSemanticImage, context: CaptureContext) throws -> SemanticBatch {
        try Task.checkCancellation()
        guard let model else { throw ContractError.invalidValue("sceneModelNotPrepared") }
        try validate(image, context: context, at: clock.now())
        let started = clock.now()
        let request = VNCoreMLRequest(model: model); request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(data: image.data, orientation: orientation(image.quarterTurn), options: [:]).perform([request])
        try Task.checkCancellation()
        guard image.frame.envelope.isCurrent(in: context, at: clock.now()),
              let results = request.results as? [VNRecognizedObjectObservation] else {
            throw ContractError.invalidValue("sceneResultExpiredOrInvalid")
        }
        let observations = results.prefix(32).compactMap { object -> SemanticObservation? in
            guard let label = object.labels.first, label.confidence >= 0.6,
                  let name = SceneObjectLabels.mapping[label.identifier],
                  let original = SemanticImageTransform.originalBounds(bounds(object.boundingBox), quarterTurn: image.quarterTurn) else { return nil }
            return SemanticObservation(envelope: image.frame.envelope, modelID: preset.modelID, modelVersion: Self.version,
                target: nil, text: name, labelScore: Double(label.confidence), imageBounds: original,
                visualContextConfirmed: true)
        }
        return SemanticBatch(frame: image.frame, observations: observations, inferenceDuration: clock.now() - started,
            modelID: preset.modelID, modelVersion: Self.version)
    }
    public static let classes = SceneObjectLabels.names
}
