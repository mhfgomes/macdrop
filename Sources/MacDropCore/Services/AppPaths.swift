import Foundation

public struct AppPaths: Sendable {
    public let root: URL
    public let library: URL
    public let backups: URL
    public let logs: URL

    public init(root: URL? = nil) {
        let resolvedRoot = root ?? Self.defaultRoot()
        self.root = resolvedRoot
        self.library = resolvedRoot.appendingPathComponent("Library", isDirectory: true)
        self.backups = resolvedRoot.appendingPathComponent("Backups/WallpaperSystem", isDirectory: true)
        self.logs = resolvedRoot.appendingPathComponent("Logs", isDirectory: true)
    }

    static func defaultRoot(
        userDefaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        uiTestIdentifier: UUID = UUID()
    ) -> URL {
        let isUITesting = userDefaults.bool(forKey: "MacDropUITesting")
            || arguments.contains("-MacDropUITesting")
        if isUITesting {
            return temporaryDirectory.appendingPathComponent(
                "MacDropUITests-\(uiTestIdentifier.uuidString)",
                isDirectory: true
            )
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDrop", isDirectory: true)
    }

    public func prepare() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: library, withIntermediateDirectories: true)
        try manager.createDirectory(at: backups, withIntermediateDirectories: true)
        try manager.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    public func directory(for wallpaperID: UUID) -> URL {
        library.appendingPathComponent(wallpaperID.uuidString, isDirectory: true)
    }

    public func sourceURL(for wallpaper: Wallpaper) -> URL {
        directory(for: wallpaper.id).appendingPathComponent(wallpaper.sourceFilename)
    }

    public func thumbnailURL(for wallpaper: Wallpaper) -> URL {
        directory(for: wallpaper.id).appendingPathComponent(wallpaper.thumbnailFilename)
    }

    public func lockAssetURL(for wallpaper: Wallpaper) -> URL? {
        wallpaper.lockAssetFilename.map { directory(for: wallpaper.id).appendingPathComponent($0) }
    }
}

