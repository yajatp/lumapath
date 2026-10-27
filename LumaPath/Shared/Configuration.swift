import Foundation

/// Engineering starting values, not validated sensing limits.
public struct CaptureConfiguration: Sendable, Equatable {
    public static let current = CaptureConfiguration()
    public let schemaVersion = 2
    public let configurationVersion = 3
    public let startupTimeout: TimeInterval = 5
    public let maximumFrameAge: TimeInterval = 0.300
    public let missingFrameInterval: TimeInterval = 0.500
    public let watchdogInterval: TimeInterval = 0.100
    public let maximumRetainedFrames = 3
    public let processingInterval: TimeInterval = 1.0 / 15.0
    public init() {}
}

public protocol MonotonicClock: Sendable {
    func now() -> TimeInterval
}

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public enum ContractError: Error, Equatable {
    case unsupportedSchema(Int)
    case invalidValue(String)
}
