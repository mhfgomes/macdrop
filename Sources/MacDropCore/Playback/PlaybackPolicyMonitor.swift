import AppKit
import CoreGraphics
import Foundation
import IOKit.ps

@MainActor
public final class PlaybackPolicyMonitor: ObservableObject {
    @Published public private(set) var isOnBattery = false
    @Published public private(set) var thermalState = ProcessInfo.processInfo.thermalState

    private weak var controller: WallpaperPlaybackController?
    private var observers: [NSObjectProtocol] = []
    private var preferences: () -> AppPreferences?

    public init(controller: WallpaperPlaybackController, preferences: @escaping () -> AppPreferences?) {
        self.controller = controller
        self.preferences = preferences
        installObservers()
        refreshPowerState()
        refreshThermalState()
    }

    public func refreshAll() {
        refreshPowerState()
        refreshThermalState()
        refreshFullscreenState()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.refreshPowerState() } })
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.refreshThermalState() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.controller?.setPaused(true, reason: .systemSleep) } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.controller?.reconcileDisplays()
                self?.controller?.setPaused(false, reason: .systemSleep)
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFullscreenState() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFullscreenState() }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFullscreenState() }
        })
    }

    private func refreshPowerState() {
        let type = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String?
        isOnBattery = type == (kIOPSBatteryPowerValue as String)
        guard let preferences = preferences() else { return }
        controller?.setBatteryMode(isOnBattery && preferences.reduceQualityOnBattery)
        controller?.setPaused(isOnBattery && preferences.pauseOnBattery, reason: .battery)
    }

    private func refreshThermalState() {
        thermalState = ProcessInfo.processInfo.thermalState
        guard let preferences = preferences() else { return }
        let pressured = thermalState == .serious || thermalState == .critical
        controller?.setPaused(pressured && preferences.pauseAtSeriousThermalState, reason: .thermalPressure)
    }

    private func refreshFullscreenState() {
        guard let preferences = preferences(), preferences.pauseForFullscreenApps else {
            controller?.setPaused(false, reason: .fullscreenApplication)
            return
        }
        controller?.setPaused(frontmostApplicationHasFullscreenWindow(), reason: .fullscreenApplication)
    }

    private func frontmostApplicationHasFullscreenWindow() -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let windowInfo = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return false
        }

        let screenBounds = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }

        return windowInfo.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? CFDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                return false
            }
            return screenBounds.contains { Self.approximatelyEqual(bounds, $0) }
        }
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 1
        return abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }
}
