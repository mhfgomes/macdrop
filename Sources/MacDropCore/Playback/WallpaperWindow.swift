import AppKit
import CoreGraphics

@MainActor
final class WallpaperWindow: NSWindow {
    let displayID: String
    let videoView: VideoWallpaperView
    var visibilityChanged: ((Bool) -> Void)?
    private var occlusionObserver: NSObjectProtocol?

    init(displayID: String, frame: NSRect) {
        self.displayID = displayID
        self.videoView = VideoWallpaperView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentView = videoView
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(frame, display: true)
        orderBack(nil)

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.visibilityChanged?(self.occlusionState.contains(.visible))
            }
        }
    }

    func invalidate() {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        visibilityChanged = nil
        videoView.invalidate()
        orderOut(nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
