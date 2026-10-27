import Foundation
import Testing
import LumaPathDomain
import LumaPathRouting

private let routeNow = Date(timeIntervalSince1970: 1_000_000)
private func attribute<T>(_ value: T, uncertainty: Double = 0, expired: Bool = false) -> SurveyAttribute<T> {
    SurveyAttribute(value: value,observedAt: routeNow.addingTimeInterval(-100),expiresAt: routeNow.addingTimeInterval(expired ? -1 : 1000),source: "synthetic-survey-v1",uncertainty: uncertainty)
}
private func edge(_ id: String, _ from: String, _ to: String, _ meters: Double, knownLighting: Double,
                  width: SurveyAttribute<Double>? = nil, stairs: SurveyAttribute<Bool>? = nil) -> PedestrianEdge {
    PedestrianEdge(id: id,from: from,to: to,segmentID: id,side: "north",level: "ground",
        geometry: [RouteCoordinate(latitude: 0,longitude: 0),RouteCoordinate(latitude: 0,longitude: 0.001)],lengthMeters: meters,
        width: width,stairs: stairs,surfacePenalty: attribute(0),lighting: attribute(LightingEvidence(knownFraction: knownLighting,darknessPenalty: 0,applicableUTCHours: Array(0...23))))
}
private func routeGraph(_ edges: [PedestrianEdge]) -> PedestrianGraph {
    PedestrianGraph(version: "synthetic-1",scope: .syntheticFixture,source: "analytic fixture; no pilot data",license: "CC0 synthetic fixture",
        attribution: "LumaPath generated test geometry",surveyedBy: "not a physical survey",publishedAt: routeNow.addingTimeInterval(-1000),expiresAt: routeNow.addingTimeInterval(10_000),
        nodes: ["a","b","c","d","isolated"].map { PedestrianNode(id: $0,coordinate: RouteCoordinate(latitude: 0,longitude: 0)) },edges: edges)
}
@Test func workedExampleRanks460MeterRouteBefore400WithoutMislabelingEquivalentCost() throws {
    let graph = routeGraph([edge("short","a","d",400,knownLighting: 0.4),edge("documented","a","d",460,knownLighting: 0.9)])
    let plan = try RoutePlanner.plan(graph: graph,from: "a",to: "d",preferences: RoutePreferences(),at: routeNow,allowSynthetic: true)
    #expect(plan.routes.count == 2)
    #expect(plan.routes[0].distanceMeters == 460)
    #expect(abs(plan.routes[0].equivalentMeterCost-492.2) < 1e-8)
    #expect(plan.routes[1].distanceMeters == 400 && abs(plan.routes[1].equivalentMeterCost-568) < 1e-8)
    #expect(plan.routes[0].explanations[0].tokens.contains { $0.hasPrefix("lightingObservedAt:") })
}
@Test func hardConstraintsRejectUnknownAndUncertainAttributesWithoutRelaxing() throws {
    let graph = routeGraph([edge("unknown","a","d",10,knownLighting: 1),
        edge("narrow","a","d",20,knownLighting: 1,width: attribute(0.9,uncertainty: 0.2),stairs: attribute(false)),
        edge("stairs","a","d",30,knownLighting: 1,width: attribute(1.2),stairs: attribute(true)),
        edge("stale","a","d",40,knownLighting: 1,width: attribute(1.2,expired: true),stairs: attribute(false)),
        edge("eligible","a","d",50,knownLighting: 1,width: attribute(1.2,uncertainty: 0.1),stairs: attribute(false))])
    let plan = try RoutePlanner.plan(graph: graph,from: "a",to: "d",preferences: RoutePreferences(avoidStairs: true,minimumWidth: 0.9),at: routeNow,allowSynthetic: true)
    #expect(plan.routes.count == 1 && plan.routes[0].edgeIDs == ["eligible"])
    #expect(plan.excludedEdges["unknown"]?.contains("stairsUnknownOrStale") == true)
    #expect(plan.excludedEdges["narrow"] == ["widthLowerBoundBelowRequired"])
    #expect(plan.excludedEdges["stairs"] == ["knownStairs"])
    #expect(plan.excludedEdges["stale"] == ["widthUnknownOrStale"])
}
@Test func disconnectedAndSyntheticGraphsNeverPretendToOfferPilotCoverage() throws {
    let graph = routeGraph([edge("ab","a","b",5,knownLighting: 1)])
    let disconnected = try RoutePlanner.plan(graph: graph,from: "a",to: "isolated",preferences: RoutePreferences(),at: routeNow,allowSynthetic: true)
    #expect(disconnected.routes.isEmpty && disconnected.reason == "noEligibleConnectionNoConstraintsRelaxed")
    let unsupported = try RoutePlanner.plan(graph: graph,from: "a",to: "b",preferences: RoutePreferences(),at: routeNow)
    #expect(unsupported.reason == "syntheticGraphNotPilotCoverage")
    let stale = try RoutePlanner.plan(graph: graph,from: "a",to: "b",preferences: RoutePreferences(),at: routeNow.addingTimeInterval(10_000),allowSynthetic: true)
    #expect(stale.reason == "graphExpiredOrFuture")
}
@Test func directedEdgesTieBreakAndAlternativesAreDeterministic() throws {
    let graph = routeGraph([edge("ab","a","b",5,knownLighting: 1),edge("bd","b","d",5,knownLighting: 1),edge("ac","a","c",5,knownLighting: 1),edge("cd","c","d",5,knownLighting: 1)])
    let first = try RoutePlanner.plan(graph: graph,from: "a",to: "d",preferences: RoutePreferences(),at: routeNow,allowSynthetic: true)
    #expect(first.routes.count == 1 && first.routes[0].edgeIDs == ["ab","bd"])
    let reversed = routeGraph(Array(graph.edges.reversed()))
    let second = try RoutePlanner.plan(graph: reversed,from: "a",to: "d",preferences: RoutePreferences(),at: routeNow,allowSynthetic: true)
    #expect(second.routes[0].edgeIDs == first.routes[0].edgeIDs)
}
@Test func communityLatestRevisionSideAndExpiryControlInfluence() throws {
    let graph = routeGraph([edge("street","a","d",50,knownLighting: 1)])
    func issue(_ revision: Int, _ state: CommunityVerification, side: String = "north", expired: Bool = false) -> CommunityRouteEvidence {
        CommunityRouteEvidence(issueID: "issue",revision: revision,segmentID: "street",side: side,level: "ground",state: state,
            observedAt: routeNow.addingTimeInterval(-10),expiresAt: routeNow.addingTimeInterval(expired ? -1 : 100),verifiedBarrier: state == .verified)
    }
    let blocked = try RoutePlanner.plan(graph: graph,from: "a",to: "d",preferences: RoutePreferences(),community: [issue(1,.verified)],at: routeNow,allowSynthetic: true)
    #expect(blocked.routes.isEmpty)
    for evidence in [[issue(1,.verified),issue(2,.disputed)],[issue(1,.verified),issue(2,.expired,expired: true)],[issue(1,.verified,side: "south")]] {
        let plan = try RoutePlanner.plan(graph: graph,from: "a",to: "d",preferences: RoutePreferences(),community: evidence,at: routeNow,allowSynthetic: true)
        #expect(plan.routes.count == 1 && plan.routes[0].equivalentMeterCost == 50)
    }
}
@Test func offlineGraphImportPreservesEvidenceAgeAndRejectsCorruptionAndRevisionConflict() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let graph = routeGraph([edge("street","a","d",50,knownLighting: 1)]), store = try OfflineGraphStore(file: file)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(graph)
    let imported = try await store.importGraph(data)
    let loaded = try await store.load()
    #expect(imported == graph && loaded.edges[0].lighting?.observedAt == graph.edges[0].lighting?.observedAt)
    do { _ = try await store.importGraph(data); Issue.record("Accepted stale graph replacement") } catch {}
    try Data("bad".utf8).write(to: file)
    do { _ = try await store.load(); Issue.record("Accepted corrupted graph") } catch {}
}
@Test func invalidNonnegativeWeightsAndGraphReferencesFailBeforePlanning() throws {
    #expect(throws: ContractError.self) { try RoutePreferences(unknownWeight: -1) }
    let graph = routeGraph([edge("bad","missing","d",10,knownLighting: 1)])
    #expect(throws: ContractError.self) { try graph.validate() }
}

