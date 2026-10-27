import Foundation
import Testing
import LumaPathPersonalization
import LumaPathDomain
import LumaPathPerception
import LumaPathRisk
import LumaPathFeedback

private func temporaryArchive() -> ProfileArchive {
    ProfileArchive(directory: FileManager.default.temporaryDirectory.appendingPathComponent("B4-" + UUID().uuidString))
}
@Test func profilesAndActiveSelectionSurviveNewArchiveInstance() throws {
    let archive = temporaryArchive(); defer { try? FileManager.default.removeItem(at: archive.directory) }
    var first = VisionProfile(name: "Night"); first.preferences.glare = .reducedHighlights
    first.sources[.glare] = .manual; first.preferences.requiredWidth = 0.9
    let second = VisionProfile(name: "Day")
    try archive.save(first); try archive.save(second); try archive.select(first.id)
    let result = try ProfileArchive(directory: archive.directory).load()
    #expect(result.profiles.count == 2 && result.activeID == first.id && result.issues.isEmpty)
    #expect(result.profiles.first { $0.id == first.id } == first)
    var draft = first; draft.preferences.contrast = 1.9
    #expect(try archive.load().profiles.first { $0.id == first.id }?.preferences.contrast == 1)
    try archive.save(draft)
    #expect(try archive.load().profiles.first { $0.id == second.id } == second)
}
@Test func schemaOneMigrationPreservesIdentityTimesAndManualChoices() throws {
    let id = UUID()
    let json = """
    {"schemaVersion":1,"id":"\(id.uuidString)","name":"Legacy","createdAt":10,"updatedAt":20,"exposure":1.5,"contrast":1.25}
    """
    let profile = try ProfileArchive.decode(Data(json.utf8))
    #expect(profile.id == id && profile.schemaVersion == 2 && profile.name == "Legacy")
    #expect(profile.createdAt == Date(timeIntervalSinceReferenceDate: 10) && profile.updatedAt == Date(timeIntervalSinceReferenceDate: 20))
    #expect(profile.preferences.exposure == 1.5 && profile.sources[.contrast] == .manual)
    #expect(profile.sources[.density] == .preset && profile.preferences.density == 3)
    #expect(try ProfileArchive.decode(JSONEncoder().encode(profile)) == profile)
}
@Test func badAndFutureRecordsRemainIntactAndDoNotHideHealthyProfiles() throws {
    let archive = temporaryArchive(); defer { try? FileManager.default.removeItem(at: archive.directory) }
    let healthy = VisionProfile(); try archive.save(healthy); try archive.select(healthy.id)
    let corruptID = UUID(), futureID = UUID()
    let corrupt = archive.directory.appendingPathComponent(corruptID.uuidString + ".json")
    let future = archive.directory.appendingPathComponent(futureID.uuidString + ".json")
    let futureData = Data("{\"schemaVersion\":99}".utf8)
    try Data("broken".utf8).write(to: corrupt); try futureData.write(to: future)
    let result = try archive.load()
    #expect(result.profiles == [healthy] && result.activeID == healthy.id && result.issues.count == 2)
    #expect(throws: ProfileArchiveError.self) { try archive.save(VisionProfile(id: futureID)) }
    #expect(throws: ProfileArchiveError.self) { try archive.save(VisionProfile(id: corruptID)) }
    #expect(try Data(contentsOf: future) == futureData)
    #expect(try String(contentsOf: corrupt, encoding: .utf8) == "broken")
}
@Test func invalidSelectionAndStorageFailureAreErrorsWithoutOverwritingProfile() throws {
    let archive = temporaryArchive(); defer { try? FileManager.default.removeItem(at: archive.directory) }
    let profile = VisionProfile(); try archive.save(profile)
    #expect(throws: ProfileArchiveError.self) { try archive.select(UUID()) }
    try Data("bad selection".utf8).write(to: archive.directory.appendingPathComponent("active.json"))
    #expect(try archive.load().issues.count == 1)
    #expect(try archive.load().profiles == [profile])
    let fileArchive = ProfileArchive(directory: archive.directory.appendingPathComponent(profile.id.uuidString + ".json"))
    #expect(throws: (any Error).self) { try fileArchive.save(VisionProfile()) }
}
@Test func invalidPreferencesVersionsAndOversizeRecordsAreRejected() throws {
    var profile = VisionProfile()
    profile.preferences.glare = .reducedHighlights; profile.preferences.highlights = -2
    #expect(!profile.isValid)
    profile.reset(); profile.preferences.descriptionInterval = 4; #expect(!profile.isValid)
    profile.reset(); profile.preferences.requiredWidth = .infinity; #expect(!profile.isValid)
    profile.reset(); profile.sources.removeValue(forKey: .density); #expect(!profile.isValid)
    profile.reset(); profile.preferences.outlineWidth = .nan; #expect(!profile.isValid)
    #expect(throws: ProfileArchiveError.self) { try ProfileArchive.decode(Data(repeating: 0, count: 65_537)) }
}
@Test func suggestionsRequireAcceptanceAndResetRetainsIdentity() {
    var profile = VisionProfile(name: "Preserve me")
    let suggestion = ExerciseSuggestion.contrast(1.5)
    #expect(profile.preferences.contrast == 1 && profile.exercises[.contrast] == .notStarted)
    profile.exercises[.contrast] = .skipped
    #expect(profile.preferences.contrast == 1 && profile.exercises[.contrast] != .completed)
    profile.accept(suggestion)
    #expect(profile.preferences.contrast == 1.5 && profile.sources[.contrast] == .exerciseSuggested && profile.exercises[.contrast] == .completed)
    let id = profile.id, date = profile.createdAt
    profile.reset()
    #expect(profile.id == id && profile.createdAt == date && profile.name == "Preserve me")
    #expect(profile.preferences == ProfilePreferences() && profile.sources.values.allSatisfy { $0 == .preset })
    #expect(profile.exercises.values.allSatisfy { $0 == .notStarted })
}

