// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumaPath",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "LumaPathCommands", targets: ["LumaPathCommands"]),
        .library(name: "LumaPathAttention", targets: ["LumaPathAttention"]),
        .library(name: "LumaPathAccessories", targets: ["LumaPathAccessories"]),
        .library(name: "LumaPathDomain", targets: ["LumaPathDomain"]),
        .library(name: "LumaPathSensors", targets: ["LumaPathSensors"]),
        .library(name: "LumaPathPerception", targets: ["LumaPathPerception"]),
        .library(name: "LumaPathRisk", targets: ["LumaPathRisk"]),
        .library(name: "LumaPathModels", targets: ["LumaPathModels"]),
        .library(name: "LumaPathGoals", targets: ["LumaPathGoals"]),
        .library(name: "LumaPathMemory", targets: ["LumaPathMemory"]),
        .library(name: "LumaPathRouting", targets: ["LumaPathRouting"]),
        .executable(name: "lumapath-route-tool", targets: ["LumaPathRouteTool"]),
        .library(name: "LumaPathRendering", targets: ["LumaPathRendering"]),
        .library(name: "LumaPathPersonalization", targets: ["LumaPathPersonalization"]),
        .library(name: "LumaPathFeedback", targets: ["LumaPathFeedback"])
    ],
    targets: [
        .target(name: "LumaPathCommands", dependencies: ["LumaPathDomain", "LumaPathGoals"], path: "LumaPath/Goals/Commands"),
        .target(name: "LumaPathAttention", dependencies: ["LumaPathDomain"], path: "LumaPath/Attention"),
        .testTarget(name: "LumaPathCommandTests", dependencies: ["LumaPathCommands", "LumaPathAttention", "LumaPathDomain", "LumaPathGoals", "LumaPathPerception"], path: "LumaPathCommandTests"),
        .target(name: "LumaPathAccessories", dependencies: ["LumaPathDomain"], path: "LumaPath/Accessories"),
        .testTarget(name: "LumaPathAccessoriesTests", dependencies: ["LumaPathAccessories", "LumaPathDomain"], path: "LumaPathAccessoriesTests"),
        .target(name: "LumaPathPersonalization", dependencies: ["LumaPathDomain", "LumaPathRendering"], path: "LumaPath/Personalization"),
        .testTarget(name: "LumaPathPersonalizationTests", dependencies: ["LumaPathPersonalization", "LumaPathDomain", "LumaPathPerception", "LumaPathRisk", "LumaPathFeedback"], path: "LumaPathPersonalizationTests"),
        .target(name: "LumaPathFeedback", dependencies: ["LumaPathDomain", "LumaPathRisk", "LumaPathAccessories"], path: "LumaPath/Feedback"),
        .testTarget(name: "LumaPathFeedbackTests", dependencies: ["LumaPathDomain", "LumaPathRisk", "LumaPathPerception", "LumaPathFeedback"], path: "LumaPathFeedbackTests"),
        .target(name: "LumaPathRendering", dependencies: ["LumaPathDomain", "LumaPathSensors"], path: "LumaPath/Rendering"),
        .testTarget(name: "LumaPathRenderingTests", dependencies: ["LumaPathDomain", "LumaPathRendering"], path: "LumaPathRenderingTests"),
        .target(name: "LumaPathDomain", path: "LumaPath/Shared", resources: [.copy("Fixtures")]),
        .target(name: "LumaPathSensors", dependencies: ["LumaPathDomain", "LumaPathMemory"], path: "LumaPath/Sensors"),
        .target(name: "LumaPathPerception", dependencies: ["LumaPathDomain"], path: "LumaPath/Perception"),
        .target(name: "LumaPathRisk", dependencies: ["LumaPathDomain", "LumaPathPerception"], path: "LumaPath/Risk"),
        .target(name: "LumaPathModels", dependencies: ["LumaPathDomain"], path: "LumaPath/Models", resources: [.copy("Assets")]),
        .target(name: "LumaPathGoals", dependencies: ["LumaPathDomain", "LumaPathModels", "LumaPathMemory"], path: "LumaPath/Goals/Resolution"),
        .target(name: "LumaPathMemory", dependencies: ["LumaPathDomain"], path: "LumaPath/Memory"),
        .target(name: "LumaPathRouting", dependencies: ["LumaPathDomain"], path: "LumaPath/Routing"),
        .executableTarget(name: "LumaPathRouteTool", dependencies: ["LumaPathRouting"], path: "Tools/Routing"),
        .testTarget(name: "LumaPathRoutingTests", dependencies: ["LumaPathRouting", "LumaPathDomain"], path: "LumaPathRoutingTests", resources: [.copy("Fixtures")]),
        .testTarget(name: "LumaPathMemoryTests", dependencies: ["LumaPathMemory", "LumaPathGoals", "LumaPathDomain"], path: "LumaPathMemoryTests"),
        .testTarget(name: "LumaPathPerceptionTests", dependencies: ["LumaPathDomain", "LumaPathPerception", "LumaPathRisk", "LumaPathModels", "LumaPathGoals"], path: "LumaPathPerceptionTests"),
        .testTarget(name: "LumaPathSensorTests", dependencies: ["LumaPathSensors", "LumaPathDomain"], path: "LumaPathSensorTests"),
        .testTarget(name: "LumaPathDomainTests", dependencies: ["LumaPathDomain"], path: "LumaPathTests")
    ]
)
