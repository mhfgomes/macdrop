import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

public enum VideoServiceError: LocalizedError, Equatable {
    case unsupportedExtension
    case unreadableAsset
    case missingVideoTrack
    case invalidDuration
    case thumbnailFailed
    case exportUnavailable
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedExtension: "Only MP4, MOV, and M4V videos are supported."
        case .unreadableAsset: "The video could not be read."
        case .missingVideoTrack: "The file does not contain a playable video track."
        case .invalidDuration: "The video has no playable duration."
        case .thumbnailFailed: "A preview image could not be generated."
        case .exportUnavailable: "This video cannot be converted to HEVC."
        case .exportFailed(let message): "HEVC conversion failed: \(message)"
        }
    }
}

public struct AVVideoInspector: VideoInspecting {
    public init() {}

    public func inspect(_ url: URL) async throws -> VideoMetadata {
        guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else {
            throw VideoServiceError.unsupportedExtension
        }

        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        guard playable else { throw VideoServiceError.unreadableAsset }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw VideoServiceError.invalidDuration }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoServiceError.missingVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = naturalSize.applying(transform)
        let width = Int(abs(transformed.width).rounded())
        let height = Int(abs(transformed.height).rounded())
        let descriptions = try await track.load(.formatDescriptions)
        let codecType = descriptions.first.map(CMFormatDescriptionGetMediaSubType)
        let codec: VideoCodec
        switch codecType {
        case kCMVideoCodecType_H264: codec = .h264
        case kCMVideoCodecType_HEVC: codec = .hevc
        case kCMVideoCodecType_AppleProRes422,
             kCMVideoCodecType_AppleProRes4444,
             kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT,
             kCMVideoCodecType_AppleProRes422Proxy: codec = .proRes
        case kCMVideoCodecType_AV1: codec = .av1
        default: codec = .other
        }

        return VideoMetadata(
            duration: duration,
            pixelWidth: max(1, width),
            pixelHeight: max(1, height),
            codec: codec,
            isHEVC: codec == .hevc,
            isQuickTime: url.pathExtension.lowercased() == "mov"
        )
    }
}

public struct AVThumbnailGenerator: ThumbnailGenerating {
    public init() {}

    public func generate(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let requestedSeconds = min(1, max(0, duration * 0.1))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        let (image, _) = try await generator.image(at: CMTime(seconds: requestedSeconds, preferredTimescale: 600))
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else {
            throw VideoServiceError.thumbnailFailed
        }
        try data.write(to: destination, options: .atomic)
    }
}

public struct AVLockAssetPreparer: LockAssetPreparing {
    public init() {}

    @MainActor
    public func prepare(
        sourceURL source: URL,
        destinationURL destination: URL,
        metadata: VideoMetadata,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        if metadata.isHEVC && metadata.isQuickTime {
            progress(1)
            return source
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            let cachedAsset = AVURLAsset(url: destination)
            let isPlayable = (try? await cachedAsset.load(.isPlayable)) == true
            let duration = try? await cachedAsset.load(.duration)
            let tracks = try? await cachedAsset.loadTracks(withMediaType: .video)
            if isPlayable,
               let duration,
               duration.isNumeric,
               duration.seconds > 0,
               tracks?.isEmpty == false {
                progress(1)
                return destination
            }
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".lock-hevc-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: temporary)

        let asset = AVURLAsset(url: source)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoServiceError.missingVideoTrack
        }
        let duration = try await asset.load(.duration)
        let transform = try await sourceTrack.load(.preferredTransform)
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoServiceError.exportUnavailable
        }
        let targetDuration = CMTime(seconds: 180, preferredTimescale: 600)
        var cursor = CMTime.zero
        repeat {
            try Task.checkCancellation()
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: cursor
            )
            cursor = cursor + duration
        } while cursor < targetDuration
        compositionTrack.preferredTransform = transform
        let preset = metadata.pixelWidth > 1_920 || metadata.pixelHeight > 1_080
            ? AVAssetExportPresetHEVC3840x2160
            : AVAssetExportPresetHEVC1920x1080
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw VideoServiceError.exportUnavailable
        }
        session.shouldOptimizeForNetworkUse = true

        do {
            let progressTask = Task { @MainActor in
                for await state in session.states(updateInterval: 0.1) {
                    guard !Task.isCancelled else { return }
                    if case .exporting(let exportProgress) = state {
                        progress(exportProgress.fractionCompleted)
                    }
                }
            }
            defer { progressTask.cancel() }
            try await session.export(to: temporary, as: .mov)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            progress(1)
            return destination
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: temporary)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw VideoServiceError.exportFailed(error.localizedDescription)
        }
    }
}