private struct FixedProfileClock: MonotonicClock { func now() -> TimeInterval { 100 } }
@MainActor private final class ProfileSink: FeedbackOutputSink {
    let capabilities = OutputCapabilities(speech: true, haptics: true)
    var onCompletion: (@MainActor (UUID) -> Void)?
    var starts: [FeedbackItem] = []
    func play(_ item: FeedbackItem, channels: OutputChannels) -> Bool { starts.append(item); return true }
    func cancel(reason: String) {}
}
@MainActor @Test func densityFocusAndImagePreferencesCannotSuppressDarkDepthHazard() async throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .demoReplay)
    let depth = try GeometryFixture.load()[2].image(context: context, sequence: 1, at: 100)
    let dark = try LumaImage(frame: depth.frame, size: PixelSize(width: 12, height: 9), values: [UInt8](repeating: 0, count: 108))
    let pipeline = GeometryPipeline(clock: FixedProfileClock()); pipeline.start(context: context)
    let snapshot = try #require(try await pipeline.process(depth, image: dark))
    #expect(snapshot.geometry.quality.reasons.contains("darkImage"))
    let events = snapshot.events
    #expect(events.contains { $0.urgency == .urgent })
    for focus in ProfileFocus.allCases {
        var prefs = ProfilePreferences(); prefs.focus = focus; prefs.density = 1; prefs.exposure = 2; prefs.glare = .reducedHighlights
        let visible = ProfilePresentation.prioritize(snapshot.geometry.observations, events: events).prefix(prefs.density)
        #expect(!visible.isEmpty && snapshot.events == events)
        #expect(visible.contains { observation in events.contains { $0.urgency == .urgent && $0.geometryIDs.contains(observation.id) } })
    }
    let sink = ProfileSink(), coordinator = FeedbackCoordinator(sink: ProfileSink(), clock: FixedProfileClock())
    let output = FeedbackCoordinator(sink: sink, clock: FixedProfileClock())
    output.start(context: context, allowResearch: true); output.setChannels(OutputChannels(speech: true))
    output.setDescriptionInterval(30); output.consume(pipeline.ledger)
    #expect(sink.starts.first?.kind == .urgent && pipeline.ledger.pending(at: 100).isEmpty)
    let current = output.current?.id
    output.setDescriptionInterval(5)
    #expect(output.current?.id == current)
    coordinator.setDescriptionInterval(.nan); #expect(coordinator.descriptionInterval == 10)
}
@MainActor @Test func sparseDepthRemainsLimitedAcrossPresentationChoices() async throws {
    let context = CaptureContext(sessionID: UUID(), generation: 1, mode: .demoReplay)
    let template = try GeometryFixture.load()[0].image(context: context, sequence: 1, at: 100)
    var samples = [Float](repeating: .nan, count: template.values.count)
    for i in 0..<128 { samples[i] = 0.8 }
    let depth = try DepthImage(frame: template.frame, values: samples, confidence: [UInt8](repeating: 2, count: samples.count))
    let pipeline = GeometryPipeline(clock: FixedProfileClock()); pipeline.start(context: context)
    let snapshot = try #require(try await pipeline.process(depth))
    #expect(snapshot.geometry.quality.state != .active)
    #expect(snapshot.geometry.quality.reasons.contains("partialDepthCoverage"))
    _ = ProfilePresentation.prioritize(snapshot.geometry.observations, events: snapshot.events)
    #expect(snapshot.geometry.quality.details?.regions.contains { $0.coverage == .unknown || $0.coverage == .sparse } == true)
}
