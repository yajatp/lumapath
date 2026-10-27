import Foundation

public enum CapabilityProfile: String, Codable, Sendable { case depth, tracking, camera, noCamera }
public enum CaptureBackend: String, Codable, Sendable { case arkit, avfoundation }
public enum FeatureID: String, Codable, Sendable, CaseIterable {
    case cameraView, imageCandidates, metricGeometry, spatialMemory, savedNotes, manualRoutes, manualReports
}
public enum AvailabilityState: String, Codable, Sendable { case enabled, limited, unavailable }
public struct FeatureAvailability: Codable, Sendable, Equatable {
    public let feature: FeatureID
    public let state: AvailabilityState
    public let reason: String
    public let fallback: String
}

/// Hardware support, current operation and evidence authorization are distinct inputs.
/// Unknown model/output readiness defaults to false; no device-name allowlist authorizes geometry.
public struct CapabilitySnapshot: Codable, Sendable, Equatable {
    public let revision: UInt64
    public let probedAt: TimeInterval
    public let rearCamera: Bool
    public let worldTracking: Bool
    public let sceneDepth: Bool
    public let smoothedSceneDepth: Bool
    public let authorized: Bool
    public let operational: Bool
    public let imageModelReady: Bool
    public let geometryEvidenceEnabled: Bool
    public let memoryEvidenceEnabled: Bool
    public let forceCameraOnly: Bool
    public init(revision: UInt64, probedAt: TimeInterval, rearCamera: Bool, worldTracking: Bool,
                sceneDepth: Bool, smoothedSceneDepth: Bool, authorized: Bool, operational: Bool,
                imageModelReady: Bool = false, geometryEvidenceEnabled: Bool = false,
                memoryEvidenceEnabled: Bool = false, forceCameraOnly: Bool = false) {
        self.revision = revision; self.probedAt = probedAt; self.rearCamera = rearCamera
        self.worldTracking = worldTracking; self.sceneDepth = sceneDepth; self.smoothedSceneDepth = smoothedSceneDepth
        self.authorized = authorized; self.operational = operational; self.imageModelReady = imageModelReady
        self.geometryEvidenceEnabled = geometryEvidenceEnabled; self.memoryEvidenceEnabled = memoryEvidenceEnabled
        self.forceCameraOnly = forceCameraOnly
    }
    public var profile: CapabilityProfile {
        guard rearCamera, authorized, operational, probedAt.isFinite, probedAt >= 0 else { return .noCamera }
        guard !forceCameraOnly, worldTracking else { return .camera }
        return sceneDepth || smoothedSceneDepth ? .depth : .tracking
    }
}

public enum FeatureAvailabilityEvaluator {
    /// Frame evidence can remove hardware eligibility; a capability probe cannot supply missing measurements.
    public static func evaluate(_ feature: FeatureID, frame: FrameDescriptor, context: CaptureContext,
                                at now: TimeInterval, imageModelReady: Bool = false,
                                geometryEvidenceEnabled: Bool = false, memoryEvidenceEnabled: Bool = false) -> FeatureAvailability {
        let current = (try? frame.validate()) != nil && frame.envelope.isCurrent(in: context, at: now)
        // Camera-relative measured range needs calibrated depth, not a stable world pose.
        // World memory retains the stricter normal-tracking prerequisite below.
        if feature == .metricGeometry {
            guard current, frame.depthKind != .none, frame.intrinsics != nil else {
                return FeatureAvailability(feature: feature, state: .unavailable, reason: "depthUnavailable", fallback: "cameraView")
            }
            return FeatureAvailability(feature: feature, state: geometryEvidenceEnabled ? .enabled : .unavailable,
                reason: geometryEvidenceEnabled ? "depthEvidenceEnabled" : "evidenceGateClosed", fallback: geometryEvidenceEnabled ? "none" : "cameraView")
        }
        return evaluate(feature, snapshot: CapabilitySnapshot(revision: frame.capabilityRevision ?? context.generation,
            probedAt: now, rearCamera: current, worldTracking: current && frame.cameraToWorld != nil && frame.tracking == .normal,
            sceneDepth: current && frame.depthKind == .sceneDepth && frame.intrinsics != nil,
            smoothedSceneDepth: current && frame.depthKind == .smoothedSceneDepth && frame.intrinsics != nil,
            authorized: current, operational: current, imageModelReady: imageModelReady,
            geometryEvidenceEnabled: geometryEvidenceEnabled, memoryEvidenceEnabled: memoryEvidenceEnabled,
            forceCameraOnly: frame.backend == .avfoundation))
    }
    public static func evaluate(_ feature: FeatureID, snapshot: CapabilitySnapshot) -> FeatureAvailability {
        func result(_ state: AvailabilityState, _ reason: String, _ fallback: String) -> FeatureAvailability {
            FeatureAvailability(feature: feature, state: state, reason: reason, fallback: fallback)
        }
        switch feature {
        case .savedNotes, .manualRoutes, .manualReports:
            return result(.enabled, "localManualWorkflow", "none")
        case .cameraView:
            return snapshot.profile == .noCamera ? result(.unavailable, "cameraUnavailable", "retryOrSettings")
                : result(.enabled, "cameraAvailable", "none")
        case .imageCandidates:
            guard snapshot.profile != .noCamera else { return result(.unavailable, "cameraUnavailable", "typeOrSelect") }
            return snapshot.imageModelReady ? result(.limited, "imageRelativeOnly", "distanceUnavailable")
                : result(.unavailable, "modelUnavailable", "typeOrSelect")
        case .metricGeometry:
            guard snapshot.profile == .depth else { return result(.unavailable, "depthUnavailable", "cameraView") }
            return snapshot.geometryEvidenceEnabled ? result(.enabled, "depthEvidenceEnabled", "none")
                : result(.unavailable, "evidenceGateClosed", "cameraView")
        case .spatialMemory:
            guard snapshot.profile == .depth || snapshot.profile == .tracking else {
                return result(.unavailable, "worldTrackingUnavailable", "savedNotes")
            }
            return snapshot.memoryEvidenceEnabled ? result(.limited, "currentAlignmentRequired", "savedNotes")
                : result(.unavailable, "evidenceGateClosed", "savedNotes")
        }
    }
}

/// One automatic AR → standard camera replacement per explicit Start. Never retries permission refusal.
public struct CaptureRecoveryPolicy: Sendable {
    public private(set) var attemptedFallback = false
    public init() {}
    public mutating func requestFallback(backend: CaptureBackend?, status: CaptureStatus) -> Bool {
        guard backend == .arkit, !attemptedFallback else { return false }
        let failure = status.phase == .blocked &&
            (status.reason?.hasPrefix("arkitFailure:") == true || status.reason == "worldTrackingUnsupported" || status.reason == "depthUnsupported")
        guard failure || (status.phase == .unavailable && status.reason == "missingFrames") else { return false }
        attemptedFallback = true
        return true
    }
}
