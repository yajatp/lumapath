import Foundation
import LumaPathRouting

@main struct RouteTool {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 2 else { throw ToolError.usage }
            let file = URL(fileURLWithPath: args[1])
            switch args[0] {
            case "validate":
                let graph = try await OfflineGraphStore(file: file).load()
                print("Valid schema-1 graph: \(graph.version), \(graph.scope.rawValue), \(graph.nodes.count) nodes, \(graph.edges.count) edges. Not a field-validation result.")
            case "import":
                guard args.count == 3 || args.count == 5 && args[3] == "--replace" else { throw ToolError.usage }
                let data = try Data(contentsOf: file)
                let store = try OfflineGraphStore(file: URL(fileURLWithPath: args[2]))
                let graph = try await store.importGraph(data,replacingVersion: args.count == 5 ? args[4] : nil)
                print("Imported \(graph.version); original evidence timestamps retained.")
            case "plan":
                guard args.count == 4 || args.count == 5 && args[4] == "--synthetic" else { throw ToolError.usage }
                let graph = try await OfflineGraphStore(file: file).load()
                let result = try RoutePlanner.plan(graph: graph,from: args[2],to: args[3],preferences: RoutePreferences(),at: Date(),allowSynthetic: args.count == 5)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                if let reason = result.reason { print(reason) }
                else { print(String(decoding: try encoder.encode(result.routes),as: UTF8.self)) }
            default: throw ToolError.usage
            }
        } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
    enum ToolError: Error, CustomStringConvertible {
        case usage
        var description: String { "Usage: lumapath-route-tool validate INPUT | import INPUT OUTPUT [--replace VERSION] | plan INPUT FROM TO [--synthetic]" }
    }
}
