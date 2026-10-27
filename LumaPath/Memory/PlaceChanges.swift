import Foundation
import LumaPathDomain

public enum PlaceChangeKind: String, Sendable { case newObject, layoutMayHaveChanged, movedLandmark }
public struct PlaceChange: Sendable {
    public let kind: PlaceChangeKind
    public let cell: VoxelKey?
    public let landmarkID: UUID?
    public let displacementMeters: Double?
}
/// Candidates for B7 review, never input to mandatory live-hazard suppression or automatic saving.
public struct PlaceChangeDetector: Sendable {
    private struct Key: Hashable { let kind: String; let cell: VoxelKey?; let landmark: UUID? }
    private var counts: [Key: Int] = [:]
    private var identity: String?
    private var lastSequence: UInt64?
    private var lastCapture: Double?
    public init() {}
    public mutating func compare(place: PlaceArchive, alignment: PlaceAlignment?, currentFrameID: UUID,
        current: OccupancySnapshot, currentLandmarks: [LandmarkMatch] = [], context: CaptureContext, at now: Double) -> [PlaceChange] {
        guard let alignment, alignment.isCurrent(place: place,context: context,currentFrameID: currentFrameID,at: now),
              (try? place.validate()) != nil, (try? current.frame.validate()) != nil,
              current.frame.envelope.isCurrent(in: context,at: now), current.frame.tracking == .normal,
              current.voxelSize.isFinite, abs(current.voxelSize-place.voxelSize) < 1e-6, !current.truncated,
              current.cells.count <= 20_000,
              currentLandmarks.count <= 512, Set(currentLandmarks.map(\.landmarkID)).count == currentLandmarks.count else {
            reset(); return []
        }
        let token = "\(place.id):\(place.revision):\(context.sessionID):\(context.generation):\(alignment.transform.id)"
        if identity != token { reset(); identity = token }
        let sequence = current.frame.envelope.frameID.sequence
        guard lastSequence.map({ sequence > $0 }) ?? true else { return [] }
        if let lastCapture, current.frame.envelope.captureTimeMonotonic-lastCapture > 0.75 { counts = [:] }
        lastSequence = sequence; lastCapture = current.frame.envelope.captureTimeMonotonic
        var pending: [Key: PlaceChange] = [:]
        for saved in place.cells {
            let size = place.voxelSize
            let center = SIMD3((Double(saved.key.x)+0.5)*size,(Double(saved.key.y)+0.5)*size,(Double(saved.key.z)+0.5)*size)
            let point = alignment.transform.apply(center)
            guard validPosition(point) else { continue }
            let key = VoxelKey(x: Int(floor(point.x/size)),y: Int(floor(point.y/size)),z: Int(floor(point.z/size)))
            guard let observed = current.cells[key], observed.key == key, observed.support >= 3,
                  observed.lastObservedAt.isFinite, observed.lastObservedAt >= current.frame.envelope.captureTimeMonotonic,
                  observed.lastObservedAt <= now else { continue }
            let kind: PlaceChangeKind?
            switch (saved.evidence,observed.evidence) {
            case (.observedFree,.occupied): kind = .newObject
            case (.occupied,.observedFree): kind = .layoutMayHaveChanged
            default: kind = nil // Missing/occluded/unknown evidence is never removal.
            }
            if let kind {
                pending[Key(kind: kind.rawValue,cell: saved.key,landmark: nil)] = PlaceChange(kind: kind,cell: saved.key,landmarkID: nil,displacementMeters: nil)
            }
        }
        for observed in currentLandmarks {
            guard validPosition(observed.currentPosition), let saved = place.landmarks.first(where: { $0.id == observed.landmarkID }) else { continue }
            let displacement = distance(alignment.transform.apply(saved.position),observed.currentPosition)
            if displacement >= 0.15 {
                pending[Key(kind: PlaceChangeKind.movedLandmark.rawValue,cell: nil,landmark: saved.id)] = PlaceChange(kind: .movedLandmark,cell: nil,landmarkID: saved.id,displacementMeters: displacement)
            }
        }
        counts = pending.mapValues { _ in 0 }.merging(counts.filter { pending[$0.key] != nil }) { _, previous in previous }
        var result: [PlaceChange] = []
        for (key,change) in pending {
            counts[key] = min(4,counts[key,default: 0]+1)
            if counts[key] == 3 { result.append(change) }
        }
        return result.sorted { "\($0.kind):\(String(describing: $0.cell)):\(String(describing: $0.landmarkID))" < "\($1.kind):\(String(describing: $1.cell)):\(String(describing: $1.landmarkID))" }
    }
    public mutating func reset() { counts = [:]; identity = nil; lastSequence = nil; lastCapture = nil }
}

public struct RememberedLandmarkCandidate: Sendable {
    public let placeID: UUID
    public let placeRevision: UUID
    public let landmarkID: UUID
    public let label: String
    public let currentPosition: SIMD3<Double>
    public let transformID: UUID
    public let envelope: ObservationEnvelope
    public let source: ObservationSource = .rememberedLandmark
}
public enum SavedLandmarkProvider {
    public static func candidates(place: PlaceArchive, alignment: PlaceAlignment?, context: CaptureContext,
                                  currentFrameID: UUID, at now: Double) -> [RememberedLandmarkCandidate] {
        guard (try? place.validate()) != nil, let alignment,
              alignment.isCurrent(place: place,context: context,currentFrameID: currentFrameID,at: now) else { return [] }
        return place.landmarks.compactMap { landmark in
            guard landmark.userConfirmed, let label = landmark.label else { return nil }
            return RememberedLandmarkCandidate(placeID: place.id,placeRevision: place.revision,landmarkID: landmark.id,
                label: label,currentPosition: alignment.transform.apply(landmark.position),transformID: alignment.transform.id,envelope: alignment.envelope)
        }
    }
}
