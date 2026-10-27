import Foundation
import LumaPathDomain

public enum ProfilePresentation {
    /// Order visual regions by producer urgency, then range. No event filtering or acknowledgement here.
    public static func prioritize(_ observations: [GeometryObservation], events: [HazardEvent]) -> [GeometryObservation] {
        var priority: [UUID: Int] = [:]
        for event in events {
            let rank = event.urgency == .urgent ? 3 : event.urgency == .warning ? 2 : 1
            for id in event.geometryIDs { priority[id] = max(priority[id] ?? 0, rank) }
        }
        return observations.sorted {
            let a = priority[$0.id] ?? 0, b = priority[$1.id] ?? 0
            if a != b { return a > b }
            if $0.rangeMeters != $1.rangeMeters { return $0.rangeMeters < $1.rangeMeters }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
