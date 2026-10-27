import Foundation
import Testing
@testable import LumaPathDomain

private struct ConsumerClock: MonotonicClock {
    let time: TimeInterval
    func now() -> TimeInterval { time }
}

@MainActor @Test func replayTransportReachesConsumerAndTraversesFailureStates() async throws {
    let service = try ReplayShellService(clock: ConsumerClock(time: 100))
    var shell = ShellState()
    shell.bind(to: service.snapshot.context)
    #expect(shell.receive(service.snapshot, at: 100) == true)
    #expect(shell.allows(.startDemo))
    #expect(!shell.allows(.pause))
    var stream = service.snapshots.makeAsyncIterator()
    service.perform(.startDemo)
    shell.bind(to: service.snapshot.context)
    let first = try #require(await stream.next())
    #expect(shell.receive(first, at: 100) == true)
    #expect(shell.snapshot?.events.count == 1)
    #expect(shell.snapshot?.context.mode == .demoReplay)
    service.perform(.nextFixture)
    let limited = try #require(await stream.next())
    #expect(shell.receive(limited, at: 100) == true)
    #expect(shell.snapshot?.quality.state == .limited)
    #expect(shell.snapshot?.events.count == 1)
    service.perform(.nextFixture)
    shell.bind(to: service.snapshot.context)
    let paused = try #require(await stream.next())
    #expect(shell.receive(paused, at: 100) == true)
    #expect(shell.snapshot?.lifecycle == .paused)
    #expect(shell.snapshot?.events.isEmpty == true)
    #expect(shell.receive(first, at: 100) == false)
    service.perform(.resume)
    shell.bind(to: service.snapshot.context)
    let unavailable = try #require(await stream.next())
    #expect(shell.receive(unavailable, at: 100) == true)
    #expect(shell.snapshot?.quality.state == .unavailable)
    #expect(shell.snapshot?.frame == nil)
    #expect(shell.allows(.pause))
    service.perform(.end)
    shell.bind(to: service.snapshot.context)
    let ended = try #require(await stream.next())
    #expect(shell.receive(ended, at: 100) == true)
    #expect(shell.allows(.startDemo))
    #expect(!shell.isSessionOpen)
}

@MainActor @Test func consumerExpiryAndPauseCannotResurrectBufferedScene() throws {
    let service = try ReplayShellService(clock: ConsumerClock(time: 100))
    service.perform(.startDemo)
    let first = service.snapshot
    var shell = ShellState()
    shell.bind(to: first.context)
    #expect(shell.receive(first, at: 100) == true)
    shell.expire(at: 100.3)
    #expect(shell.snapshot?.frame == nil)
    #expect(shell.snapshot?.geometry.isEmpty == true)
    #expect(shell.snapshot?.events.isEmpty == true)
    #expect(shell.snapshot?.quality.state == .unavailable)
    #expect(shell.receive(first, at: 100.3) == false)
    // Even a consumer clock rollback cannot revive a cleared frame sequence.
    #expect(shell.receive(first, at: 100.1) == false)
    service.perform(.pause)
    shell.bind(to: service.snapshot.context)
    #expect(shell.receive(service.snapshot, at: 100.1) == true)
    #expect(shell.receive(first, at: 100.1) == false)
    #expect(shell.snapshot?.lifecycle == .paused)
    #expect(shell.allows(.resume))
    #expect(!shell.allows(.nextFixture))
}

@MainActor @Test func endingAndRestartingRejectsPreviousSession() throws {
    let service = try ReplayShellService(clock: ConsumerClock(time: 100))
    service.perform(.startDemo)
    let first = service.snapshot
    service.perform(.end)
    service.perform(.startDemo)
    var shell = ShellState()
    shell.bind(to: service.snapshot.context)
    #expect(shell.receive(service.snapshot, at: 100) == true)
    #expect(shell.context?.sessionID != first.context.sessionID)
    #expect(shell.receive(first, at: 100) == false)
    let newLaunch = ShellState()
    #expect(newLaunch.snapshot == nil)
    #expect(newLaunch.profileRevision == 0)
}

@MainActor @Test func profileAndNavigationDoNotChangeHazardEvidence() throws {
    let service = try ReplayShellService(clock: ConsumerClock(time: 100))
    service.perform(.startDemo)
    var shell = ShellState()
    shell.bind(to: service.snapshot.context)
    #expect(shell.receive(service.snapshot, at: 100) == true)
    let before = shell.snapshot
    var preferences = PresentationPreferences()
    preferences.focus = .centralSummary
    preferences.speechDetail = .descriptive
    shell.apply(preferences)
    shell.tab = .routes
    #expect(shell.profileRevision == 1)
    #expect(shell.snapshot == before)
    #expect(shell.isSessionOpen)
    shell.apply(preferences)
    #expect(shell.profileRevision == 1)
    shell.apply(PresentationPreferences())
    #expect(shell.profileRevision == 2)
    #expect(shell.snapshot == before)
}

@MainActor @Test func rendererBoundaryRejectsMismatchedExpiredAndPausedFrames() throws {
    let service = try ReplayShellService(clock: ConsumerClock(time: 100))
    service.perform(.startDemo)
    let snapshot = service.snapshot
    let frame = try #require(snapshot.frame)
    #expect(RendererRequest(snapshot: snapshot, displayedFrame: frame,
                            orientation: frame.orientation, viewport: frame.viewportSize, at: 100)?.geometry.count == 1)
    #expect(RendererRequest(snapshot: snapshot, displayedFrame: frame,
                            orientation: frame.orientation, viewport: frame.viewportSize, at: 100.3) == nil)
    #expect(RendererRequest(snapshot: snapshot, displayedFrame: frame,
                            orientation: .portraitUpsideDown, viewport: frame.viewportSize, at: 100) == nil)
    #expect(RendererRequest(snapshot: snapshot, displayedFrame: frame,
                            orientation: frame.orientation, viewport: PixelSize(width: 1, height: 1), at: 100) == nil)
    service.perform(.nextFixture)
    #expect(RendererRequest(snapshot: service.snapshot, displayedFrame: frame,
                            orientation: frame.orientation, viewport: frame.viewportSize, at: 100) == nil)
    service.perform(.pause)
    #expect(RendererRequest(snapshot: service.snapshot, displayedFrame: frame,
                            orientation: frame.orientation, viewport: frame.viewportSize, at: 100) == nil)
}

@MainActor @Test func oldSequencesCannotOverwriteNewerConsumerEvidence() throws {
    let service = try ReplayShellService(clock: ConsumerClock(time: 100))
    service.perform(.startDemo)
    let first = service.snapshot
    service.perform(.nextFixture)
    var shell = ShellState()
    shell.bind(to: service.snapshot.context)
    #expect(shell.receive(service.snapshot, at: 100) == true)
    #expect(shell.receive(first, at: 100) == false)
    #expect(shell.snapshot?.quality.state == .limited)
}
