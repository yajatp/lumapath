import Foundation
import Testing
import LumaPathDomain
import LumaPathMemory
import LumaPathGoals

private let memoryContext = CaptureContext(sessionID: UUID(),generation: 1,mode: .demoReplay)
private let currentSpace = UUID()
private let identityMatrix: [Double] = [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
private func placeFixture(cells: [SavedCell] = []) -> PlaceArchive {
    PlaceArchive(name: "Room",appVersion: "test",qualitySummary: "Analytic fixture, no physical evidence",landmarks: [
        PlaceLandmark(label: "Desk",userConfirmed: true,position: SIMD3(0,0,0)),
        PlaceLandmark(position: SIMD3(1,0,0)),PlaceLandmark(position: SIMD3(0,0,1))],cells: cells)
}
private func memoryFrame(_ sequence: UInt64, _ time: Double, tracking: TrackingQuality = .normal, depth: Bool = false) -> FrameDescriptor {
    FrameDescriptor(envelope: ObservationEnvelope(frameID: FrameID(context: memoryContext,sequence: sequence),mode: .demoReplay,
        capturedAt: time,createdAt: time,lifetime: 0.3),imageSize: PixelSize(width: 640,height: 480),depthSize: depth ? PixelSize(width: 64,height: 48) : nil,
        confidenceSize: nil,intrinsics: CameraIntrinsics(fx: 500,fy: 500,cx: 320,cy: 240),cameraToWorld: identityMatrix,
        orientation: .portrait,viewportSize: PixelSize(width: 640,height: 480),imageToDisplay: .identity,depthKind: depth ? .sceneDepth : .none,tracking: tracking)
}
private func transform(_ place: PlaceArchive, x: Double = 0) throws -> PlaceTransform {
    var m = identityMatrix; m[12] = x
    return try PlaceTransform(savedFrameID: place.coordinateFrameID,currentFrameID: currentSpace,matrix: m)
}
private func matches(_ place: PlaceArchive, transform: PlaceTransform) -> [LandmarkMatch] {
    place.landmarks.map { LandmarkMatch(landmarkID: $0.id,currentPosition: transform.apply($0.position)) }
}
private func align(_ place: PlaceArchive) throws -> (RelocalizationGate, PlaceTransform, PlaceAlignment) {
    let t = try transform(place)
    var gate = try RelocalizationGate(place: place,context: memoryContext,currentFrameID: currentSpace,at: 100)
    for (sequence,time) in [(UInt64(1),100.0),(2,100.5),(3,101.0)] {
        _ = gate.update(frame: memoryFrame(sequence,time),transform: t,matches: matches(place,transform: t),ambiguousPlace: false,at: time)
    }
    return (gate,t,try #require(gate.alignment))
}

@Test func alignmentRequiresDistributedSustainedMatchesAndRejectsSimilarRoomsJumpsAndLoss() throws {
    let place = placeFixture(), t = try transform(place)
    var gate = try RelocalizationGate(place: place,context: memoryContext,currentFrameID: currentSpace,at: 100)
    #expect((gate.update(frame: memoryFrame(1,100),transform: t,matches: matches(place,transform: t),ambiguousPlace: false,at: 100) == nil))
    #expect((gate.update(frame: memoryFrame(2,100.5),transform: t,matches: matches(place,transform: t),ambiguousPlace: true,at: 100.5) == nil))
    #expect(gate.phase == .lost)
    var (aligned,_,_) = try align(place)
    let jump = try transform(place,x: 0.3)
    #expect((aligned.update(frame: memoryFrame(4,101.1),transform: jump,matches: matches(place,transform: jump),ambiguousPlace: false,at: 101.1) == nil))
    #expect(aligned.alignment == nil)
    var (tracking,_,_) = try align(place)
    #expect((tracking.update(frame: memoryFrame(4,101.1,tracking: .limited),transform: t,matches: matches(place,transform: t),ambiguousPlace: false,at: 101.1) == nil))
    var (expired,_,_) = try align(place); expired.tick(at: 101.3)
    #expect(expired.alignment == nil)
    gate.tick(at: 120); #expect(gate.phase == .timedOut)
    #expect((gate.update(frame: memoryFrame(10,121),transform: t,matches: matches(place,transform: t),ambiguousPlace: false,at: 121) == nil))
}

@Test func mismatchesCollinearDuplicateAndWrongCoordinateFramesNeverActivateMemory() throws {
    let place = placeFixture(), t = try transform(place)
    var gate = try RelocalizationGate(place: place,context: memoryContext,currentFrameID: currentSpace,at: 100)
    let wrong = place.landmarks.map { LandmarkMatch(landmarkID: $0.id,currentPosition: $0.position+SIMD3(1,0,0)) }
    #expect((gate.update(frame: memoryFrame(1,100),transform: t,matches: wrong,ambiguousPlace: false,at: 100) == nil))
    let duplicate = Array(repeating: matches(place,transform: t)[0],count: 3)
    #expect((gate.update(frame: memoryFrame(2,100.1),transform: t,matches: duplicate,ambiguousPlace: false,at: 100.1) == nil))
    let otherFrame = try PlaceTransform(savedFrameID: UUID(),currentFrameID: currentSpace,matrix: identityMatrix)
    #expect((gate.update(frame: memoryFrame(3,100.2),transform: otherFrame,matches: matches(place,transform: t),ambiguousPlace: false,at: 100.2) == nil))
    let line = PlaceArchive(name: "Line",appVersion: "1",qualitySummary: "fixture",landmarks: [0.0,1,2].map { PlaceLandmark(position: SIMD3($0,0,0)) })
    var lineGate = try RelocalizationGate(place: line,context: memoryContext,currentFrameID: currentSpace,at: 100)
    let lineTransform = try transform(line)
    for i in 0..<4 {
        #expect((lineGate.update(frame: memoryFrame(UInt64(i+1),100+Double(i)*0.5),transform: lineTransform,
            matches: matches(line,transform: lineTransform),ambiguousPlace: false,at: 100+Double(i)*0.5) == nil))
    }
    var scale = identityMatrix; scale[0] = 2
    #expect(throws: ContractError.self) { try PlaceTransform(savedFrameID: UUID(),currentFrameID: UUID(),matrix: scale) }
}

