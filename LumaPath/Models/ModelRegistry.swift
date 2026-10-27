import Foundation
import LumaPathDomain

/// A registry describes actual installed inference assets. No class is inferred from a model's display name.
public struct ModelRegistry: Sendable {
    public private(set) var manifests: [String: DetectorManifest] = [DetectorManifest.systemOCR.id: .systemOCR]
    public private(set) var verifiedAssets: Set<String> = []
    public init() {}
    @discardableResult public mutating func register(_ manifest: DetectorManifest, assetURL: URL) throws -> CoreMLDetector {
        try manifest.validate()
        guard manifest.runtime == .coreML, assetURL.isFileURL,
              manifest.sha256 != nil, manifests[manifest.id] == nil else { throw ContractError.invalidValue("modelRegistration") }
        let detector = try CoreMLDetector(manifest: manifest,assetURL: assetURL)
        manifests[manifest.id] = manifest; verifiedAssets.insert(manifest.id)
        return detector
    }
    public func capability(for target: GoalTarget) -> TargetCapability {
        let available = manifests.values.filter { manifest in
            manifest.classMap.values.contains(target) && (manifest.runtime == .appleVisionOCR || verifiedAssets.contains(manifest.id))
        }.sorted { $0.id < $1.id }
        return TargetCapability(target: target,modelIDs: available.map(\.id),researchAvailable: !available.isEmpty,
            ordinaryLiveAvailable: false,reason: available.isEmpty ? (target == .savedLandmark ? "selectedPlaceAlignmentProviderRequired" : "licensedEvaluatedDetectorRequired") : "researchOnlyHeldOutAndPhysicalValidationPending")
    }
}
