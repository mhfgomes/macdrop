import Foundation
import SwiftData
import XCTest
import MacDropCore

private struct FakeInspector: VideoInspecting {
    func inspect(_ url: URL) async throws -> VideoMetadata {
        VideoMetadata(duration: 12, pixelWidth: 1920, pixelHeight: 1080, codec: .h264, isHEVC: false, isQuickTime: false)
    }
}

private struct FakeThumbnailer: ThumbnailGenerating {
    func generate(from source: URL, to destination: URL) async throws {
        try Data("thumbnail".utf8).write(to: destination)
    }
}

private struct FakeHEVCPreparer: LockAssetPreparing {
    @MainActor
    func prepare(
        sourceURL: URL,
        destinationURL: URL,
        metadata: VideoMetadata,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        progress(1)
        return destinationURL
    }
}

private struct FailingHEVCPreparer: LockAssetPreparing {
    @MainActor
    func prepare(
        sourceURL: URL,
        destinationURL: URL,
        metadata: VideoMetadata,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        throw VideoServiceError.exportFailed("Test failure")
    }
}

@MainActor
final class LibraryManagerTests: XCTestCase {
    func testInitializationRemovesStaleImportDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let schema = Schema(MacDropSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let paths = AppPaths(root: root.appendingPathComponent("ApplicationSupport"))
        try paths.prepare()
        let staleDirectory = paths.library.appendingPathComponent(".import-stale", isDirectory: true)
        let similarlyNamedFile = paths.library.appendingPathComponent(".import-keep")
        try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: true)
        try Data("partial import".utf8).write(to: staleDirectory.appendingPathComponent("source.mp4"))
        try Data("not a directory".utf8).write(to: similarlyNamedFile)

        _ = try LibraryManager(
            context: container.mainContext,
            paths: paths,
            inspector: FakeInspector(),
            thumbnailGenerator: FakeThumbnailer(),
            hevcPreparer: FakeHEVCPreparer()
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: similarlyNamedFile.path))
    }

    func testImportCommitsOnlyAfterManagedFilesExist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: source)

        let schema = Schema(MacDropSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let paths = AppPaths(root: root.appendingPathComponent("ApplicationSupport"))
        let manager = try LibraryManager(
            context: container.mainContext,
            paths: paths,
            inspector: FakeInspector(),
            thumbnailGenerator: FakeThumbnailer(),
            hevcPreparer: FakeHEVCPreparer()
        )

        let result = await manager.importVideos(from: [source])
        XCTAssertNil(result.first?.error)
        let wallpapers = try container.mainContext.fetch(FetchDescriptor<Wallpaper>())
        XCTAssertEqual(wallpapers.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sourceURL(for: wallpapers[0]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.thumbnailURL(for: wallpapers[0]).path))
        XCTAssertEqual(wallpapers[0].lockAssetStatus, .notPrepared)
        try await manager.prepareHEVC(for: wallpapers[0]) { _ in }
        XCTAssertEqual(wallpapers[0].lockAssetStatus, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(paths.lockAssetURL(for: wallpapers[0])).path))
    }

    func testHEVCFailureKeepsImportedOriginalUsable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: source)

        let schema = Schema(MacDropSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let paths = AppPaths(root: root.appendingPathComponent("ApplicationSupport"))
        let manager = try LibraryManager(
            context: container.mainContext,
            paths: paths,
            inspector: FakeInspector(),
            thumbnailGenerator: FakeThumbnailer(),
            hevcPreparer: FailingHEVCPreparer()
        )

        let result = await manager.importVideos(from: [source])
        XCTAssertNil(result.first?.error)
        let wallpaper = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<Wallpaper>()).first)
        do {
            try await manager.prepareHEVC(for: wallpaper) { _ in }
            XCTFail("Expected HEVC preparation to fail")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sourceURL(for: wallpaper).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.thumbnailURL(for: wallpaper).path))
        }
    }
}
