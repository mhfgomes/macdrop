import AppKit
import Combine
import MacDropCore
import SwiftData
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let context: ModelContext
    let paths: AppPaths
    let library: LibraryManager
    let displays: DisplayDiscovery
    let playback: WallpaperPlaybackController
    let launchAtLogin: LaunchAtLoginController
    let lockIntegrator: TahoeLockScreenIntegrator
    let lockPreparer: AVLockAssetPreparer
    let inspector: AVVideoInspector
    let scheduler = PlaylistScheduler()
    let diagnostics: DiagnosticsExporter

    @Published var preferences: AppPreferences
    @Published var importResults: [VideoImportResult] = []
    @Published var isImporting = false
    @Published private(set) var optimizationProgress: [UUID: Double] = [:]
    @Published private(set) var optimizationETA: [UUID: TimeInterval] = [:]
    @Published private(set) var queuedOptimizationIDs: Set<UUID> = []
    @Published private(set) var isLockScreenBusy = false
    @Published private(set) var isDestructiveOperationBusy = false
    @Published private(set) var lockScreenProgressMessage: String?
    @Published var lockHealth = LockScreenHealth(state: .disabled, message: "Lock-screen integration is off.")
    @Published var presentedError: String?
    @Published var selectedSection: SidebarSection = .library

    private var timers: [String: Timer] = [:]
    private var observers: [NSObjectProtocol] = []
    private var policyMonitor: PlaybackPolicyMonitor?
    private var pendingOptimizationIDs: [UUID] = []
    private var activeOptimizationTasks: [UUID: Task<Void, Never>] = [:]
    private var optimizationStartedAt: [UUID: Date] = [:]
    private var userCancelledOptimizationIDs: Set<UUID> = []
    private let maxConcurrentOptimizations = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

    enum SidebarSection: String, CaseIterable, Identifiable {
        case library = "Library"
        case playlists = "Playlists"
        case displays = "Displays"
        case settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .library: "sparkles.rectangle.stack"
            case .playlists: "rectangle.stack"
            case .displays: "display.2"
            case .settings: "gearshape"
            }
        }
    }

    init(container: ModelContainer) {
        self.context = container.mainContext
        self.paths = AppPaths()
        do {
            self.library = try LibraryManager(context: container.mainContext, paths: paths)
        } catch {
            fatalError("MacDrop library could not be initialized: \(error)")
        }
        self.displays = DisplayDiscovery()
        self.playback = WallpaperPlaybackController(paths: paths)
        self.launchAtLogin = LaunchAtLoginController()
        self.lockIntegrator = TahoeLockScreenIntegrator(appPaths: paths)
        self.lockPreparer = AVLockAssetPreparer()
        self.inspector = AVVideoInspector()
        self.diagnostics = DiagnosticsExporter(paths: paths)

        let descriptor = FetchDescriptor<AppPreferences>()
        if let existing = try? container.mainContext.fetch(descriptor).first {
            self.preferences = existing
        } else {
            let preferences = AppPreferences()
            container.mainContext.insert(preferences)
            try? container.mainContext.save()
            self.preferences = preferences
        }

        self.playback.playbackEnded = { [weak self] displayID in
            self?.advanceAfterVideoEnd(on: displayID)
        }

        recoverInterruptedLockPreparationState()
        self.policyMonitor = PlaybackPolicyMonitor(controller: playback) { [weak self] in self?.preferences }
        installObservers()
        refreshSystemState()
        Task { @MainActor [weak self] in self?.resumePendingOptimizations() }
    }

    func importVideos(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        importResults = []
        for url in urls {
            let results = await library.importVideos(from: [url])
            importResults.append(contentsOf: results)
            let importedIDs = results.compactMap(\.wallpaperID)
            if !importedIDs.isEmpty {
                reconcileDisplaysAndAssignments()
                enqueueOptimizations(importedIDs)
            }
        }
        isImporting = false
        let failures = importResults.compactMap { result in result.error.map { "\(result.sourceName): \($0)" } }
        if !failures.isEmpty {
            presentedError = (["Some videos could not be imported:"] + failures).joined(separator: "\n")
        }
    }

    func retryOptimization(_ wallpaper: Wallpaper) {
        userCancelledOptimizationIDs.remove(wallpaper.id)
        wallpaper.lockAssetStatus = .notPrepared
        try? context.save()
        enqueueOptimizations([wallpaper.id])
    }

    func cancelOptimization(_ wallpaper: Wallpaper) {
        let id = wallpaper.id
        if let task = activeOptimizationTasks[id] {
            userCancelledOptimizationIDs.insert(id)
            task.cancel()
            return
        }

        pendingOptimizationIDs.removeAll { $0 == id }
        queuedOptimizationIDs.remove(id)
        optimizationProgress.removeValue(forKey: id)
        optimizationETA.removeValue(forKey: id)
        wallpaper.lockAssetStatus = .cancelled
        try? context.save()
    }

    func openImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor [weak self] in await self?.importVideos(panel.urls) }
        }
    }

    func reconcileDisplaysAndAssignments() {
        displays.refresh()
        playback.reconcileDisplays()
        let wallpapers = fetchWallpapers()
        guard let first = wallpapers.first else { return }
        var assignments = fetchAssignments()
        let mainAssignment = assignments.first { assignment in
            displays.displays.first(where: { $0.isMain })?.id == assignment.displayUUID
        }
        for display in displays.displays where !assignments.contains(where: { $0.displayUUID == display.id }) {
            let source = mainAssignment?.source ?? .wallpaper(first.id)
            let assignment = DisplayAssignment(displayUUID: display.id, source: source)
            context.insert(assignment)
            assignments.append(assignment)
        }
        try? context.save()
        for assignment in assignments where displays.displays.contains(where: { $0.id == assignment.displayUUID }) {
            apply(assignment: assignment)
        }
    }

    func assign(_ wallpaper: Wallpaper, to displayID: String) {
        let assignment = assignment(for: displayID) ?? DisplayAssignment(displayUUID: displayID, source: .wallpaper(wallpaper.id))
        if assignment.modelContext == nil { context.insert(assignment) }
        assignment.source = .wallpaper(wallpaper.id)
        assignment.lastWallpaperID = wallpaper.id
        try? context.save()
        apply(assignment: assignment)
    }

    func assign(_ playlist: Playlist, to displayID: String) {
        let assignment = assignment(for: displayID) ?? DisplayAssignment(displayUUID: displayID, source: .playlist(playlist.id))
        if assignment.modelContext == nil { context.insert(assignment) }
        assignment.source = .playlist(playlist.id)
        assignment.lastWallpaperID = nil
        try? context.save()
        apply(assignment: assignment)
    }

    func createPlaylist(name: String) -> Playlist {
        let playlist = Playlist(name: name)
        context.insert(playlist)
        try? context.save()
        return playlist
    }

    func add(_ wallpaper: Wallpaper, to playlist: Playlist) {
        guard !playlist.entries.contains(where: { $0.wallpaperID == wallpaper.id }) else { return }
        let entry = PlaylistEntry(wallpaperID: wallpaper.id, sortIndex: playlist.entries.count)
        playlist.entries.append(entry)
        try? context.save()
    }

    func remove(_ entry: PlaylistEntry, from playlist: Playlist) {
        playlist.entries.removeAll { $0.id == entry.id }
        context.delete(entry)
        for (index, remaining) in playlist.orderedEntries.enumerated() { remaining.sortIndex = index }
        try? context.save()
        reconcileDisplaysAndAssignments()
    }

    func moveEntries(in playlist: Playlist, from source: IndexSet, to destination: Int) {
        var ordered = playlist.orderedEntries
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, entry) in ordered.enumerated() { entry.sortIndex = index }
        try? context.save()
    }

    func deletePlaylist(_ playlist: Playlist) {
        let fallback = fetchWallpapers().first
        for assignment in fetchAssignments() {
            if case .playlist(let id) = assignment.source, id == playlist.id, let fallback {
                assignment.source = .wallpaper(fallback.id)
                assignment.lastWallpaperID = fallback.id
            }
        }
        context.delete(playlist)
        try? context.save()
        reconcileDisplaysAndAssignments()
    }

    func deleteWallpaper(_ wallpaper: Wallpaper) async {
        if preferences.lockScreenWallpaperID == wallpaper.id {
            await restoreLockScreen()
            guard preferences.lockScreenWallpaperID == nil else { return }
        }
        for playlist in fetchPlaylists() {
            for entry in playlist.entries where entry.wallpaperID == wallpaper.id {
                context.delete(entry)
            }
            playlist.entries.removeAll { $0.wallpaperID == wallpaper.id }
            for (index, entry) in playlist.orderedEntries.enumerated() { entry.sortIndex = index }
        }
        let fallback = fetchWallpapers().first { $0.id != wallpaper.id }
        for assignment in fetchAssignments() where assignment.lastWallpaperID == wallpaper.id {
            if let fallback {
                assignment.source = .wallpaper(fallback.id)
                assignment.lastWallpaperID = fallback.id
            } else {
                context.delete(assignment)
            }
        }
        do {
            try library.delete(wallpaper)
            reconcileDisplaysAndAssignments()
        } catch { presentedError = error.localizedDescription }
    }

    func next(on displayID: String) {
        guard !playback.globallyPaused else { return }
        advancePlaylist(on: displayID)
    }

    private func advancePlaylist(on displayID: String) {
        guard let assignment = assignment(for: displayID), case .playlist(let playlistID) = assignment.source,
              let playlist = fetchPlaylists().first(where: { $0.id == playlistID }) else { return }
        let ids = playlist.orderedEntries.map(\.wallpaperID)
        assignment.lastWallpaperID = scheduler.nextID(in: ids, current: assignment.lastWallpaperID, order: playlist.playbackOrder)
        try? context.save()
        apply(assignment: assignment, resetTimer: false)
    }

    func previous(on displayID: String) {
        guard let assignment = assignment(for: displayID), case .playlist(let playlistID) = assignment.source,
              let playlist = fetchPlaylists().first(where: { $0.id == playlistID }) else { return }
        assignment.lastWallpaperID = scheduler.previousID(in: playlist.orderedEntries.map(\.wallpaperID), current: assignment.lastWallpaperID)
        try? context.save()
        apply(assignment: assignment, resetTimer: false)
    }

    func prepareAndInstallLockScreen(_ wallpaper: Wallpaper) async {
        guard !isLockScreenBusy else {
            presentedError = "A lock-screen wallpaper is already being prepared. Please wait for it to finish."
            return
        }
        isLockScreenBusy = true
        lockScreenProgressMessage = "Applying \(wallpaper.name) to the lock screen…"
        defer {
            isLockScreenBusy = false
            lockScreenProgressMessage = nil
        }
        do {
            let needsOneTimeSystemSelection = (try? lockIntegrator.health().state) == .disabled
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
            let assetURL: URL
            if let cached = paths.lockAssetURL(for: wallpaper), FileManager.default.fileExists(atPath: cached.path) {
                assetURL = cached
            } else {
                wallpaper.lockAssetStatus = .preparing(progress: 0)
                try? context.save()
                lockScreenProgressMessage = "Optimizing \(wallpaper.name)…"
                assetURL = try await lockPreparer.prepare(
                    sourceURL: source,
                    destinationURL: destination,
                    metadata: metadata,
                    progress: { _ in }
                )
            }
            lockScreenProgressMessage = "Applying \(wallpaper.name) to the lock screen…"
            let thumbnailURL = paths.thumbnailURL(for: wallpaper)
            let integrator = lockIntegrator
            let name = wallpaper.name
            try await Task.detached(priority: .userInitiated) {
                try integrator.install(assetURL: assetURL, thumbnailURL: thumbnailURL, name: name)
            }.value
            wallpaper.lockAssetFilename = assetURL.lastPathComponent
            wallpaper.lockAssetStatus = .ready
            preferences.lockScreenEnabled = true
            preferences.lockScreenWallpaperID = wallpaper.id
            try context.save()
            refreshLockHealth()
            if needsOneTimeSystemSelection {
                openWallpaperSettings()
                presentedError = "One-time Tahoe setup: select the borrowed Apple Aerial (currently Tahoe Day) once in System Settings → Wallpaper. MacDrop has already placed your video inside that slot."
            }
        } catch {
            wallpaper.lockAssetStatus = .failed(message: error.localizedDescription)
            try? context.save()
            presentedError = error.localizedDescription
        }
    }

    func restoreLockScreen() async {
        guard !isLockScreenBusy else {
            presentedError = "Please wait for the current lock-screen operation to finish."
            return
        }
        isLockScreenBusy = true
        lockScreenProgressMessage = "Restoring the previous lock screen…"
        defer {
            isLockScreenBusy = false
            lockScreenProgressMessage = nil
        }
        do {
            let integrator = lockIntegrator
            try await Task.detached(priority: .userInitiated) { try integrator.restore() }.value
            preferences.lockScreenEnabled = false
            preferences.lockScreenWallpaperID = nil
            try context.save()
            refreshLockHealth()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func openWallpaperSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLogin.setEnabled(enabled)
            preferences.launchAtLogin = enabled
            try context.save()
        } catch { presentedError = error.localizedDescription }
    }

    func persistPreferences() {
        try? context.save()
        playback.setOcclusionPausingEnabled(preferences.pauseWhenObscured)
        policyMonitor?.refreshAll()
    }

    func toggleManualPause() {
        playback.toggleManualPause()
        objectWillChange.send()
    }

    func exportDiagnostics() async {
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            let archive = try await diagnostics.export(appVersion: version, displays: displays.displays, lockHealth: lockHealth)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = archive.lastPathComponent
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: archive, to: destination)
        } catch { presentedError = error.localizedDescription }
    }

    func resetApplicationData() async {
        guard !isDestructiveOperationBusy else { return }
        isDestructiveOperationBusy = true
        defer { isDestructiveOperationBusy = false }

        do {
            try await performFactoryReset()
            selectedSection = .library
        } catch {
            presentedError = "MacDrop could not be reset: \(error.localizedDescription)"
        }
    }

    func prepareForManualUninstall() async -> Bool {
        guard !isDestructiveOperationBusy else { return false }
        isDestructiveOperationBusy = true
        defer { isDestructiveOperationBusy = false }

        do {
            try await performFactoryReset()
            return true
        } catch {
            presentedError = "MacDrop could not be uninstalled: \(error.localizedDescription)"
            return false
        }
    }

    func finishManualUninstall() {
        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: paths.root.path) {
                var trashedSupportURL: NSURL?
                try manager.trashItem(at: paths.root, resultingItemURL: &trashedSupportURL)
            }
            NSApp.terminate(nil)
        } catch {
            presentedError = "MacDrop could not remove its local data: \(error.localizedDescription)"
        }
    }

    func showMainWindow(openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings(openWindow: OpenWindowAction) {
        selectedSection = .settings
        showMainWindow(openWindow: openWindow)
    }

    func fetchWallpapers() -> [Wallpaper] {
        (try? context.fetch(FetchDescriptor<Wallpaper>(sortBy: [SortDescriptor(\.importedAt, order: .reverse)]))) ?? []
    }

    func fetchPlaylists() -> [Playlist] {
        (try? context.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func fetchAssignments() -> [DisplayAssignment] {
        (try? context.fetch(FetchDescriptor<DisplayAssignment>())) ?? []
    }

    private func resumePendingOptimizations() {
        let ids = fetchWallpapers().compactMap { wallpaper -> UUID? in
            if case .notPrepared = wallpaper.lockAssetStatus { return wallpaper.id }
            return nil
        }
        enqueueOptimizations(ids)
    }

    private func enqueueOptimizations(_ ids: [UUID]) {
        for id in ids where
            !pendingOptimizationIDs.contains(id) &&
            activeOptimizationTasks[id] == nil &&
            optimizationProgress[id] == nil {
            pendingOptimizationIDs.append(id)
            queuedOptimizationIDs.insert(id)
        }
        startPendingOptimizations()
    }

    private func startPendingOptimizations() {
        while activeOptimizationTasks.count < maxConcurrentOptimizations,
              !pendingOptimizationIDs.isEmpty {
            let id = pendingOptimizationIDs.removeFirst()
            queuedOptimizationIDs.remove(id)
            activeOptimizationTasks[id] = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.optimizeWallpaper(id: id)
                self.activeOptimizationTasks.removeValue(forKey: id)
                self.startPendingOptimizations()
            }
        }
    }

    private func optimizeWallpaper(id: UUID) async {
        guard let wallpaper = fetchWallpapers().first(where: { $0.id == id }) else { return }

        wallpaper.lockAssetStatus = .preparing(progress: 0)
        optimizationProgress[id] = 0
        optimizationStartedAt[id] = .now
        try? context.save()

        do {
            try await library.prepareHEVC(for: wallpaper) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.optimizationProgress[id] != nil else { return }
                    let fraction = min(1, max(0, progress))
                    self.optimizationProgress[id] = fraction
                    self.updateOptimizationETA(for: id, progress: fraction)
                }
            }
            optimizationProgress.removeValue(forKey: id)
            optimizationETA.removeValue(forKey: id)
            optimizationStartedAt.removeValue(forKey: id)
            reconcileDisplaysAndAssignments()
        } catch is CancellationError {
            wallpaper.lockAssetStatus = userCancelledOptimizationIDs.remove(id) != nil ? .cancelled : .notPrepared
            optimizationProgress.removeValue(forKey: id)
            optimizationETA.removeValue(forKey: id)
            optimizationStartedAt.removeValue(forKey: id)
            try? context.save()
        } catch {
            wallpaper.lockAssetStatus = .failed(message: error.localizedDescription)
            optimizationProgress.removeValue(forKey: id)
            optimizationETA.removeValue(forKey: id)
            optimizationStartedAt.removeValue(forKey: id)
            try? context.save()
        }
    }

    private func updateOptimizationETA(for id: UUID, progress: Double) {
        guard progress >= 0.02,
              let startedAt = optimizationStartedAt[id] else { return }
        let elapsed = Date.now.timeIntervalSince(startedAt)
        guard elapsed >= 2 else { return }
        let estimate = elapsed * (1 - progress) / progress
        guard estimate.isFinite, estimate >= 0 else { return }
        if let previous = optimizationETA[id] {
            optimizationETA[id] = previous * 0.72 + estimate * 0.28
        } else {
            optimizationETA[id] = estimate
        }
    }

    private func assignment(for displayID: String) -> DisplayAssignment? {
        fetchAssignments().first { $0.displayUUID == displayID }
    }

    private func apply(assignment: DisplayAssignment, resetTimer: Bool = true) {
        switch assignment.source {
        case .wallpaper(let wallpaperID):
            timers[assignment.displayUUID]?.invalidate()
            timers.removeValue(forKey: assignment.displayUUID)
            guard let wallpaper = fetchWallpapers().first(where: { $0.id == wallpaperID }) else { return }
            assignment.lastWallpaperID = wallpaper.id
            playback.play(
                wallpaper: wallpaper,
                on: assignment.displayUUID,
                contentMode: assignment.contentMode,
                advancesOnEnd: false
            )
        case .playlist(let playlistID):
            guard let playlist = fetchPlaylists().first(where: { $0.id == playlistID }) else { return }
            let ids = playlist.orderedEntries.map(\.wallpaperID)
            var currentDuration: TimeInterval?
            if assignment.lastWallpaperID == nil || !ids.contains(assignment.lastWallpaperID!) {
                assignment.lastWallpaperID = scheduler.nextID(in: ids, current: nil, order: playlist.playbackOrder)
            }
            if let wallpaperID = assignment.lastWallpaperID,
               let wallpaper = fetchWallpapers().first(where: { $0.id == wallpaperID }) {
                currentDuration = wallpaper.duration
                playback.play(
                    wallpaper: wallpaper,
                    on: assignment.displayUUID,
                    contentMode: assignment.contentMode,
                    advancesOnEnd: assignment.advanceMode == .videoEnd && ids.count > 1
                )
            }
            if assignment.advanceMode == .interval {
                if resetTimer { scheduleTimer(for: assignment) }
            } else {
                timers[assignment.displayUUID]?.invalidate()
                timers.removeValue(forKey: assignment.displayUUID)
                if ids.count > 1, let currentDuration {
                    scheduleEndFallback(for: assignment, duration: currentDuration)
                }
            }
        }
        try? context.save()
    }

    private func scheduleTimer(for assignment: DisplayAssignment) {
        timers[assignment.displayUUID]?.invalidate()
        let interval = TimeInterval(min(1_440, max(1, assignment.rotationMinutes)) * 60)
        let displayID = assignment.displayUUID
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.next(on: displayID) }
        }
        timer.tolerance = min(60, interval * 0.1)
        timers[displayID] = timer
    }

    private func scheduleEndFallback(for assignment: DisplayAssignment, duration: TimeInterval) {
        let displayID = assignment.displayUUID
        let interval = max(0.5, duration)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let current = self.assignment(for: displayID),
                      current.advanceMode == .videoEnd else { return }
                self.advancePlaylist(on: displayID)
            }
        }
        timer.tolerance = min(0.1, interval * 0.005)
        timers[displayID] = timer
    }

    private func advanceAfterVideoEnd(on displayID: String) {
        guard let assignment = assignment(for: displayID),
              assignment.advanceMode == .videoEnd,
              case .playlist = assignment.source else { return }
        advancePlaylist(on: displayID)
    }

    private func installObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.reconcileDisplaysAndAssignments() } })

        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let integrator = self?.lockIntegrator else { return }
            Task.detached(priority: .utility) {
                integrator.refreshRendererAfterUnlockIfNeeded()
            }
        })
    }

    private func refreshSystemState() {
        preferences.launchAtLogin = launchAtLogin.isEnabled
        playback.setOcclusionPausingEnabled(preferences.pauseWhenObscured)
        reconcileDisplaysAndAssignments()
        refreshLockHealth()
    }

    private func recoverInterruptedLockPreparationState() {
        let wallpapers = (try? context.fetch(FetchDescriptor<Wallpaper>())) ?? []
        var changed = false
        for wallpaper in wallpapers {
            guard case .preparing = wallpaper.lockAssetStatus else { continue }
            if let cachedAsset = paths.lockAssetURL(for: wallpaper),
               FileManager.default.fileExists(atPath: cachedAsset.path) {
                wallpaper.lockAssetStatus = .ready
            } else {
                wallpaper.lockAssetStatus = .notPrepared
            }
            changed = true
        }
        if changed { try? context.save() }
    }

    private func refreshLockHealth() {
        do { lockHealth = try lockIntegrator.health() }
        catch { lockHealth = LockScreenHealth(state: .incompatible, message: error.localizedDescription) }
    }

    private func performFactoryReset() async throws {
        pendingOptimizationIDs.removeAll()
        queuedOptimizationIDs.removeAll()
        userCancelledOptimizationIDs.formUnion(activeOptimizationTasks.keys)
        let optimizationTasks = Array(activeOptimizationTasks.values)
        optimizationTasks.forEach { $0.cancel() }
        for task in optimizationTasks { await task.value }
        activeOptimizationTasks.removeAll()
        optimizationProgress.removeAll()
        optimizationETA.removeAll()
        optimizationStartedAt.removeAll()

        let shouldRestoreLockScreen = preferences.lockScreenEnabled ||
            preferences.lockScreenWallpaperID != nil ||
            lockHealth.state == .healthy ||
            lockHealth.state == .degraded
        if shouldRestoreLockScreen {
            let integrator = lockIntegrator
            try await Task.detached(priority: .userInitiated) {
                try integrator.restore()
            }.value
        }

        try launchAtLogin.setEnabled(false)
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        playback.stopAll()

        for wallpaper in fetchWallpapers() {
            try library.delete(wallpaper)
        }
        for playlist in fetchPlaylists() {
            context.delete(playlist)
        }
        for assignment in fetchAssignments() {
            context.delete(assignment)
        }

        preferences.launchAtLogin = false
        preferences.pauseWhenObscured = true
        preferences.pauseForFullscreenApps = true
        preferences.reduceQualityOnBattery = true
        preferences.pauseOnBattery = false
        preferences.pauseAtSeriousThermalState = true
        preferences.lockScreenEnabled = false
        preferences.lockScreenWallpaperID = nil
        try context.save()

        importResults.removeAll()
        let manager = FileManager.default
        for directory in [paths.backups, paths.logs] where manager.fileExists(atPath: directory.path) {
            var trashedURL: NSURL?
            try manager.trashItem(at: directory, resultingItemURL: &trashedURL)
        }
        try paths.prepare()

        playback.setPaused(false, reason: .manual)
        playback.setOcclusionPausingEnabled(preferences.pauseWhenObscured)
        policyMonitor?.refreshAll()
        refreshLockHealth()
    }
}
