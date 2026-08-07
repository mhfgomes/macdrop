import AppKit
import Foundation

public struct VideoMetadata: Equatable, Sendable {
    public let duration: TimeInterval
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let codec: VideoCodec
    public let isHEVC: Bool
    public let isQuickTime: Bool

    public init(duration: TimeInterval, pixelWidth: Int, pixelHeight: Int, codec: VideoCodec, isHEVC: Bool, isQuickTime: Bool) {
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.codec = codec
        self.isHEVC = isHEVC
        self.isQuickTime = isQuickTime
    }
}

public protocol VideoInspecting: Sendable {
    func inspect(_ url: URL) async throws -> VideoMetadata
}

public protocol ThumbnailGenerating: Sendable {
    func generate(from source: URL, to destination: URL) async throws
}

@MainActor
public protocol LibraryManaging: AnyObject {
    func importVideos(from urls: [URL]) async -> [VideoImportResult]
    func prepareHEVC(for wallpaper: Wallpaper, progress: @escaping @Sendable (Double) -> Void) async throws
    func delete(_ wallpaper: Wallpaper) throws
}

public protocol PlaylistScheduling: AnyObject {
    func nextID(in ids: [UUID], current: UUID?, order: PlaylistOrder) -> UUID?
    func previousID(in ids: [UUID], current: UUID?) -> UUID?
}

@MainActor
public protocol DisplayDiscovering: AnyObject {
    var displays: [DisplayDescriptor] { get }
    func refresh()
}

@MainActor
public protocol WallpaperPlaybackControlling: AnyObject {
    func reconcileDisplays()
    func play(
        wallpaper: Wallpaper,
        on displayID: String,
        contentMode: WallpaperContentMode,
        advancesOnEnd: Bool
    )
    func stop(on displayID: String)
    func setPaused(_ paused: Bool, reason: PlaybackPauseReason)
    func setBatteryMode(_ enabled: Bool)
}

public protocol LockAssetPreparing: Sendable {
    @MainActor
    func prepare(
        sourceURL: URL,
        destinationURL: URL,
        metadata: VideoMetadata,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

public protocol LockScreenIntegrating: Sendable {
    func health() throws -> LockScreenHealth
    func install(assetURL: URL, thumbnailURL: URL, name: String) throws
    func restore() throws
}

@MainActor
public protocol LaunchAtLoginControlling: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public struct LockScreenHealth: Equatable, Sendable {
    public enum State: String, Sendable { case disabled, healthy, degraded, incompatible }
    public let state: State
    public let message: String
    public let lastBackup: Date?

    public init(state: State, message: String, lastBackup: Date? = nil) {
        self.state = state
        self.message = message
        self.lastBackup = lastBackup
    }
}

public struct VideoImportResult: Identifiable, Sendable {
    public let id = UUID()
    public let sourceName: String
    public let wallpaperID: UUID?
    public let error: String?

    public init(sourceName: String, wallpaperID: UUID? = nil, error: String? = nil) {
        self.sourceName = sourceName
        self.wallpaperID = wallpaperID
        self.error = error
    }
}
