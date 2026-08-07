import AppKit
import CoreGraphics
import Foundation

@MainActor
public final class WallpaperPlaybackController: ObservableObject, WallpaperPlaybackControlling {
    @Published public private(set) var globallyPaused = false
    @Published public private(set) var activeWallpaperIDs: [String: UUID] = [:]
    public var playbackEnded: ((String) -> Void)?

    private let paths: AppPaths
    private var windows: [String: WallpaperWindow] = [:]
    private var stateMachine = PlaybackStateMachine()
    private var displayOccluded: Set<String> = []
    private var pendingOcclusionTasks: [String: Task<Void, Never>] = [:]
    private var batteryMode = false
    private var occlusionPausingEnabled = true
    private let occlusionGracePeriod: Duration = .seconds(2)

    public init(paths: AppPaths = AppPaths()) {
        self.paths = paths
    }

    public func reconcileDisplays() {
        let screensByID = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { (Self.identifier(for: $0), $0) })

        for id in Array(windows.keys) where screensByID[id] == nil {
            pendingOcclusionTasks[id]?.cancel()
            pendingOcclusionTasks.removeValue(forKey: id)
            windows[id]?.videoView.clear()
            windows[id]?.orderOut(nil)
            windows.removeValue(forKey: id)
            activeWallpaperIDs.removeValue(forKey: id)
            displayOccluded.remove(id)
        }

        for (id, screen) in screensByID {
            if let window = windows[id] {
                window.setFrame(screen.frame, display: true)
                window.videoView.setBatteryMode(batteryMode)
                if activeWallpaperIDs[id] == nil {
                    window.orderOut(nil)
                } else {
                    window.orderBack(nil)
                }
            } else {
                let window = WallpaperWindow(displayID: id, frame: screen.frame)
                window.visibilityChanged = { [weak self] visible in
                    self?.handleVisibilityChange(visible, displayID: id)
                }
                window.videoView.playbackEnded = { [weak self] in
                    self?.playbackEnded?(id)
                }
                windows[id] = window
                window.videoView.setBatteryMode(batteryMode)
                window.orderOut(nil)
            }
        }
        applyPlaybackState()
    }

    public func play(
        wallpaper: Wallpaper,
        on displayID: String,
        contentMode: WallpaperContentMode,
        advancesOnEnd: Bool = false
    ) {
        guard let window = windows[displayID] else { return }
        let optimizedURL = paths.lockAssetURL(for: wallpaper)
        let playbackURL = optimizedURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? paths.sourceURL(for: wallpaper)
        window.videoView.load(url: playbackURL, contentMode: contentMode, loops: !advancesOnEnd)
        activeWallpaperIDs[displayID] = wallpaper.id
        window.orderBack(nil)
        applyPlaybackState()
    }

    public func setPaused(_ paused: Bool, reason: PlaybackPauseReason) {
        stateMachine.set(reason, active: paused)
        globallyPaused = stateMachine.isPaused
        applyPlaybackState()
    }

    public func setBatteryMode(_ enabled: Bool) {
        batteryMode = enabled
        windows.values.forEach { $0.videoView.setBatteryMode(enabled) }
    }

    public func setOcclusionPausingEnabled(_ enabled: Bool) {
        occlusionPausingEnabled = enabled
        if !enabled {
            pendingOcclusionTasks.values.forEach { $0.cancel() }
            pendingOcclusionTasks.removeAll()
            displayOccluded.removeAll()
        }
        applyPlaybackState()
    }

    public func toggleManualPause() {
        setPaused(!stateMachine.reasons.contains(.manual), reason: .manual)
    }

    public func stopAll() {
        pendingOcclusionTasks.values.forEach { $0.cancel() }
        pendingOcclusionTasks.removeAll()
        displayOccluded.removeAll()
        for window in windows.values {
            window.videoView.clear()
            window.orderOut(nil)
        }
        windows.removeAll()
        activeWallpaperIDs.removeAll()
    }

    private func handleVisibilityChange(_ visible: Bool, displayID: String) {
        pendingOcclusionTasks[displayID]?.cancel()
        pendingOcclusionTasks.removeValue(forKey: displayID)

        if visible {
            displayOccluded.remove(displayID)
            applyPlaybackState()
            return
        }

        // A wallpaper window is briefly reported as occluded while macOS animates
        // between Spaces. Delay the pause so those transient events never stop video.
        pendingOcclusionTasks[displayID] = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.occlusionGracePeriod ?? .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingOcclusionTasks.removeValue(forKey: displayID)
            self.displayOccluded.insert(displayID)
            self.applyPlaybackState()
        }
    }

    private func applyPlaybackState() {
        for (id, window) in windows {
            let shouldPause = stateMachine.isPaused || (occlusionPausingEnabled && displayOccluded.contains(id))
            if shouldPause { window.videoView.pause() } else { window.videoView.resume() }
        }
    }

    public static func identifier(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let displayID = CGDirectDisplayID(number?.uint32Value ?? 0)
        return CGDisplayCreateUUIDFromDisplayID(displayID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            ?? "display-\(displayID)"
    }
}
