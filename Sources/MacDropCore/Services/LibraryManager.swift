import Foundation
import SwiftData

@MainActor
public final class LibraryManager: ObservableObject, LibraryManaging {
    public let paths: AppPaths
    private let context: ModelContext
    private let inspector: any VideoInspecting
    private let thumbnailGenerator: any ThumbnailGenerating
    private let hevcPreparer: any LockAssetPreparing

    public init(
        context: ModelContext,
        paths: AppPaths = AppPaths(),
        inspector: any VideoInspecting = AVVideoInspector(),
        thumbnailGenerator: any ThumbnailGenerating = AVThumbnailGenerator(),
        hevcPreparer: any LockAssetPreparing = AVLockAssetPreparer()
    ) throws {
        self.context = context
        self.paths = paths
        self.inspector = inspector
        self.thumbnailGenerator = thumbnailGenerator
        self.hevcPreparer = hevcPreparer
        try paths.prepare()
    }

    public func importVideos(from urls: [URL]) async -> [VideoImportResult] {
        var results: [VideoImportResult] = []
        for url in urls {
            do {
                let wallpaper = try await importVideo(from: url)
                results.append(VideoImportResult(sourceName: url.lastPathComponent, wallpaperID: wallpaper.id))
            } catch {
                results.append(VideoImportResult(sourceName: url.lastPathComponent, error: error.localizedDescription))
            }
        }
        return results
    }

    private func importVideo(from externalURL: URL) async throws -> Wallpaper {
        let accessed = externalURL.startAccessingSecurityScopedResource()
        defer { if accessed { externalURL.stopAccessingSecurityScopedResource() } }

        let metadata = try await inspector.inspect(externalURL)
        let id = UUID()
        let finalDirectory = paths.directory(for: id)
        let stagingDirectory = paths.library.appendingPathComponent(".import-\(id.uuidString)", isDirectory: true)
        let safeExtension = externalURL.pathExtension.lowercased()
        let sourceFilename = "source.\(safeExtension)"
        let stagedSource = stagingDirectory.appendingPathComponent(sourceFilename)
        let stagedThumbnail = stagingDirectory.appendingPathComponent("thumbnail.jpg")

        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: externalURL, to: stagedSource)
            }.value
            try await thumbnailGenerator.generate(from: stagedSource, to: stagedThumbnail)
            try FileManager.default.moveItem(at: stagingDirectory, to: finalDirectory)
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            try? FileManager.default.removeItem(at: finalDirectory)
            throw error
        }

        let wallpaper = Wallpaper(
            id: id,
            name: externalURL.deletingPathExtension().lastPathComponent,
            sourceFilename: sourceFilename,
            duration: metadata.duration,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            codec: metadata.codec,
            thumbnailFilename: "thumbnail.jpg"
        )
        context.insert(wallpaper)
        do {
            try context.save()
        } catch {
            context.delete(wallpaper)
            try? FileManager.default.removeItem(at: finalDirectory)
            throw error
        }
        return wallpaper
    }

    public func prepareHEVC(
        for wallpaper: Wallpaper,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let source = paths.sourceURL(for: wallpaper)
        let destination = paths.directory(for: wallpaper.id).appendingPathComponent("lock-hevc.mov")
        let metadata = VideoMetadata(
            duration: wallpaper.duration,
            pixelWidth: wallpaper.pixelWidth,
            pixelHeight: wallpaper.pixelHeight,
            codec: wallpaper.codec,
            isHEVC: wallpaper.codec == .hevc,
            isQuickTime: source.pathExtension.lowercased() == "mov"
        )
        let prepared = try await hevcPreparer.prepare(
            sourceURL: source,
            destinationURL: destination,
            metadata: metadata,
            progress: progress
        )
        wallpaper.lockAssetFilename = prepared.lastPathComponent
        wallpaper.lockAssetStatus = .ready
        try context.save()
    }

    public func delete(_ wallpaper: Wallpaper) throws {
        let directory = paths.directory(for: wallpaper.id)
        var trashedURL: NSURL?
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.trashItem(at: directory, resultingItemURL: &trashedURL)
        }
        context.delete(wallpaper)
        do {
            try context.save()
        } catch {
            context.rollback()
            if let trashedURL, !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.moveItem(at: trashedURL as URL, to: directory)
            }
            throw error
        }
    }
}