@Test func changesRequireFreshThreeFrameEvidenceAndOcclusionNeverMeansRemoval() throws {
    let freeKey = VoxelKey(x: 5,y: 0,z: 0), occupiedKey = VoxelKey(x: 6,y: 0,z: 0)
    let place = placeFixture(cells: [SavedCell(key: freeKey,evidence: .observedFree),SavedCell(key: occupiedKey,evidence: .occupied)])
    var (gate,t,alignment) = try align(place)
    var detector = PlaceChangeDetector()
    func snapshot(_ sequence: UInt64, _ time: Double, formerObject: VolumeEvidence) -> OccupancySnapshot {
        OccupancySnapshot(frame: memoryFrame(sequence,time),voxelSize: 0.2,cells: [
            freeKey: VoxelObservation(key: freeKey,evidence: .occupied,lastObservedAt: time,support: 4),
            occupiedKey: VoxelObservation(key: occupiedKey,evidence: formerObject,lastObservedAt: time,support: 4)],truncated: false)
    }
    for i in 0..<3 {
        let time = 101+Double(i)*0.1, sequence = UInt64(i+4)
        let nextAlignment = gate.update(frame: memoryFrame(sequence,time),transform: t,matches: matches(place,transform: t),ambiguousPlace: false,at: time)
        alignment = try #require(nextAlignment)
        let changes = detector.compare(place: place,alignment: alignment,currentFrameID: currentSpace,current: snapshot(sequence,time,formerObject: .unknown),context: memoryContext,at: time)
        #expect(changes.count == (i == 2 ? 1 : 0))
        #expect(changes.allSatisfy { $0.kind == .newObject })
    }
    detector.reset()
    for i in 0..<3 {
        let time = 101.3+Double(i)*0.1, sequence = UInt64(i+7)
        let nextAlignment = gate.update(frame: memoryFrame(sequence,time),transform: t,matches: matches(place,transform: t),ambiguousPlace: false,at: time)
        alignment = try #require(nextAlignment)
        let moved = LandmarkMatch(landmarkID: place.landmarks[0].id,currentPosition: SIMD3(0.4,0,0))
        let changes = detector.compare(place: place,alignment: alignment,currentFrameID: currentSpace,current: snapshot(sequence,time,formerObject: .observedFree),currentLandmarks: [moved],context: memoryContext,at: time)
        if i == 2 { #expect(Set(changes.map(\.kind)) == [.newObject,.layoutMayHaveChanged,.movedLandmark]) }
        else { #expect(changes.isEmpty) }
    }
    #expect(detector.compare(place: place,alignment: nil,currentFrameID: currentSpace,current: snapshot(20,102,formerObject: .observedFree),context: memoryContext,at: 102).isEmpty)
}

@Test func savedGoalIsRememberedOnlyAndInvalidatesOnRevisionDeletionAndExpiry() throws {
    let place = placeFixture(); let (_,_,alignment) = try align(place)
    var goal = GoalResolver()
    let revision = try goal.beginSavedLandmark(place: place,context: memoryContext,research: true,at: 101)
    let updated = goal.updateSavedLandmarks(place: place,alignment: alignment,currentFrameID: currentSpace,revision: revision,context: memoryContext,at: 101)
    #expect(updated)
    #expect(goal.snapshot.phase == .candidate && goal.snapshot.candidate == nil)
    #expect(goal.snapshot.rememberedCandidate?.source == .rememberedLandmark)
    #expect(goal.snapshot.rememberedCandidate?.label == "Desk")
    goal.tick(context: memoryContext,at: 101.3)
    #expect(goal.snapshot.rememberedCandidate == nil)
    #expect((goal.updateSavedLandmarks(place: nil,alignment: nil,currentFrameID: currentSpace,revision: revision,context: memoryContext,at: 101.4) == false))
    #expect(goal.snapshot.phase == .cancelled)
    #expect(SavedLandmarkProvider.candidates(place: place,alignment: alignment,context: memoryContext,currentFrameID: UUID(),at: 101).isEmpty)
}

@Test func protectedStoreEnforcesReviewRollbackCapsCorruptionAndCompleteDeletion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PlaceStore(directory: directory,maximumPlaces: 1)
    let place = placeFixture(); try await store.save(place)
    #expect(try await store.load(place.id) == place)
    let update = PlaceArchive(id: place.id,coordinateFrameID: place.coordinateFrameID,name: "Renamed room",appVersion: "test",
        createdAt: place.createdAt,updatedAt: place.updatedAt,qualitySummary: "fixture",landmarks: place.landmarks)
    do { try await store.update(update,reviewedRevision: UUID()); Issue.record("Accepted stale review") } catch {}
    try await store.update(update,reviewedRevision: place.revision)
    let undone = try await store.rollback(place.id,reviewedRevision: update.revision)
    #expect(undone.name == place.name && undone.revision != place.revision)
    do { try await store.save(placeFixture()); Issue.record("Exceeded count cap") } catch {}
    let file = directory.appendingPathComponent(place.id.uuidString+".place")
    try Data("corrupt".utf8).write(to: file)
    do { _ = try await store.load(place.id); Issue.record("Loaded corruption") } catch {}
    try await store.delete(place.id)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    let small = try PlaceStore(directory: directory,maximumBytes: 10)
    do { try await small.save(place); Issue.record("Exceeded byte cap") } catch {}
}

@Test func archiveRejectsUnsupportedSchemasAndSymlinkReads() async throws {
    var place = placeFixture(); place.schemaVersion = 99
    #expect(throws: ContractError.self) { try place.validate() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PlaceStore(directory: directory)
    let id = UUID(), target = directory.appendingPathComponent("outside")
    try Data("outside".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(id.uuidString+".place"),withDestinationURL: target)
    do { _ = try await store.load(id); Issue.record("Followed symlink") } catch {}
    try await store.delete(id)
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test func alignmentCannotBridgeAnObservationGapOrReactivateInOrdinaryMode() throws {
    let place = placeFixture(), t = try transform(place)
    var gate = try RelocalizationGate(place: place,context: memoryContext,currentFrameID: currentSpace,at: 100)
    _ = gate.update(frame: memoryFrame(1,100),transform: t,matches: matches(place,transform: t),ambiguousPlace: false,at: 100)
    _ = gate.update(frame: memoryFrame(2,101.1),transform: t,matches: matches(place,transform: t),ambiguousPlace: false,at: 101.1)
    #expect(gate.alignment == nil)
    var goal = GoalResolver()
    _ = try goal.beginSavedLandmark(place: place,context: memoryContext,at: 101)
    #expect(goal.snapshot.phase == .unavailable)
    let revision = try goal.beginSavedLandmark(place: place,context: memoryContext,research: true,at: 101)
    let revised = PlaceArchive(id: place.id,coordinateFrameID: place.coordinateFrameID,name: place.name,appVersion: place.appVersion,
        createdAt: place.createdAt,updatedAt: place.updatedAt,qualitySummary: place.qualitySummary,landmarks: place.landmarks)
    let accepted = goal.updateSavedLandmarks(place: revised,alignment: nil,currentFrameID: currentSpace,revision: revision,context: memoryContext,at: 101)
    #expect(!accepted && goal.snapshot.phase == .cancelled)
}

@Test func rememberedNextCyclesAllCandidatesAndRepeatRechecksExpiry() throws {
    let original = placeFixture()
    let place = PlaceArchive(name: "Three labels",appVersion: "test",qualitySummary: "fixture",landmarks: original.landmarks.enumerated().map {
        PlaceLandmark(id: $1.id,label: "Label \($0)",userConfirmed: true,position: $1.position)
    })
    let (_,_,alignment) = try align(place)
    var goal = GoalResolver()
    let revision = try goal.beginSavedLandmark(place: place,context: memoryContext,research: true,at: 101)
    _ = goal.updateSavedLandmarks(place: place,alignment: alignment,currentFrameID: currentSpace,revision: revision,context: memoryContext,at: 101)
    var ids = Set<UUID>()
    for _ in 0..<3 {
        let candidate = goal.repeatRememberedCandidate(context: memoryContext,at: 101)
        ids.insert(try #require(candidate).landmarkID)
        goal.next(context: memoryContext,at: 101)
    }
    #expect(ids.count == 3)
    let expired = goal.repeatRememberedCandidate(context: memoryContext,at: 101.3)
    #expect(expired == nil)
}

@Test func currentGeometryMatcherRejectsCompetingFeaturesAndFeedsAlignmentWithoutSavedAnchorIDs() throws {
    let place = placeFixture(), t = try transform(place)
    let currentPoints = place.landmarks.map { t.apply($0.position)+SIMD3(0.02,0,0) }
    let result = PlaceGeometryMatcher.match(place: place,transform: t,currentPositions: currentPoints)
    #expect(result.matches.count == 3 && !result.ambiguous)
    let competing = PlaceGeometryMatcher.match(place: place,transform: t,currentPositions: currentPoints+[SIMD3(0.03,0,0)])
    #expect(competing.ambiguous)
    var gate = try RelocalizationGate(place: place,context: memoryContext,currentFrameID: currentSpace,at: 100)
    for i in 0..<3 {
        let time = 100+Double(i)*0.5
        _ = gate.update(frame: memoryFrame(UInt64(i+1),time),place: place,transform: t,currentFeaturePositions: currentPoints,ambiguousPlace: false,at: time)
    }
    #expect(gate.phase == .aligned)
    let acceptedID = gate.alignment?.transform.id
    let refreshed = gate.update(frame: memoryFrame(4,101.05),place: place,transform: try transform(place),currentFeaturePositions: currentPoints,ambiguousPlace: false,at: 101.05)
    #expect(refreshed?.transform.id == acceptedID)
    let lost = gate.update(frame: memoryFrame(5,101.1),place: place,transform: t,currentFeaturePositions: currentPoints,ambiguousPlace: true,at: 101.1)
    #expect(lost == nil && gate.alignment == nil)
}

@Test func geometryComponentAdapterUsesFreshMeasuredPositionsAndRejectsCameraOnlyInput() throws {
    let place = PlaceArchive(name: "Geometry",appVersion: "test",qualitySummary: "fixture",landmarks: [
        PlaceLandmark(position: SIMD3(0,0,-2)),PlaceLandmark(position: SIMD3(1,0,-2)),PlaceLandmark(position: SIMD3(0,1,-2))])
    let t = try transform(place)
    var gate = try RelocalizationGate(place: place,context: memoryContext,currentFrameID: currentSpace,at: 100)
    for i in 0..<3 {
        let time = 100+Double(i)*0.5, frame = memoryFrame(UInt64(i+1),time,depth: true)
        let observations = place.landmarks.map { landmark in
            let point = OpticalPoint(x: landmark.position.x,y: -landmark.position.y,z: -landmark.position.z)
            return GeometryObservation(id: UUID(),envelope: frame.envelope,opticalPoint: point,axialDepthMeters: point.z,rangeMeters: point.range,
                details: GeometryDetails(imageBounds: NormalizedBounds(minX: 0,minY: 0,maxX: 1,maxY: 1),displayBounds: nil,
                    corridor: .unknown,bearingRadians: nil,supportCount: 12,groundRelation: .raised,heightAboveGroundMeters: nil,evidence: .confidenceBacked))
        }
        _ = gate.update(frame: frame,place: place,transform: t,geometry: observations,ambiguousPlace: false,at: time)
    }
    #expect(gate.alignment != nil)
    let result = gate.update(frame: memoryFrame(4,101.1),place: place,transform: t,geometry: [],ambiguousPlace: false,at: 101.1)
    #expect(result == nil && gate.alignment == nil)
}
