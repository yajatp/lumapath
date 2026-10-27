import Foundation
import LumaPathDomain
import LumaPathRendering

public enum PreferenceSource: String, Codable, Sendable { case manual, exerciseSuggested, preset }
public enum ProfileFocus: String, Codable, Sendable, CaseIterable { case wholeScene, centralSummary, wideSceneSummary }
public enum OutlineColor: String, Codable, Sendable, CaseIterable { case yellow, cyan, white }
public enum GlareComfort: String, Codable, Sendable, CaseIterable { case standard, reducedHighlights }
public enum LightingPreference: String, Codable, Sendable, CaseIterable { case dimIndoor, outdoorNight, backlit, rapidlyChanging }
public enum ProfileSpeechDetail: String, Codable, Sendable, CaseIterable { case minimal, standard, descriptive }
public enum SurfacePreference: String, Codable, Sendable, CaseIterable { case noPreference, firmEven, paved }
public enum AnticipationPreference: String, Codable, Sendable, CaseIterable { case standard, earlier }
public enum ExerciseKind: String, Codable, Sendable, CaseIterable { case contrast, highlights, outline, placement, cues }
public enum ExerciseStatus: String, Codable, Sendable { case notStarted, skipped, completed }
public enum ProfileKey: String, Codable, Sendable, CaseIterable {
    case exposure, contrast, highlights, edges, outlineWidth, outlineColor, dualStroke, density, focus
    case glare, lighting, speechDetail, descriptionInterval, speech, haptics, spatialCues
    case avoidStairs, requiredWidth, surface, anticipation
}

/// Local preferences only. There is deliberately no detector confidence, urgency or expiry setting.
public struct ProfilePreferences: Codable, Sendable, Equatable {
    public var exposure = 0.0
    public var contrast = 1.0
    public var highlights = 0.25
    public var edges = 0.0
    public var outlineWidth = 4.0
    public var outlineColor: OutlineColor = .yellow
    public var dualStroke = true
    public var density = 3
    public var focus: ProfileFocus = .wholeScene
    public var glare: GlareComfort = .standard
    public var lighting: Set<LightingPreference> = []
    public var speechDetail: ProfileSpeechDetail = .standard
    public var descriptionInterval = 10.0
    public var speech = false
    public var haptics = false
    public var spatialCues = false
    public var avoidStairs = false
    /// User-requested minimum route width, meters; nil means no extra width constraint.
    public var requiredWidth: Double? = nil
    public var surface: SurfacePreference = .noPreference
    public var anticipation: AnticipationPreference = .standard
    public init() {}
    public var isValid: Bool {
        enhancement.isValid && (0...1).contains(highlights) && (2...10).contains(outlineWidth) && (1...5).contains(density)
        && (5...30).contains(descriptionInterval)
        && (requiredWidth.map { $0.isFinite && (0.3...3).contains($0) } ?? true)
    }
    public var enhancement: EnhancementSettings {
        var value = EnhancementSettings()
        value.exposure = exposure; value.contrast = contrast; value.edges = edges
        value.highlightCompression = glare == .reducedHighlights ? max(0.65, highlights) : highlights
        return value
    }
    public var presentation: PresentationPreferences {
        var value = PresentationPreferences()
        value.focus = focus == .centralSummary ? .centralSummary : focus == .wideSceneSummary ? .wideSceneSummary : .wholeScene
        value.speechDetail = speechDetail == .minimal ? .minimal : speechDetail == .descriptive ? .descriptive : .standard
        return value
    }
}

public struct VisionProfile: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchema = 2
    public var schemaVersion = currentSchema
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date
    public var preferences = ProfilePreferences()
    public var sources: [ProfileKey: PreferenceSource] = Dictionary(uniqueKeysWithValues: ProfileKey.allCases.map { ($0, .preset) })
    public var exercises: [ExerciseKind: ExerciseStatus] = Dictionary(uniqueKeysWithValues: ExerciseKind.allCases.map { ($0, .notStarted) })
    public init(id: UUID = UUID(), name: String = "Everyday", now: Date = Date()) {
        self.id = id; self.name = name; createdAt = now; updatedAt = now
    }
    public var isValid: Bool {
        schemaVersion == Self.currentSchema && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80
        && createdAt.timeIntervalSince1970.isFinite && updatedAt.timeIntervalSince1970.isFinite && updatedAt >= createdAt
        && preferences.isValid && Set(sources.keys) == Set(ProfileKey.allCases) && Set(exercises.keys) == Set(ExerciseKind.allCases)
    }
    public mutating func reset() {
        preferences = ProfilePreferences()
        sources = Dictionary(uniqueKeysWithValues: ProfileKey.allCases.map { ($0, .preset) })
        exercises = Dictionary(uniqueKeysWithValues: ExerciseKind.allCases.map { ($0, .notStarted) })
    }
    public mutating func accept(_ suggestion: ExerciseSuggestion) {
        switch suggestion {
        case .contrast(let value): preferences.contrast = value; sources[.contrast] = .exerciseSuggested; exercises[.contrast] = .completed
        case .highlights(let value): preferences.highlights = value; sources[.highlights] = .exerciseSuggested; exercises[.highlights] = .completed
        case .outline(let color, let width):
            preferences.outlineColor = color; preferences.outlineWidth = width
            sources[.outlineColor] = .exerciseSuggested; sources[.outlineWidth] = .exerciseSuggested; exercises[.outline] = .completed
        case .placement(let focus): preferences.focus = focus; sources[.focus] = .exerciseSuggested; exercises[.placement] = .completed
        }
    }
}
public enum ExerciseSuggestion: Sendable, Equatable {
    case contrast(Double), highlights(Double), outline(OutlineColor, Double), placement(ProfileFocus)
}

