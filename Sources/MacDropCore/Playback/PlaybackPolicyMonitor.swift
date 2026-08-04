import AppKit
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
}
