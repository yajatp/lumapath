import Foundation
import LumaPathDomain

/// Explicit saved-place → current-session rigid transform, column-major, meters.
public struct PlaceTransform: Codable, Sendable, Equatable {
    public let id: UUID
    public let savedFrameID: UUID
    public let currentFrameID: UUID
    public let matrix: [Double]
    public init(id: UUID = UUID(), savedFrameID: UUID, currentFrameID: UUID, matrix: [Double]) throws {
        self.id = id; self.savedFrameID = savedFrameID; self.currentFrameID = currentFrameID; self.matrix = matrix
        try validate()
    }
    public func validate() throws {
        guard matrix.count == 16, matrix.allSatisfy(\.isFinite),
              abs(matrix[3])+abs(matrix[7])+abs(matrix[11])+abs(matrix[15]-1) < 1e-6 else { throw ContractError.invalidValue("placeTransform") }
        let a = SIMD3(matrix[0],matrix[1],matrix[2]), b = SIMD3(matrix[4],matrix[5],matrix[6]), c = SIMD3(matrix[8],matrix[9],matrix[10])
        func dot(_ x: SIMD3<Double>, _ y: SIMD3<Double>) -> Double { x.x*y.x+x.y*y.y+x.z*y.z }
        let cross = SIMD3(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x)
        guard abs(dot(a,a)-1) < 1e-6, abs(dot(b,b)-1) < 1e-6, abs(dot(c,c)-1) < 1e-6,
              abs(dot(a,b))+abs(dot(a,c))+abs(dot(b,c)) < 1e-6, abs(dot(cross,c)-1) < 1e-6,
              validPosition(SIMD3(matrix[12],matrix[13],matrix[14])) else { throw ContractError.invalidValue("placeTransformRigid") }
    }
    public func apply(_ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(matrix[0]*p.x+matrix[4]*p.y+matrix[8]*p.z+matrix[12],
              matrix[1]*p.x+matrix[5]*p.y+matrix[9]*p.z+matrix[13],
              matrix[2]*p.x+matrix[6]*p.y+matrix[10]*p.z+matrix[14])
    }
}
public struct LandmarkMatch: Sendable {
    public let landmarkID: UUID
    public let currentPosition: SIMD3<Double>
    public init(landmarkID: UUID, currentPosition: SIMD3<Double>) { self.landmarkID = landmarkID; self.currentPosition = currentPosition }
}
public enum AlignmentPhase: String, Sendable { case searching, aligned, lost, timedOut }
public struct PlaceAlignment: Sendable {
    public let placeID: UUID
    public let revision: UUID
    public let context: CaptureContext
    public let transform: PlaceTransform
    public let envelope: ObservationEnvelope
    public let residualMeters: Double
    // Only the gate can issue accepted alignment evidence.
    init(place: PlaceArchive, context: CaptureContext, transform: PlaceTransform, envelope: ObservationEnvelope, residual: Double) {
        placeID = place.id; revision = place.revision; self.context = context; self.transform = transform
        self.envelope = envelope; residualMeters = residual
    }
    public func isCurrent(place: PlaceArchive, context: CaptureContext, currentFrameID: UUID, at now: Double) -> Bool {
        placeID == place.id && revision == place.revision && self.context == context
        && transform.savedFrameID == place.coordinateFrameID && transform.currentFrameID == currentFrameID
        && envelope.isCurrent(in: context,at: now)
    }
}
/// Hypotheses: ≤15 cm maximum residual, ≥3 non-collinear distributed matches for ≥1 second.
/// Normal AR tracking alone cannot issue an alignment. Ambiguous room evidence always fails closed.
public struct RelocalizationGate: Sendable {
    public private(set) var phase: AlignmentPhase = .searching
    public private(set) var alignment: PlaceAlignment?
    private let place: PlaceArchive
    private let context: CaptureContext
    private let currentFrameID: UUID
    private let beganAt: Double
    private var stableSince: Double?
    private var previous: PlaceTransform?
    private var lastTime: Double
    private var lastSequence: UInt64?
    private var acceptedFrames = 0
    private var lastAcceptedCapture: Double?
    private var alignmentIdentity = UUID()
    public init(place: PlaceArchive, context: CaptureContext, currentFrameID: UUID, at now: Double) throws {
        try place.validate()
        guard now.isFinite, now >= 0 else { throw ContractError.invalidValue("alignmentClock") }
        self.place = place; self.context = context; self.currentFrameID = currentFrameID; beganAt = now; lastTime = now
    }
    @discardableResult public mutating func update(frame: FrameDescriptor, transform: PlaceTransform,
        matches: [LandmarkMatch], ambiguousPlace: Bool, at now: Double) -> PlaceAlignment? {
        alignment = nil
        guard now.isFinite, now >= lastTime else { lose(); return nil }
        lastTime = now
        if phase == .timedOut { return nil }
        if let lastAcceptedCapture, now-lastAcceptedCapture > 0.75 { lose() }
        if phase != .aligned && now-beganAt >= 20 { phase = .timedOut; loseStability(); return nil }
        guard (try? frame.validate()) != nil, (try? transform.validate()) != nil,
              frame.envelope.isCurrent(in: context,at: now), frame.tracking == .normal, frame.cameraToWorld != nil,
              transform.savedFrameID == place.coordinateFrameID, transform.currentFrameID == currentFrameID,
              !ambiguousPlace, matches.count >= 3, matches.count <= 512,
              Set(matches.map(\.landmarkID)).count == matches.count,
              lastSequence.map({ frame.envelope.frameID.sequence > $0 }) ?? true else { lose(); return nil }
        lastSequence = frame.envelope.frameID.sequence
        var points: [SIMD3<Double>] = []; var residual = 0.0
        for match in matches {
            guard let saved = place.landmarks.first(where: { $0.id == match.landmarkID }), validPosition(match.currentPosition) else { lose(); return nil }
            points.append(saved.position); residual = max(residual,distance(transform.apply(saved.position),match.currentPosition))
        }
        // A spatially distributed triangle rejects a line or a tight cluster; use farthest baseline.
        let origin = points[0]
        let second = points.max { distance(origin,$0) < distance(origin,$1) }!
        let axis = second-origin; let length = distance(second,origin)
        guard length >= 0.5 else { lose(); return nil }
        let spread = points.map { point -> Double in
            let d = point-origin, cross = SIMD3(axis.y*d.z-axis.z*d.y,axis.z*d.x-axis.x*d.z,axis.x*d.y-axis.y*d.x)
            return distance(cross,.zero)/length
        }.max() ?? 0
        guard spread >= 0.25, residual <= 0.15 else { lose(); return nil }
        if let previous {
            // Includes rotation changes: test the transform at every matched anchor, not translation alone.
            let jump = points.map { distance(previous.apply($0),transform.apply($0)) }.max() ?? 0
            if jump > 0.15 { lose(); return nil }
        }
        previous = transform
        lastAcceptedCapture = frame.envelope.captureTimeMonotonic
        if stableSince == nil { stableSince = frame.envelope.captureTimeMonotonic }
        acceptedFrames += 1
        guard frame.envelope.captureTimeMonotonic-(stableSince ?? now) >= 1, acceptedFrames >= 3 else { phase = .searching; return nil }
        phase = .aligned
        // Transform identity names the accepted continuous alignment, not each caller-created matrix sample.
        guard let acceptedTransform = try? PlaceTransform(id: alignmentIdentity,savedFrameID: transform.savedFrameID,
            currentFrameID: transform.currentFrameID,matrix: transform.matrix) else { lose(); return nil }
        let result = PlaceAlignment(place: place,context: context,transform: acceptedTransform,envelope: frame.envelope,residual: residual)
        alignment = result; return result
    }
    public mutating func tick(at now: Double) {
        guard now.isFinite, now >= lastTime else { lose(); return }; lastTime = now
        if let alignment, !alignment.envelope.isCurrent(in: context,at: now) { lose() }
        if phase != .aligned && now-beganAt >= 20 { phase = .timedOut; loseStability() }
    }
    public mutating func invalidate() { lose() }
    private mutating func loseStability() { alignment = nil; stableSince = nil; previous = nil; acceptedFrames = 0; lastAcceptedCapture = nil; alignmentIdentity = UUID() }
    private mutating func lose() { loseStability(); if phase != .timedOut { phase = .lost } }
}

