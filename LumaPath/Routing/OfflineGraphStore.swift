import Foundation
import LumaPathDomain

/// Atomic versioned graph import. Offline reads preserve every original observation/expiry timestamp.
public actor OfflineGraphStore {
    private let file: URL
    public init(file: URL) throws {
        guard file.isFileURL else { throw ContractError.invalidValue("graphFileURL") }; self.file = file
    }
    @discardableResult public func importGraph(_ data: Data, replacingVersion expected: String? = nil) throws -> PedestrianGraph {
        guard !data.isEmpty, data.count <= 8_000_000 else { throw ContractError.invalidValue("graphFileBudget") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let graph = try decoder.decode(PedestrianGraph.self,from: data); try graph.validate()
        if FileManager.default.fileExists(atPath: file.path) {
            let prior = try load()
            guard expected == prior.version, graph.version != prior.version else { throw ContractError.invalidValue("graphVersionConflict") }
        } else if expected != nil { throw ContractError.invalidValue("graphVersionMissing") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),withIntermediateDirectories: true)
        try data.write(to: file,options: .atomic); return graph
    }
    public func load() throws -> PedestrianGraph {
        let values = try file.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 8_000_000 else { throw ContractError.invalidValue("graphFileBudgetOrType") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let graph = try decoder.decode(PedestrianGraph.self,from: Data(contentsOf: file)); try graph.validate(); return graph
    }
    public func delete() throws { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
}