private func serverFeedData() throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: "community-feed",withExtension: "json",subdirectory: "Fixtures")))
}
private func changedFeed(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
    var value = try #require(JSONSerialization.jsonObject(with: serverFeedData()) as? [String: Any])
    mutate(&value); return try JSONSerialization.data(withJSONObject: value)
}
@Test func actualServerEvidenceProjectionBlocksOnlyItsFreshVerifiedSegment() throws {
    let feed = try CommunityEvidenceFeed.decode(serverFeedData(),at: routeNow)
    let graph = routeGraph([edge("pilot-1","a","d",50,knownLighting: 1)])
    let routed = try feed.plan(graph: graph,from: "a",to: "d",preferences: RoutePreferences(),at: routeNow,allowSynthetic: true)
    #expect(routed.plan.routes.isEmpty && routed.evidenceVersion == feed.version)
    #expect(routed.plan.excludedEdges["pilot-1"] == ["freshVerifiedBarrier"])
    #expect(throws: ContractError.self) { try feed.validate(at: routeNow.addingTimeInterval(300)) }
}
@Test func disputedSnapshotDowngradesInfluenceAndRejectsOlderCachedVersion() throws {
    let initial = try CommunityEvidenceFeed.decode(serverFeedData(),at: routeNow)
    let changed = try changedFeed { value in
        value["version"] = initial.version+1
        var issues = value["issues"] as! [[String: Any]]
        issues[0]["state"] = "disputed"; issues[0]["verifiedBarrier"] = false; issues[0]["revision"] = 20
        value["issues"] = issues
    }
    let newer = try CommunityEvidenceFeed.decode(changed,at: routeNow,minimumVersion: initial.version)
    let graph = routeGraph([edge("pilot-1","a","d",50,knownLighting: 1)])
    let result = try newer.plan(graph: graph,from: "a",to: "d",preferences: RoutePreferences(),at: routeNow,allowSynthetic: true)
    #expect(result.plan.routes.first?.equivalentMeterCost == 50)
    #expect(throws: ContractError.self) { try CommunityEvidenceFeed.decode(serverFeedData(),at: routeNow,minimumVersion: newer.version) }
}
@Test func incompleteFilteredFutureAndDuplicateIssueFeedsFailClosed() throws {
    let mutations: [(inout [String: Any]) -> Void] = [
        { $0["complete"] = false }, { $0["coverage"] = "filtered" }, { $0["generatedAt"] = 1_000_001 },
        { $0["validUntil"] = 1_000_301 }, { value in
            var issues = value["issues"] as! [[String: Any]]; issues.append(issues[0]); value["issues"] = issues
        }
    ]
    for mutation in mutations {
        let data = try changedFeed(mutation)
        #expect(throws: ContractError.self) { try CommunityEvidenceFeed.decode(data,at: routeNow) }
    }
}
@Test func conflictingSameRevisionAndChangedSegmentIdentityAreRejectedBeforePlanning() throws {
    let feed = try CommunityEvidenceFeed.decode(serverFeedData(),at: routeNow), first = feed.issues[0]
    let conflict = CommunityRouteEvidence(issueID: first.issueID,revision: first.revision,segmentID: first.segmentID,side: first.side,level: first.level,
        state: .disputed,observedAt: first.observedAt,expiresAt: first.expiresAt,verifiedBarrier: false)
    let graph = routeGraph([edge("pilot-1","a","d",50,knownLighting: 1)])
    #expect(throws: ContractError.self) { try RoutePlanner.plan(graph: graph,from: "a",to: "d",preferences: RoutePreferences(),community: [first,conflict],at: routeNow,allowSynthetic: true) }
    let otherSide = CommunityRouteEvidence(issueID: first.issueID,revision: first.revision+1,segmentID: first.segmentID,side: "south",level: first.level,
        state: .verified,observedAt: first.observedAt,expiresAt: first.expiresAt,verifiedBarrier: true)
    #expect(throws: ContractError.self) { try RoutePlanner.plan(graph: graph,from: "a",to: "d",preferences: RoutePreferences(),community: [first,otherSide],at: routeNow,allowSynthetic: true) }
}