extension RelocalizationGate {
    /// Connect actual current geometric feature extraction to correspondence checking and sustained alignment.
    /// Competing room hypotheses or insufficient room-identity evidence must set ambiguousPlace to true.
    @discardableResult public mutating func update(frame: FrameDescriptor, place: PlaceArchive, transform: PlaceTransform,
        currentFeaturePositions: [SIMD3<Double>], ambiguousPlace: Bool, at now: Double) -> PlaceAlignment? {
        guard place.id == self.place.id, place.revision == self.place.revision else { invalidate(); return nil }
        let result = PlaceGeometryMatcher.match(place: place,transform: transform,currentPositions: currentFeaturePositions)
        // The existing gate verifies its own selected-place landmarks and transform frame identity.
        return update(frame: frame,transform: transform,matches: result.matches,ambiguousPlace: ambiguousPlace || result.ambiguous,at: now)
    }
}

extension RelocalizationGate {
    /// Adapter for A3's current geometry components. It never uses positions from an initial world map as observations.
    @discardableResult public mutating func update(frame: FrameDescriptor, place: PlaceArchive, transform: PlaceTransform,
        geometry: [GeometryObservation], ambiguousPlace: Bool, at now: Double) -> PlaceAlignment? {
        guard (try? frame.validate()) != nil, frame.depthKind != .none, let m = frame.cameraToWorld, geometry.count <= 512 else { invalidate(); return nil }
        let points = geometry.compactMap { observation -> SIMD3<Double>? in
            guard observation.envelope == frame.envelope, observation.envelope.isCurrent(in: context,at: now),
                  observation.details?.evidence == .confidenceBacked, (observation.details?.supportCount ?? 0) >= 8,
                  observation.opticalPoint.range.isFinite, (0.3...4).contains(observation.opticalPoint.range) else { return nil }
            let p = observation.opticalPoint.arKitCameraPoint
            let world = SIMD3(m[0]*p.x+m[4]*p.y+m[8]*p.z+m[12],m[1]*p.x+m[5]*p.y+m[9]*p.z+m[13],m[2]*p.x+m[6]*p.y+m[10]*p.z+m[14])
            return validPosition(world) ? world : nil
        }
        return update(frame: frame,place: place,transform: transform,currentFeaturePositions: points,ambiguousPlace: ambiguousPlace,at: now)
    }
}
