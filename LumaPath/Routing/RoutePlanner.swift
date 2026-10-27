import Foundation
import LumaPathDomain

public struct RoutePreferences: Codable, Sendable, Equatable {
    public let avoidStairs: Bool
    public let minimumWidth: Double?
    public let maximumSlope: Double?
    public let avoidVerifiedBarriers: Bool
    public let darknessWeight: Double
    public let surfaceWeight: Double
    public let unknownWeight: Double
    public let crossingCost: Double
    public let barrierCost: Double
    public init(avoidStairs: Bool = false, minimumWidth: Double? = nil, maximumSlope: Double? = nil,
                avoidVerifiedBarriers: Bool = true, darknessWeight: Double = 0.5, surfaceWeight: Double = 0.3,
                unknownWeight: Double = 0.7, crossingCost: Double = 25, barrierCost: Double = 100) throws {
        self.avoidStairs = avoidStairs; self.minimumWidth = minimumWidth; self.maximumSlope = maximumSlope
        self.avoidVerifiedBarriers = avoidVerifiedBarriers; self.darknessWeight = darknessWeight; self.surfaceWeight = surfaceWeight
        self.unknownWeight = unknownWeight; self.crossingCost = crossingCost; self.barrierCost = barrierCost
        try validate()
    }
    public func validate() throws {
        guard minimumWidth.map({ $0.isFinite && (0.3...5).contains($0) }) ?? true,
              maximumSlope.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              [darknessWeight,surfaceWeight,unknownWeight,crossingCost,barrierCost].allSatisfy({ $0.isFinite && (0...1000).contains($0) }) else {
            throw ContractError.invalidValue("routePreferences")
        }
    }
}
public enum CommunityVerification: String, Codable, Sendable { case unverified, verified, disputed, expired, resolved, inactive }
public struct CommunityRouteEvidence: Codable, Sendable, Equatable {
    public let issueID: String
    public let revision: Int
    public let segmentID: String
    public let side: String
    public let level: String
    public let state: CommunityVerification
    public let observedAt: Date
    public let expiresAt: Date
    public let verifiedBarrier: Bool
    public init(issueID: String, revision: Int, segmentID: String, side: String, level: String, state: CommunityVerification,
                observedAt: Date, expiresAt: Date, verifiedBarrier: Bool) {
        self.issueID = issueID; self.revision = revision; self.segmentID = segmentID; self.side = side; self.level = level
        self.state = state; self.observedAt = observedAt; self.expiresAt = expiresAt; self.verifiedBarrier = verifiedBarrier
    }
}
public struct EdgeRouteExplanation: Codable, Sendable {
    public let edgeID: String
    public let equivalentMeterCost: Double
    public let unknownLightingFraction: Double
    public let tokens: [String]
    public let evidenceVersions: [String]
}
public struct PlannedRoute: Codable, Sendable {
    public let objective: String
    public let graphVersion: String
    public let edgeIDs: [String]
    public let nodeIDs: [String]
    public let distanceMeters: Double
    public let equivalentMeterCost: Double
    public let explanations: [EdgeRouteExplanation]
}
public struct RoutePlan: Sendable {
    public let routes: [PlannedRoute]
    public let excludedEdges: [String: [String]]
    public let reason: String?
    public let graphVersion: String
    public let evaluatedAt: Date
}
public enum RoutePlanner {
    private struct Cost { let explanation: EdgeRouteExplanation; let lightingCost: Double }
    public static func plan(graph: PedestrianGraph, from origin: String, to destination: String, preferences: RoutePreferences,
                            community: [CommunityRouteEvidence] = [], at now: Date, allowSynthetic: Bool = false) throws -> RoutePlan {
        try graph.validate(); try preferences.validate()
        guard now.timeIntervalSince1970.isFinite, community.count <= 10_000,
              Set(graph.nodes.map(\.id)).isSuperset(of: [origin,destination]) else { throw ContractError.invalidValue("routeRequest") }
        let grouped = Dictionary(grouping: community,by: \.issueID)
        for (_,variants) in grouped {
            guard variants.allSatisfy({ item in
                !item.issueID.isEmpty && item.issueID.count <= 128 && item.revision > 0
                && item.observedAt.timeIntervalSince1970.isFinite && item.expiresAt.timeIntervalSince1970.isFinite
                && item.expiresAt > item.observedAt && (!item.verifiedBarrier || item.state == .verified)
                && item.segmentID == variants[0].segmentID && item.side == variants[0].side && item.level == variants[0].level
            }) else { throw ContractError.invalidValue("communityEvidence") }
            for version in Dictionary(grouping: variants,by: \.revision).values {
                guard version.allSatisfy({ $0 == version[0] }) else { throw ContractError.invalidValue("conflictingCommunityRevision") }
            }
        }
        if graph.scope == .syntheticFixture && !allowSynthetic { return RoutePlan(routes: [],excludedEdges: [:],reason: "syntheticGraphNotPilotCoverage",graphVersion: graph.version,evaluatedAt: now) }
        if now < graph.publishedAt || now >= graph.expiresAt { return RoutePlan(routes: [],excludedEdges: [:],reason: "graphExpiredOrFuture",graphVersion: graph.version,evaluatedAt: now) }
        var excluded: [String: [String]] = [:], costs: [String: Cost] = [:]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let hour = calendar.component(.hour,from: now)
        for edge in graph.edges {
            var reasons: [String] = []
            if preferences.avoidStairs {
                if let stairs = edge.stairs, stairs.isFresh(at: now) { if stairs.value { reasons.append("knownStairs") } }
                else { reasons.append("stairsUnknownOrStale") }
            }
            if let required = preferences.minimumWidth {
                if let width = edge.width, width.isFresh(at: now) { if width.value-width.uncertainty < required { reasons.append("widthLowerBoundBelowRequired") } }
                else { reasons.append("widthUnknownOrStale") }
            }
            if let maximum = preferences.maximumSlope {
                if let slope = edge.slope, slope.isFresh(at: now) { if slope.value+slope.uncertainty > maximum { reasons.append("slopeUpperBoundAboveMaximum") } }
                else { reasons.append("slopeUnknownOrStale") }
            }
            let evidence = community.filter { $0.segmentID == edge.segmentID && $0.side == edge.side && $0.level == edge.level
                && $0.revision > 0 }
            // One canonical issue contributes once; conflicting revisions use the latest state.
            let issues = Dictionary(grouping: evidence,by: \.issueID).compactMap { _, values in values.max { $0.revision < $1.revision } }
                .filter { $0.observedAt <= now && now < $0.expiresAt }
            if preferences.avoidVerifiedBarriers && issues.contains(where: { $0.state == .verified && $0.verifiedBarrier }) { reasons.append("freshVerifiedBarrier") }
            if !reasons.isEmpty { excluded[edge.id] = reasons; continue }
            var tokens: [String] = [], versions: [String] = []
            let light = edge.lighting.flatMap { $0.isFresh(at: now) && $0.value.applicableUTCHours.contains(hour) ? $0 : nil }
            let unknown = 1-(light?.value.knownFraction ?? 0), darkness = light?.value.darknessPenalty ?? 0
            if unknown > 0 { tokens.append("lightingUnknownFraction:\(unknown)") }
            if let light { tokens.append("lightingObservedAt:\(light.observedAt.timeIntervalSince1970)"); versions.append(light.source) }
            let surface = edge.surfacePenalty.flatMap { $0.isFresh(at: now) ? $0.value : nil }
            if surface == nil { tokens.append("surfaceUnknown") }
            let barrier = issues.reduce(0.0) { total, item in
                switch item.state {
                case .verified: return min(1,total+1)
                case .unverified: return min(1,total+0.1)
                case .disputed,.expired,.resolved,.inactive: return total
                }
            }
            for issue in issues { versions.append("\(issue.issueID):\(issue.revision):\(issue.state.rawValue)") }
            if barrier > 0 { tokens.append("communityCautionNotMeasuredWidth") }
            // UnknownFraction follows the worked specification's lighting coverage measure. Other unknowns are explained separately.
            let cost = edge.lengthMeters*(1+preferences.darknessWeight*darkness+preferences.surfaceWeight*(surface ?? 0)+preferences.unknownWeight*unknown)
                + preferences.crossingCost*Double(edge.crossingCount)+preferences.barrierCost*barrier
            guard cost.isFinite else { throw ContractError.invalidValue("routeCostOverflow") }
            costs[edge.id] = Cost(explanation: EdgeRouteExplanation(edgeID: edge.id,equivalentMeterCost: cost,unknownLightingFraction: unknown,tokens: tokens,evidenceVersions: versions.sorted()),lightingCost: edge.lengthMeters*(1+unknown+0.5*darkness))
        }
        var routes: [PlannedRoute] = []
        for objective in ["profile","shorter","documentedLighting"] {
            guard let route = shortest(graph: graph,from: origin,to: destination,costs: costs,objective: objective) else { continue }
            let edgeSet = Set(route.edgeIDs)
            if routes.contains(where: { prior in
                let priorSet = Set(prior.edgeIDs), union = priorSet.union(edgeSet)
                return union.isEmpty || Double(priorSet.intersection(edgeSet).count)/Double(union.count) >= 0.8
            }) { continue }
            routes.append(route)
        }
        return RoutePlan(routes: routes,excludedEdges: excluded,reason: routes.isEmpty ? "noEligibleConnectionNoConstraintsRelaxed" : nil,graphVersion: graph.version,evaluatedAt: now)
    }
    private static func shortest(graph: PedestrianGraph, from origin: String, to destination: String, costs: [String: Cost], objective: String) -> PlannedRoute? {
        var adjacent: [String: [(String,PedestrianEdge)]] = [:]
        for edge in graph.edges.sorted(by: { $0.id < $1.id }) where costs[edge.id] != nil {
            adjacent[edge.from,default: []].append((edge.to,edge))
            if edge.bidirectional { adjacent[edge.to,default: []].append((edge.from,edge)) }
        }
        var distances = [origin: 0.0], previous: [String: (String,PedestrianEdge)] = [:], visited = Set<String>()
        while let node = distances.keys.filter({ !visited.contains($0) }).min(by: { (distances[$0]!, $0) < (distances[$1]!, $1) }) {
            if node == destination { break }; visited.insert(node)
            for (next,edge) in adjacent[node] ?? [] where !visited.contains(next) {
                let cost = costs[edge.id]!
                let increment = objective == "shorter" ? edge.lengthMeters : objective == "documentedLighting" ? cost.lightingCost : cost.explanation.equivalentMeterCost
                let proposed = distances[node]!+increment
                if proposed < distances[next,default: .infinity] {
                    distances[next] = proposed; previous[next] = (node,edge)
                }
            }
        }
        guard distances[destination] != nil else { return nil }
        var edges: [PedestrianEdge] = [], nodes = [destination], current = destination
        while current != origin {
            guard let (prior,edge) = previous[current] else { return nil }; edges.append(edge); nodes.append(prior); current = prior
        }
        edges.reverse(); nodes.reverse()
        let explanations = edges.map { costs[$0.id]!.explanation }
        return PlannedRoute(objective: objective,graphVersion: graph.version,edgeIDs: edges.map(\.id),nodeIDs: nodes,
            distanceMeters: edges.reduce(0) { $0+$1.lengthMeters },equivalentMeterCost: explanations.reduce(0) { $0+$1.equivalentMeterCost },explanations: explanations)
    }
}
