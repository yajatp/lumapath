#if os(iOS)
import ARKit
import Foundation
import LumaPathDomain

/// ARWorldMap uses secure keyed coding. JSON place decoding never instantiates arbitrary archived classes.
@MainActor public enum WorldMapArchive {
    nonisolated public static func encode(_ map: ARWorldMap) throws -> Data {
        let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
        guard data.count <= 8_388_608 else { throw ContractError.invalidValue("worldMapBudget") }
        return data
    }
    public static func decode(_ data: Data) throws -> ARWorldMap {
        guard !data.isEmpty, data.count <= 8_388_608 else { throw ContractError.invalidValue("worldMapBudget") }
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
        decoder.requiresSecureCoding = true
        decoder.decodingFailurePolicy = .setErrorAndReturn
        defer { decoder.finishDecoding() }
        guard let map = decoder.decodeObject(of: ARWorldMap.self, forKey: NSKeyedArchiveRootObjectKey), decoder.error == nil else {
            throw ContractError.invalidValue("worldMapSecureDecode")
        }
        return map
    }
}
#endif