public enum ProfileArchiveError: Error { case invalidRecord, unsupportedVersion, recordTooLarge, protectedRecord, tooManyProfiles }
public struct ProfileLoadResult: Sendable {
    public let profiles: [VisionProfile]
    public let activeID: UUID?
    public let issues: [String]
}

/// One file per profile isolates damaged/future records. Atomic writes; no raw images or exercise answers.
/// Schema 1 is the documented early exposure/contrast record; migration is in memory until explicit Save.
public struct ProfileArchive {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public static func decode(_ data: Data) throws -> VisionProfile {
        guard data.count <= 65_536 else { throw ProfileArchiveError.recordTooLarge }
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        let version = try decoder.decode(Header.self, from: data).schemaVersion
        let profile: VisionProfile
        switch version {
        case 1:
            struct Legacy: Decodable { let id: UUID; let name: String; let createdAt: Date; let updatedAt: Date; let exposure: Double; let contrast: Double }
            let old = try decoder.decode(Legacy.self, from: data)
            var migrated = VisionProfile(id: old.id, name: old.name, now: old.createdAt)
            migrated.updatedAt = old.updatedAt; migrated.preferences.exposure = old.exposure; migrated.preferences.contrast = old.contrast
            migrated.sources[.exposure] = .manual; migrated.sources[.contrast] = .manual
            profile = migrated
        case VisionProfile.currentSchema: profile = try decoder.decode(VisionProfile.self, from: data)
        default: throw ProfileArchiveError.unsupportedVersion
        }
        guard profile.isValid else { throw ProfileArchiveError.invalidRecord }
        return profile
    }
    public func load() throws -> ProfileLoadResult {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ProfileLoadResult(profiles: [], activeID: nil, issues: []) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var profiles: [VisionProfile] = []; var issues: [String] = []
        for file in files where UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil && file.pathExtension == "json" {
            do {
                guard profiles.count < 100 else { throw ProfileArchiveError.tooManyProfiles }
                let value = try Self.decode(read(file))
                guard file.deletingPathExtension().lastPathComponent == value.id.uuidString else { throw ProfileArchiveError.invalidRecord }
                profiles.append(value)
            } catch { issues.append("Profile \(file.deletingPathExtension().lastPathComponent) could not be loaded (\(error)). Its file was preserved.") }
        }
        var active: UUID?
        let activeURL = directory.appendingPathComponent("active.json")
        if FileManager.default.fileExists(atPath: activeURL.path) {
            do {
                active = try JSONDecoder().decode(UUID.self, from: read(activeURL))
                if !profiles.contains(where: { $0.id == active }) { issues.append("The selected profile is unavailable. Choose a usable profile or create one."); active = nil }
            } catch { issues.append("The selected profile could not be restored. Choose a usable profile.") }
        }
        return ProfileLoadResult(profiles: profiles.sorted { $0.createdAt < $1.createdAt }, activeID: active, issues: issues)
    }
    public func save(_ profile: VisionProfile) throws {
        guard profile.isValid else { throw ProfileArchiveError.invalidRecord }
        try prepare()
        let url = directory.appendingPathComponent(profile.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            // An older app must never overwrite a future-schema or damaged record.
            guard let previous = try? Self.decode(read(url)), previous.id == profile.id else { throw ProfileArchiveError.protectedRecord }
        } else if try load().profiles.count >= 100 { throw ProfileArchiveError.tooManyProfiles }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(profile), to: url)
    }
    public func select(_ id: UUID) throws {
        guard try load().profiles.contains(where: { $0.id == id }) else { throw ProfileArchiveError.invalidRecord }
        try write(JSONEncoder().encode(id), to: directory.appendingPathComponent("active.json"))
    }
    private func prepare() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    private func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, let size = values.fileSize, size <= 65_536 else { throw ProfileArchiveError.recordTooLarge }
        return try Data(contentsOf: url)
    }
    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
