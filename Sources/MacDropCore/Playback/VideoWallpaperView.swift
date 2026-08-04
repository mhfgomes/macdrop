import AppKit
@preconcurrency import AVFoundation
import Foundation

@MainActor
final class VideoWallpaperView: NSView {
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var playerLayer = AVPlayerLayer()
    private var looperObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var endTimeObserver: Any?
    private(set) var currentURL: URL?
    private var desiredContentMode: WallpaperContentMode = .fill
    private var loops = true
    private var batteryMode = false
    private var didSignalPlaybackEnd = false
    private var rebuildRetryCount = 0
    private let maximumRebuildRetries = 3
    var playbackEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.frame = bounds
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func load(url: URL, contentMode: WallpaperContentMode, loops: Bool) {
        guard currentURL != url || desiredContentMode != contentMode || self.loops != loops else {
            resume()
            return
        }
        if currentURL != url {
            rebuildRetryCount = 0
        }
        currentURL = url
        desiredContentMode = contentMode
        self.loops = loops
        playerLayer.videoGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
        rebuildPlayer()
    }

    func pause() {
        queuePlayer?.pause()
    }

    func resume() {
        guard queuePlayer?.currentItem != nil else {
            if currentURL != nil { rebuildPlayer() }
            return
        }
        queuePlayer?.play()
    }

    func setBatteryMode(_ enabled: Bool) {
        batteryMode = enabled
        configureQuality(for: queuePlayer?.currentItem)
        playerLayer.contentsScale = enabled ? 1 : (window?.screen?.backingScaleFactor ?? 2)
    }

    func clear() {
        currentURL = nil
        rebuildRetryCount = 0
        rebuildPlayer()
    }

    private func rebuildPlayer() {
        tearDownPlayer()
        didSignalPlaybackEnd = false

        guard let currentURL else { return }
        let asset = AVURLAsset(url: currentURL)
        let item = AVPlayerItem(asset: asset)
        configureQuality(for: item)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        queuePlayer = player
        playerLayer.player = player
        playerLayer.contentsScale = batteryMode ? 1 : (window?.screen?.backingScaleFactor ?? 2)

        if loops {
            let looper = AVPlayerLooper(player: player, templateItem: item)
            playerLooper = looper
            looperObservation = looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                Task { @MainActor [weak self] in self?.handlePermanentFailure() }
            }
        } else {
            playerLooper = nil
            player.insert(item, after: nil)
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.signalPlaybackEnded() }
            }
            endTimeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                queue: .main
            ) { [weak self, weak item] time in
                guard let item else { return }
                let duration = item.duration.seconds
                guard duration.isFinite, duration > 0, time.seconds >= duration - 0.08 else { return }
                Task { @MainActor [weak self] in self?.signalPlaybackEnded() }
            }
        }
        itemObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            guard player.currentItem?.status == .failed else { return }
            Task { @MainActor [weak self] in self?.handlePermanentFailure() }
        }
        player.play()
    }

    private func tearDownPlayer() {
        if let endTimeObserver, let queuePlayer {
            queuePlayer.removeTimeObserver(endTimeObserver)
            self.endTimeObserver = nil
        }
        looperObservation?.invalidate()
        itemObservation?.invalidate()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        playerLooper?.disableLooping()
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        playerLayer.player = nil
        playerLooper = nil
        queuePlayer = nil
    }

    private func handlePermanentFailure() {
        guard currentURL != nil else { return }
        guard rebuildRetryCount < maximumRebuildRetries else {
            currentURL = nil
            tearDownPlayer()
            return
        }
        rebuildRetryCount += 1
        rebuildPlayer()
    }

    private func signalPlaybackEnded() {
        guard !didSignalPlaybackEnd else { return }
        didSignalPlaybackEnd = true
        playbackEnded?()
    }

    private func configureQuality(for item: AVPlayerItem?) {
        guard let item else { return }
        if batteryMode {
            item.preferredMaximumResolution = CGSize(width: 1_920, height: 1_080)
            item.preferredPeakBitRate = 5_000_000
        } else {
            item.preferredMaximumResolution = .zero
            item.preferredPeakBitRate = 0
        }
    }
}
