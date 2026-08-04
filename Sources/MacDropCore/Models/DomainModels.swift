import Foundation
import SwiftData

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264
    case hevc
    case proRes
    case av1
    case other
}

public enum PlaylistOrder: String, Codable, CaseIterable, Sendable {
    case sequential
    case shuffle
}

public enum PlaylistAdvanceMode: String, Codable, CaseIterable, Sendable {
    case interval
    case videoEnd
}

public enum WallpaperContentMode: String, Codable, CaseIterable, Sendable {
    case fill
    case fit
}

public enum LockAssetStatus: Codable, Equatable, Sendable {
    case notPrepared
    case preparing(progress: Double)
    case ready
    case cancelled
    case failed(message: String)
}

public enum AssignmentSource: Codable, Equatable, Sendable {
    case wallpaper(UUID)
    case playlist(UUID)
}

public enum PlaybackPauseReason: String, Codable, Hashable, Sendable {
    case manual
    case desktopObscured
    case fullscreenApplication
    case systemSleep
    case thermalPressure
    case displayDisconnected
    case battery
}

@Model
public final class Wallpaper {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var sourceFilename: String
    public var importedAt: Date
    public var duration: TimeInterval
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var codecRawValue: String
    public var thumbnailFilename: String
    public var lockAssetFilename: String?
    public var lockAssetState: String
    public var lockAssetError: String?

    public init(
        id: UUID = UUID(),
        name: String,
        sourceFilename: String,
        importedAt: Date = .now,
        duration: TimeInterval,
        pixelWidth: Int,
        pixelHeight: Int,
        codec: VideoCodec,
        thumbnailFilename: String,
        lockAssetFilename: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceFilename = sourceFilename
        self.importedAt = importedAt
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.codecRawValue = codec.rawValue
        self.thumbnailFilename = thumbnailFilename
        self.lockAssetFilename = lockAssetFilename
        self.lockAssetState = lockAssetFilename == nil ? "notPrepared" : "ready"
    }

    public var codec: VideoCodec {
        get { VideoCodec(rawValue: codecRawValue) ?? .other }
        set { codecRawValue = newValue.rawValue }
    }

    public var lockAssetStatus: LockAssetStatus {
        get {
            switch lockAssetState {
            case "ready": return .ready
            case "preparing": return .preparing(progress: 0)
            case "cancelled": return .cancelled
            case "failed": return .failed(message: lockAssetError ?? "Unknown error")
            default: return .notPrepared
            }
        }
        set {
            switch newValue {
            case .notPrepared:
                lockAssetState = "notPrepared"
                lockAssetError = nil
            case .preparing:
                lockAssetState = "preparing"
                lockAssetError = nil
            case .ready:
                lockAssetState = "ready"
                lockAssetError = nil
            case .cancelled:
                lockAssetState = "cancelled"
                lockAssetError = nil
            case .failed(let message):
                lockAssetState = "failed"
                lockAssetError = message
            }
        }
    }
}

@Model
public final class PlaylistEntry {
    @Attribute(.unique) public var id: UUID
    public var wallpaperID: UUID
    public var sortIndex: Int

    public init(id: UUID = UUID(), wallpaperID: UUID, sortIndex: Int) {
        self.id = id
        self.wallpaperID = wallpaperID
        self.sortIndex = sortIndex
    }
}

@Model
public final class Playlist {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var createdAt: Date
    public var playbackOrderRawValue: String
    @Relationship(deleteRule: .cascade) public var entries: [PlaylistEntry]

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        playbackOrder: PlaylistOrder = .sequential,
        entries: [PlaylistEntry] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.playbackOrderRawValue = playbackOrder.rawValue
        self.entries = entries
    }

    public var playbackOrder: PlaylistOrder {
        get { PlaylistOrder(rawValue: playbackOrderRawValue) ?? .sequential }
        set { playbackOrderRawValue = newValue.rawValue }
    }

    public var orderedEntries: [PlaylistEntry] {
        entries.sorted { $0.sortIndex < $1.sortIndex }
    }
}

@Model
public final class DisplayAssignment {
    @Attribute(.unique) public var displayUUID: String
    public var sourceKind: String
    public var sourceID: UUID
    public var rotationMinutes: Int
    public var advanceModeRawValue: String = PlaylistAdvanceMode.interval.rawValue
    public var contentModeRawValue: String
    public var lastWallpaperID: UUID?

    public init(
        displayUUID: String,
        source: AssignmentSource,
        rotationMinutes: Int = 30,
        advanceMode: PlaylistAdvanceMode = .interval,
        contentMode: WallpaperContentMode = .fill,
        lastWallpaperID: UUID? = nil
    ) {
        self.displayUUID = displayUUID
        switch source {
        case .wallpaper(let id):
            self.sourceKind = "wallpaper"
            self.sourceID = id
        case .playlist(let id):
            self.sourceKind = "playlist"
            self.sourceID = id
        }
        self.rotationMinutes = min(1_440, max(1, rotationMinutes))
        self.advanceModeRawValue = advanceMode.rawValue
        self.contentModeRawValue = contentMode.rawValue
        self.lastWallpaperID = lastWallpaperID
    }

    public var source: AssignmentSource {
        get { sourceKind == "playlist" ? .playlist(sourceID) : .wallpaper(sourceID) }
        set {
            switch newValue {
            case .wallpaper(let id): sourceKind = "wallpaper"; sourceID = id
            case .playlist(let id): sourceKind = "playlist"; sourceID = id
            }
        }
    }

    public var contentMode: WallpaperContentMode {
        get { WallpaperContentMode(rawValue: contentModeRawValue) ?? .fill }
        set { contentModeRawValue = newValue.rawValue }
    }

    public var advanceMode: PlaylistAdvanceMode {
        get { PlaylistAdvanceMode(rawValue: advanceModeRawValue) ?? .interval }
        set { advanceModeRawValue = newValue.rawValue }
    }
}

@Model
public final class AppPreferences {
    @Attribute(.unique) public var id: String
    public var launchAtLogin: Bool
    public var pauseWhenObscured: Bool
    public var pauseForFullscreenApps: Bool
    public var reduceQualityOnBattery: Bool
    public var pauseOnBattery: Bool
    public var pauseAtSeriousThermalState: Bool
    public var lockScreenEnabled: Bool
    public var lockScreenWallpaperID: UUID?

    public init(
        id: String = "main",
        launchAtLogin: Bool = false,
        pauseWhenObscured: Bool = true,
        pauseForFullscreenApps: Bool = true,
        reduceQualityOnBattery: Bool = true,
        pauseOnBattery: Bool = false,
        pauseAtSeriousThermalState: Bool = true,
        lockScreenEnabled: Bool = false,
        lockScreenWallpaperID: UUID? = nil
    ) {
        self.id = id
        self.launchAtLogin = launchAtLogin
        self.pauseWhenObscured = pauseWhenObscured
        self.pauseForFullscreenApps = pauseForFullscreenApps
        self.reduceQualityOnBattery = reduceQualityOnBattery
        self.pauseOnBattery = pauseOnBattery
        self.pauseAtSeriousThermalState = pauseAtSeriousThermalState
        self.lockScreenEnabled = lockScreenEnabled
        self.lockScreenWallpaperID = lockScreenWallpaperID
    }
}

public enum MacDropSchema {
    public static let models: [any PersistentModel.Type] = [
        Wallpaper.self,
        Playlist.self,
        PlaylistEntry.self,
        DisplayAssignment.self,
        AppPreferences.self
    ]
}
