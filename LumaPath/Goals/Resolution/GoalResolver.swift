import Foundation
import LumaPathDomain
import LumaPathModels
import LumaPathMemory

public enum GoalSearchPhase: String, Sendable { case idle, unavailable, searching, candidate, notObservedYet, cancelled, completed }
public struct ResolvedGoalCandidate: Sendable {
    public let observation: SemanticObservation
    public let association: DepthAssociation?
    /// Relative to the displayed image after rotation/crop, never a world bearing.
    public let imagePosition: ImageRelativePosition
}
public enum ImageRelativePosition: String, Sendable { case left, center, right, outsideView }
public struct GoalSearchSnapshot: Sendable {
    public let revision: UUID?
    public let target: GoalTarget?
    public let phase: GoalSearchPhase
    public let candidate: ResolvedGoalCandidate?
    public let reason: String?
    public let rememberedCandidate: RememberedLandmarkCandidate?
}

/// Goal resolution only. Scene text is data and never enters B6's command parser.
public struct GoalResolver: Sendable {
    private let registry: ModelRegistry
    private var context: CaptureContext?
    private var revision: UUID?
    private var target: GoalTarget?
    private var phase: GoalSearchPhase = .idle
    private var reason: String?
    private var beganAt: Double = 0
    private var lastNow: Double = 0
    private var candidates: [ResolvedGoalCandidate] = []
    private var remembered: [RememberedLandmarkCandidate] = []
    private var savedPlaceID: UUID?
    private var savedPlaceRevision: UUID?
    private var index = 0
    private var lastSequences: [String: UInt64] = [:]
    public init(registry: ModelRegistry = ModelRegistry()) { self.registry = registry }
    /// Already validated candidates; callers must tick immediately before consuming them.
    public var currentCandidates: [ResolvedGoalCandidate] { phase == .candidate ? candidates : [] }
    public mutating func selectCandidate(_ id: UUID, context: CaptureContext, at now: Double) {
        tick(context: context, at: now)
        if let selected = candidates.firstIndex(where: { $0.observation.id == id }) { index = selected }
    }
    public mutating func clearCurrentCandidates(context: CaptureContext, at now: Double) {
        candidates = []; remembered = []; tick(context: context, at: now)
    }
    public var snapshot: GoalSearchSnapshot {
        GoalSearchSnapshot(revision: revision,target: target,phase: phase,
            candidate: phase == .candidate && candidates.indices.contains(index) ? candidates[index] : nil,reason: reason,
            rememberedCandidate: phase == .candidate && remembered.indices.contains(index) ? remembered[index] : nil)
    }
    @discardableResult public mutating func begin(_ target: GoalTarget, context: CaptureContext, research: Bool = false, at now: Double) -> UUID {
        revision = UUID(); self.target = target; self.context = context; beganAt = now; lastNow = now
        candidates = []; remembered = []; savedPlaceID = nil; savedPlaceRevision = nil; index = 0; lastSequences = [:]
        let capability = registry.capability(for: target)
        if !now.isFinite || now < 0 { phase = .unavailable; reason = "invalidClock" }
        else if research ? !capability.researchAvailable : !capability.ordinaryLiveAvailable {
            phase = .unavailable; reason = capability.reason
        } else { phase = .searching; reason = nil }
        return revision!
    }
    /// A7 is a separate provider, not a fabricated camera model. Research use only until physical G5 acceptance.
    @discardableResult public mutating func beginSavedLandmark(place: PlaceArchive, context: CaptureContext,
                                                               research: Bool = false, at now: Double) throws -> UUID {
        try place.validate()
        guard now.isFinite, now >= 0 else { throw ContractError.invalidValue("goalClock") }
        let token = begin(.savedLandmark,context: context,research: true,at: now)
        savedPlaceID = place.id; savedPlaceRevision = place.revision
        phase = research ? .searching : .unavailable
        reason = research ? "alignmentRequired" : "physicalPlaceValidationPending"
        return token
    }
    /// B7 must refresh using the selected current archive; nil handles deletion, and a revision change invalidates the goal.
    @discardableResult public mutating func updateSavedLandmarks(place: PlaceArchive?, alignment: PlaceAlignment?,
        currentFrameID: UUID, revision expected: UUID, context current: CaptureContext, at now: Double) -> Bool {
        guard revision == expected, context == current, target == .savedLandmark,
              phase == .searching || phase == .candidate || phase == .notObservedYet,
              now.isFinite, now >= lastNow else { return false }
        guard let place, place.id == savedPlaceID, place.revision == savedPlaceRevision else {
            invalidate(reason: "placeDeletedOrRevised"); return false
        }
        lastNow = now
        remembered = SavedLandmarkProvider.candidates(place: place,alignment: alignment,context: current,currentFrameID: currentFrameID,at: now)
            .sorted { $0.landmarkID.uuidString < $1.landmarkID.uuidString }
        index = 0
        phase = remembered.isEmpty ? (now-beganAt >= 20 ? .notObservedYet : .searching) : .candidate
        reason = remembered.isEmpty ? "alignmentOrConfirmedLandmarkRequired" : "rememberedPositionNotCurrentDetection"
        return true
    }
    @discardableResult public mutating func update(_ batch: SemanticBatch, associations: [DepthAssociation] = [],
                                                 handrailEvidence: [HandrailStructureEvidence] = [],
                                                 revision expected: UUID, context current: CaptureContext, at now: Double) -> Bool {
        guard revision == expected, context == current, phase == .searching || phase == .candidate || phase == .notObservedYet,
              now.isFinite, now >= lastNow, batch.schemaVersion == 1, (try? batch.frame.validate()) != nil,
              batch.frame.envelope.isCurrent(in: current,at: now),
              batch.inferenceDuration.isFinite, batch.inferenceDuration >= 0,
              lastSequences[batch.modelID].map({ batch.frame.envelope.frameID.sequence > $0 }) ?? true,
              let manifest = registry.manifests[batch.modelID], manifest.version == batch.modelVersion,
              registry.capability(for: target!).modelIDs.contains(batch.modelID) else { return false }
        lastNow = now; lastSequences[batch.modelID] = batch.frame.envelope.frameID.sequence
        candidates = batch.observations.prefix(64).compactMap { observation in
            guard observation.target == target, observation.source == .currentCamera,
                  observation.envelope == batch.frame.envelope, observation.envelope.isCurrent(in: current,at: now),
                  observation.modelID == batch.modelID, observation.modelVersion == manifest.version,
                  observation.labelScore.isFinite, (0.6...1).contains(observation.labelScore),
                  observation.imageBounds.clipped == observation.imageBounds,
                  observation.visualContextConfirmed else { return nil }
            if observation.target == .handrail && (batch.frame.depthKind == .none || !handrailEvidence.contains(where: { $0.supports(observation,context: current,at: now) })) { return nil }
            let association = associations.first { association in
                batch.frame.depthKind != .none && batch.frame.intrinsics != nil
                && association.observationID == observation.id && association.frameID == observation.envelope.frameID
                && association.rangeMeters.map({ $0.isFinite && $0 > 0 && $0 <= 4 }) == true
                && association.axialDepthMeters.map({ $0.isFinite && (0.3...4).contains($0) }) == true
                && association.bearingRadians?.isFinite == true
                && association.associationSupport.map({ $0.isFinite && (0.5...1).contains($0) }) == true
                && association.uncertaintyMeters.map({ $0.isFinite && $0 >= 0 }) == true
            }
            let bounds = observation.imageBounds
            let center = batch.frame.imageToDisplay.apply(x: (bounds.minX+bounds.maxX)/2, y: (bounds.minY+bounds.maxY)/2)
            let position: ImageRelativePosition = center.x < 0 || center.x > 1 || center.y < 0 || center.y > 1
                ? .outsideView : center.x < 1.0/3 ? .left : center.x > 2.0/3 ? .right : .center
            return ResolvedGoalCandidate(observation: observation,association: association,imagePosition: position)
        }.sorted {
            if $0.observation.labelScore != $1.observation.labelScore { return $0.observation.labelScore > $1.observation.labelScore }
            let a = $0.observation.imageBounds, b = $1.observation.imageBounds
            return abs((a.minX+a.maxX)/2-0.5) < abs((b.minX+b.maxX)/2-0.5)
        }
        index = 0; phase = candidates.isEmpty ? (now-beganAt >= 20 ? .notObservedYet : .searching) : .candidate
        reason = phase == .notObservedYet ? "notObservedYetNotAbsent" : nil
        return true
    }
    public mutating func tick(context current: CaptureContext, at now: Double) {
        guard context == current else { invalidate(reason: "generationChanged"); return }
        guard now.isFinite, now >= lastNow else { return }; lastNow = now
        guard phase == .candidate || phase == .searching || phase == .notObservedYet else { return }
        candidates.removeAll { !$0.observation.envelope.isCurrent(in: current,at: now) }
        remembered.removeAll { !$0.envelope.isCurrent(in: current,at: now) }
        let count = target == .savedLandmark ? remembered.count : candidates.count
        index = min(index,max(0,count-1))
        if candidates.isEmpty && remembered.isEmpty {
            phase = now-beganAt >= 20 ? .notObservedYet : .searching
            reason = phase == .notObservedYet ? "notObservedYetNotAbsent" : "candidateLost"
        }
    }
    public mutating func repeatCandidate(context: CaptureContext, at now: Double) -> ResolvedGoalCandidate? {
        tick(context: context,at: now); return snapshot.candidate
    }
    public mutating func repeatRememberedCandidate(context: CaptureContext, at now: Double) -> RememberedLandmarkCandidate? {
        tick(context: context,at: now); return snapshot.rememberedCandidate
    }
    public mutating func next(context: CaptureContext, at now: Double) {
        tick(context: context,at: now)
        let count = target == .savedLandmark ? remembered.count : candidates.count
        if phase == .candidate && count > 0 { index = (index+1)%count }
    }
    public mutating func continueSearch(context current: CaptureContext, at now: Double) {
        tick(context: current,at: now)
        guard phase == .notObservedYet else { return }; beganAt = now; phase = .searching; reason = nil
    }
    public mutating func complete(context: CaptureContext, at now: Double) {
        tick(context: context,at: now)
        guard phase == .candidate else { return }; candidates = []; remembered = []; phase = .completed
    }
    public mutating func invalidate(reason: String = "cancelled") { revision = nil; candidates = []; remembered = []; phase = .cancelled; self.reason = reason }
}
