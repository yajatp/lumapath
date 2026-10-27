import Foundation
import LumaPathDomain

public struct PlaceMatchResult: Sendable {
    public let matches: [LandmarkMatch]
    public let ambiguous: Bool
}
/// Bounded association of saved geometric feature centers to current independently observed feature centers.
/// Inputs must be features extracted from current geometry, never loaded/predicted AR map anchors.
/// Spatial agreement is a hypothesis, not proof of room identity; callers must also supply ambiguity evidence.
public enum PlaceGeometryMatcher {
    public static func match(place: PlaceArchive, transform: PlaceTransform, currentPositions: [SIMD3<Double>]) -> PlaceMatchResult {
        guard (try? place.validate()) != nil, (try? transform.validate()) != nil,
              transform.savedFrameID == place.coordinateFrameID, currentPositions.count >= 3, currentPositions.count <= 512,
              currentPositions.allSatisfy(validPosition) else { return PlaceMatchResult(matches: [],ambiguous: true) }
        var matches: [LandmarkMatch] = [], used = Set<Int>(), ambiguous = false
        for saved in place.landmarks {
            let predicted = transform.apply(saved.position)
            let ranked = currentPositions.enumerated().map { ($0.offset,distance(predicted,$0.element)) }.sorted { $0.1 < $1.1 }
            guard let nearest = ranked.first, nearest.1 <= 0.15 else { continue }
            // Multiple similarly plausible surfaces or a reused feature cannot establish an identity.
            guard ranked.count < 2 || ranked[1].1-nearest.1 > 0.10, used.insert(nearest.0).inserted else {
                ambiguous = true; continue
            }
            matches.append(LandmarkMatch(landmarkID: saved.id,currentPosition: currentPositions[nearest.0]))
        }
        return PlaceMatchResult(matches: matches,ambiguous: ambiguous || matches.count < 3)
    }
}
