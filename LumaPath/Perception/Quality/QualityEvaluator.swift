import Foundation
import LumaPathDomain

private struct QualityCell {
    var total = 0, usable = 0, low = 0, medium = 0, high = 0, invalid = 0
    var nearest: Double?
    var imageCount = 0, dark = 0, clipped = 0, pairs = 0
    var contrast = 0.0
}

/// Bounded frame-local evidence plus one prior grid. Never suppresses geometry or invents clear space.
public struct QualityEvaluator: Sendable {
    private var healthyFrames = 0
    private let configuration: QualityConfiguration
    private var previous: (frame: FrameDescriptor, nearest: [Double?])?
    public init(configuration: QualityConfiguration = .current) { self.configuration = configuration }

    public mutating func evaluate(frame: FrameDescriptor, depth: DepthImage?, image: LumaImage?,
                                  context: CaptureContext, at now: TimeInterval) throws -> QualityAssessment {
        try frame.validate()
        guard frame.envelope.isCurrent(in: context, at: now),
              depth == nil || depth?.frame == frame, image == nil || image?.frame == frame else {
            throw ContractError.invalidValue("staleOrMismatchedQualityInput")
        }
        if let previous, previous.frame.envelope.frameID.sessionID == frame.envelope.frameID.sessionID,
           previous.frame.envelope.frameID.generation == frame.envelope.frameID.generation,
           frame.envelope.frameID.sequence <= previous.frame.envelope.frameID.sequence {
            throw ContractError.invalidValue("outOfOrderQualityInput")
        }
        if previous?.frame.envelope.frameID.sessionID != frame.envelope.frameID.sessionID
            || previous?.frame.envelope.frameID.generation != frame.envelope.frameID.generation
            || previous?.frame.envelope.isCurrent(in: context,at: now) != true
            || previous?.frame.orientation != frame.orientation || previous?.frame.viewportSize != frame.viewportSize
            || previous?.frame.imageToDisplay != frame.imageToDisplay {
            healthyFrames = 0
        }
        let cfg = configuration, geometry = GeometryConfiguration.current
        var cells = [QualityCell](repeating: QualityCell(), count: 9)
        func cell(x: Int, y: Int, size: PixelSize) -> Int? {
            let p = frame.imageToDisplay.apply(x: (Double(x)+0.5)/Double(size.width), y: (Double(y)+0.5)/Double(size.height))
            guard p.x >= 0, p.x < 1, p.y >= 0, p.y < 1 else { return nil }
            return Int(p.y*3)*3+Int(p.x*3)
        }
        if let depth, let size = frame.depthSize, let intrinsics = frame.intrinsics {
            let k = intrinsics.scaled(from: frame.imageSize, to: size)
            for y in 0..<size.height {
                try Task.checkCancellation()
                for x in 0..<size.width {
                    guard let index = cell(x: x,y: y,size: size) else { continue }
                    let offset = y*size.width+x, z = Double(depth.values[offset]), confidence = depth.confidence?[offset]
                    cells[index].total += 1
                    if confidence == 0 { cells[index].low += 1 }
                    if confidence == 1 { cells[index].medium += 1 }
                    if confidence == 2 { cells[index].high += 1 }
                    if let confidence, confidence > 2 { cells[index].invalid += 1 }
                    guard z.isFinite, z >= geometry.minimumDepth, z <= geometry.maximumDepth,
                          confidence == nil || confidence == 1 || confidence == 2 else { continue }
                    let px = (Double(x)-k.cx)*z/k.fx, py = (Double(y)-k.cy)*z/k.fy
                    let range = (px*px+py*py+z*z).squareRoot()
                    guard range <= geometry.maximumDepth else { continue }
                    cells[index].usable += 1
                    cells[index].nearest = min(cells[index].nearest ?? .infinity,range)
                }
            }
        }
        if let image {
            for y in 0..<image.size.height {
                try Task.checkCancellation()
                for x in 0..<image.size.width {
                    guard let index = cell(x: x,y: y,size: image.size) else { continue }
                    let offset = y*image.size.width+x, value = image.values[offset]
                    cells[index].imageCount += 1
                    if value <= cfg.darkLuma { cells[index].dark += 1 }
                    if value >= cfg.clippedLuma { cells[index].clipped += 1 }
                    if x > 0, cell(x: x-1,y: y,size: image.size) == index {
                        cells[index].pairs += 1
                        cells[index].contrast += Double(abs(Int(value)-Int(image.values[offset-1])))/255
                    }
                }
            }
        }
        let comparable = previous.map {
            $0.frame.envelope.isCurrent(in: context,at: now) && $0.frame.orientation == frame.orientation
            && $0.frame.viewportSize == frame.viewportSize && $0.frame.imageToDisplay == frame.imageToDisplay
            && frame.tracking == .normal && $0.frame.tracking == .normal
            && frame.envelope.captureTimeMonotonic > $0.frame.envelope.captureTimeMonotonic
        } ?? false
        var regions: [RegionalQuality] = []
        for band in ImageBand.allCases.indices {
            for sector in ViewRegion.allCases.indices {
                let index = band*3+sector, c = cells[index]
                let fraction = c.total > 0 ? Double(c.usable)/Double(c.total) : nil
                let category: CoverageCategory = fraction.map { $0 >= cfg.highCoverage ? .high : ($0 >= cfg.limitedCoverage ? .limited : .sparse) } ?? .unknown
                let metrics = c.imageCount > 0 ? ImageConditionMetrics(sampleCount: c.imageCount,
                    darkFraction: Double(c.dark)/Double(c.imageCount),clippedFraction: Double(c.clipped)/Double(c.imageCount),
                    localContrast: c.pairs > 0 ? c.contrast/Double(c.pairs) : nil) : nil
                var changed: Bool?
                if comparable, let old = previous?.nearest[index], let nearest = c.nearest {
                    changed = abs(nearest-old) >= cfg.temporalRangeChange
                }
                regions.append(RegionalQuality(region: ViewRegion.allCases[sector],band: ImageBand.allCases[band],
                    sampledDepthPixels: c.total,usableDepthPixels: c.usable,confidenceKnown: depth?.confidence != nil,
                    lowConfidencePixels: depth?.confidence != nil ? c.low : nil,
                    mediumConfidencePixels: depth?.confidence != nil ? c.medium : nil,
                    highConfidencePixels: depth?.confidence != nil ? c.high : nil,
                    invalidConfidencePixels: depth?.confidence != nil ? c.invalid : nil,
                    coverage: category,image: metrics,temporalRangeChanged: changed))
            }
        }
        var reasons: [String] = []
        if depth == nil { reasons.append(frame.envelope.sourceMode == .cameraOnly ? "cameraOnlyNoDepth" : "depthUnavailable") }
        if depth?.confidence == nil { reasons.append("confidenceUnknown") }
        if regions.contains(where: { $0.image?.localContrast == nil }) { reasons.append("imageConditionsUnknown") }
        if frame.tracking != .normal { reasons.append("trackingDegraded") }
        if PoseBasis(frame: frame) == nil { reasons.append("worldReferenceUnavailable") }
        if regions.contains(where: { $0.coverage != .high }) { reasons.append("partialDepthCoverage") }
        if regions.contains(where: { ($0.image?.darkFraction ?? 0) >= cfg.affectedImageFraction }) { reasons.append("darkImage") }
        if regions.contains(where: { ($0.image?.clippedFraction ?? 0) >= cfg.affectedImageFraction }) { reasons.append("clippedImage") }
        if regions.contains(where: { ($0.image?.localContrast ?? 1) < cfg.minimumContrast }) { reasons.append("lowImageContrast") }
        if regions.contains(where: { $0.temporalRangeChanged == true }) { reasons.append("geometryChangedAssociationUnknown") }
        let expectedCameraOnly: Set<String> = ["cameraOnlyNoDepth", "confidenceUnknown", "partialDepthCoverage", "worldReferenceUnavailable"]
        let recoveryReasons = frame.envelope.sourceMode == .cameraOnly ? reasons.filter { !expectedCameraOnly.contains($0) } : reasons
        healthyFrames = recoveryReasons.isEmpty ? min(healthyFrames+1,cfg.recoveryFrames) : 0
        let state: SensingQuality
        if (depth == nil && frame.envelope.sourceMode == .liveDepth) || depth != nil && cells.allSatisfy({ $0.usable == 0 }) { state = .unavailable }
        else if !recoveryReasons.isEmpty { state = .limited }
        else if healthyFrames < cfg.recoveryFrames { state = .initializing; reasons.append("awaitingQualityRecovery") }
        else { state = reasons.isEmpty ? .active : .limited }
        let total = cells.reduce(0) { $0+$1.total }, usable = cells.reduce(0) { $0+$1.usable }
        let details = QualityDetails(configurationVersion: cfg.configurationVersion,frameID: frame.envelope.frameID,
            sampleAge: now-frame.envelope.captureTimeMonotonic,tracking: frame.tracking,regions: regions,
            worldDependentFunctionsSupported: PoseBasis(frame: frame) != nil,reasons: reasons)
        previous = (frame,cells.map(\.nearest))
        return QualityAssessment(state: state,
            reasons: reasons,usableDepthFraction: total > 0 ? Double(usable)/Double(total) : nil,details: details)
    }
}


/// Serial bounded quality processing for camera-only and image-enhancement sessions.
public actor QualityAssessmentEngine {
    private var evaluator = QualityEvaluator()
    public init() {}
    public func evaluate(frame: FrameDescriptor, depth: DepthImage?, image: LumaImage?, context: CaptureContext, at now: TimeInterval) throws -> QualityAssessment {
        try evaluator.evaluate(frame: frame, depth: depth, image: image, context: context, at: now)
    }
}
