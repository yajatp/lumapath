import Foundation
import LumaPathDomain

public struct SurveyAttribute<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let value: Value
    public let observedAt: Date
    public let expiresAt: Date
    public let source: String
    public let uncertainty: Double
    public init(value: Value, observedAt: Date, expiresAt: Date, source: String, uncertainty: Double = 0) {
        self.value = value; self.observedAt = observedAt; self.expiresAt = expiresAt; self.source = source; self.uncertainty = uncertainty
    }
    public func isFresh(at now: Date) -> Bool { observedAt <= now && now < expiresAt }
    public func validate() throws {
        guard observedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > observedAt, !source.isEmpty, source.count <= 256, uncertainty.isFinite, uncertainty >= 0 else {
            throw ContractError.invalidValue("surveyAttribute")
        }
    }
}
public struct LightingEvidence: Codable, Sendable, Equatable {
    public let knownFraction: Double
    public let darknessPenalty: Double
    /// Applicability is explicit; an observation outside its time window is unknown.
    public let applicableUTCHours: [Int]
    public init(knownFraction: Double, darknessPenalty: Double, applicableUTCHours: [Int]) {
        self.knownFraction = knownFraction; self.darknessPenalty = darknessPenalty; self.applicableUTCHours = applicableUTCHours
    }
}
public struct RouteCoordinate: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    public var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}
public struct PedestrianNode: Codable, Sendable, Equatable {
    public let id: String
    public let coordinate: RouteCoordinate
    public init(id: String, coordinate: RouteCoordinate) { self.id = id; self.coordinate = coordinate }
}
public struct PedestrianEdge: Codable, Sendable, Equatable {
    public let id: String
    public let from: String
    public let to: String
    public let bidirectional: Bool
    public let segmentID: String
    public let side: String
    public let level: String
    public let geometry: [RouteCoordinate]
    public let lengthMeters: Double
    public let crossingCount: Int
    public let width: SurveyAttribute<Double>?
    public let stairs: SurveyAttribute<Bool>?
    public let slope: SurveyAttribute<Double>?
    public let surfacePenalty: SurveyAttribute<Double>?
    public let lighting: SurveyAttribute<LightingEvidence>?
    public init(id: String, from: String, to: String, bidirectional: Bool = true, segmentID: String, side: String, level: String,
                geometry: [RouteCoordinate], lengthMeters: Double, crossingCount: Int = 0,
                width: SurveyAttribute<Double>? = nil, stairs: SurveyAttribute<Bool>? = nil,
                slope: SurveyAttribute<Double>? = nil, surfacePenalty: SurveyAttribute<Double>? = nil,
                lighting: SurveyAttribute<LightingEvidence>? = nil) {
        self.id = id; self.from = from; self.to = to; self.bidirectional = bidirectional; self.segmentID = segmentID
        self.side = side; self.level = level; self.geometry = geometry; self.lengthMeters = lengthMeters; self.crossingCount = crossingCount
        self.width = width; self.stairs = stairs; self.slope = slope; self.surfacePenalty = surfacePenalty; self.lighting = lighting
    }
}
public enum PedestrianGraphScope: String, Codable, Sendable { case syntheticFixture, surveyedPilot }
public struct PedestrianGraph: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public let version: String
    public let scope: PedestrianGraphScope
    public let source: String
    public let license: String
    public let attribution: String
    public let surveyedBy: String
    public let publishedAt: Date
    public let expiresAt: Date
    public let nodes: [PedestrianNode]
    public let edges: [PedestrianEdge]
    public init(version: String, scope: PedestrianGraphScope, source: String, license: String, attribution: String, surveyedBy: String,
                publishedAt: Date, expiresAt: Date, nodes: [PedestrianNode], edges: [PedestrianEdge]) {
        self.version = version; self.scope = scope; self.source = source; self.license = license; self.attribution = attribution
        self.surveyedBy = surveyedBy; self.publishedAt = publishedAt; self.expiresAt = expiresAt; self.nodes = nodes; self.edges = edges
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ContractError.unsupportedSchema(schemaVersion) }
        let ids = Set(nodes.map(\.id))
        guard [version,source,license,attribution,surveyedBy].allSatisfy({ !$0.isEmpty && $0.count <= 1024 }),
              publishedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite, expiresAt > publishedAt,
              !nodes.isEmpty, nodes.count <= 5000, edges.count <= 20_000, ids.count == nodes.count,
              nodes.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 128 && $0.coordinate.isValid }),
              Set(edges.map(\.id)).count == edges.count else { throw ContractError.invalidValue("pedestrianGraph") }
        for edge in edges {
            guard [edge.id,edge.segmentID,edge.side,edge.level].allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
                  ids.contains(edge.from), ids.contains(edge.to), edge.from != edge.to,
                  edge.geometry.count >= 2, edge.geometry.count <= 1024, edge.geometry.allSatisfy(\.isValid),
                  edge.lengthMeters.isFinite, edge.lengthMeters > 0, edge.lengthMeters <= 100_000,
                  (0...100).contains(edge.crossingCount) else { throw ContractError.invalidValue("pedestrianEdge") }
            try edge.width?.validate(); try edge.stairs?.validate(); try edge.slope?.validate(); try edge.surfacePenalty?.validate(); try edge.lighting?.validate()
            guard edge.width.map({ $0.value.isFinite && $0.value > 0 && $0.value <= 100 }) ?? true,
                  edge.slope.map({ $0.value.isFinite && (0...1).contains($0.value) }) ?? true,
                  edge.surfacePenalty.map({ $0.value.isFinite && (0...1).contains($0.value) }) ?? true,
                  edge.lighting.map({ light in
                      light.value.knownFraction.isFinite && (0...1).contains(light.value.knownFraction)
                      && light.value.darknessPenalty.isFinite && (0...1).contains(light.value.darknessPenalty)
                      && !light.value.applicableUTCHours.isEmpty && light.value.applicableUTCHours.allSatisfy { (0...23).contains($0) }
                  }) ?? true else { throw ContractError.invalidValue("pedestrianAttributeValue") }
        }
    }
}
