import Foundation
import LumaPathDomain

/// Exact immutable server projection used by a route; numeric dates are UTC Unix seconds on the wire.
public struct CommunityEvidenceFeed: Codable, Sendable {
    public let schemaVersion: Int
    public let version: Int
    public let generatedAt: Date
    public let validUntil: Date
    public let complete: Bool
    public let coverage: String
    public let issues: [CommunityRouteEvidence]
    public static func decode(_ data: Data, at now: Date, minimumVersion: Int = 0) throws -> CommunityEvidenceFeed {
        guard !data.isEmpty, data.count <= 1_000_000 else { throw ContractError.invalidValue("communityFeedBudget") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let feed = try decoder.decode(Self.self,from: data)
        try feed.validate(at: now,minimumVersion: minimumVersion); return feed
    }
    public func validate(at now: Date, minimumVersion: Int = 0) throws {
        guard schemaVersion == 1, version >= max(1,minimumVersion), complete, coverage == "allPublicIssues",
              now.timeIntervalSince1970.isFinite, generatedAt.timeIntervalSince1970.isFinite,
              validUntil.timeIntervalSince1970.isFinite, generatedAt <= now, now < validUntil,
              validUntil > generatedAt, validUntil.timeIntervalSince(generatedAt) <= 300,
              issues.count <= 100, Set(issues.map(\.issueID)).count == issues.count else { throw ContractError.invalidValue("communityFeedVersionFreshnessOrCoverage") }
        for issue in issues {
            guard [issue.issueID,issue.segmentID,issue.side,issue.level].allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
                  issue.revision > 0, issue.observedAt.timeIntervalSince1970.isFinite, issue.expiresAt.timeIntervalSince1970.isFinite,
                  issue.observedAt <= generatedAt, issue.expiresAt > issue.observedAt,
                  !issue.verifiedBarrier || issue.state == .verified else { throw ContractError.invalidValue("communityIssueEvidence") }
        }
    }
    public func plan(graph: PedestrianGraph, from: String, to: String, preferences: RoutePreferences,
                     at now: Date, allowSynthetic: Bool = false) throws -> CommunityRoutePlan {
        try validate(at: now)
        let result = try RoutePlanner.plan(graph: graph,from: from,to: to,preferences: preferences,community: issues,at: now,allowSynthetic: allowSynthetic)
        return CommunityRoutePlan(plan: result,evidenceVersion: version,evidenceGeneratedAt: generatedAt,evidenceValidUntil: validUntil)
    }
}
public struct CommunityRoutePlan: Sendable {
    public let plan: RoutePlan
    public let evidenceVersion: Int
    public let evidenceGeneratedAt: Date
    public let evidenceValidUntil: Date
}
