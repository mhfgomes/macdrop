import CryptoKit
import Foundation

public enum LockScreenIntegrationError: LocalizedError, Equatable {
    case unsupportedOS
    case missingWallpaperData(String)
    case incompatibleSchema(String)
    case backupFailed(String)
    case mutationFailed(String)
    case verificationFailed(String)
    case noBackup

    public var errorDescription: String? {
        switch self {
        case .unsupportedOS: "Lock-screen integration requires macOS 26 Tahoe or newer."
        case .missingWallpaperData(let path): "Required wallpaper data is missing: \(path)"
        case .incompatibleSchema(let reason): "This macOS wallpaper format is not supported: \(reason)"
        case .backupFailed(let reason): "MacDrop could not back up the wallpaper configuration: \(reason)"
        case .mutationFailed(let reason): "MacDrop could not update the lock-screen wallpaper: \(reason)"
        case .verificationFailed(let reason): "The wallpaper update could not be verified: \(reason)"
        case .noBackup: "No MacDrop lock-screen backup is available to restore."
        }
    }
}

private struct IntegrationState: Codable {
    let active: Bool
    let assetID: String
    let backupDirectory: String
    let installedAt: Date
    let borrowedAssetID: String?
    let borrowedSlotPath: String?
    let installedVideoSHA256: String?
}

private struct BackupMetadata: Codable {
    let createdAt: Date
    let operatingSystem: String
    let entriesSHA256: String
    let indexSHA256: String
    let borrowedAssetID: String?
    let slotSHA256: String?
}

public final class TahoeLockScreenIntegrator: LockScreenIntegrating, @unchecked Sendable {
    public static let categoryID = "4D414344-524F-5000-8000-000000000001"
    public static let subcategoryID = "4D414344-524F-5000-8000-000000000002"
    public static let assetID = "4D414344-524F-5000-8000-000000000003"

    private let appPaths: AppPaths
    private let home: URL
    private let fileManager: FileManager
    private let agentRestarter: @Sendable () throws -> Void

    private var aerialsRoot: URL { home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials") }
    private var videosDirectory: URL { aerialsRoot.appendingPathComponent("videos") }
    private var thumbnailsDirectory: URL { aerialsRoot.appendingPathComponent("thumbnails") }
    private var entriesURL: URL { aerialsRoot.appendingPathComponent("manifest/entries.json") }
    private var indexURL: URL { home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist") }
    private var stateURL: URL { appPaths.root.appendingPathComponent("lock-screen-state.json") }
    private var installedVideoURL: URL { videosDirectory.appendingPathComponent("\(Self.assetID).mov") }
    private var installedThumbnailURL: URL { thumbnailsDirectory.appendingPathComponent("\(Self.assetID).jpg") }
    private static let slotBackupFilename = "aerial-slot.original.mov"

    public init(
        appPaths: AppPaths = AppPaths(),
        home: URL? = nil,
        fileManager: FileManager = .default,
        agentRestarter: (@Sendable () throws -> Void)? = nil
    ) {
        self.appPaths = appPaths
        self.home = home ?? fileManager.homeDirectoryForCurrentUser
        self.fileManager = fileManager
        self.agentRestarter = agentRestarter ?? { try Self.restartSystemWallpaperAgent() }
    }

    public func health() throws -> LockScreenHealth {
        guard let state = try loadState(), state.active else {
            return LockScreenHealth(state: .disabled, message: "Lock-screen integration is off.")
        }
        if state.borrowedAssetID == nil,
           (!fileManager.fileExists(atPath: installedVideoURL.path)
            || !fileManager.fileExists(atPath: installedThumbnailURL.path)) {
            return LockScreenHealth(state: .degraded, message: "The legacy MacDrop registration needs to be reapplied for Tahoe's Aerial renderer.", lastBackup: state.installedAt)
        }
        do {
            if let borrowedAssetID = state.borrowedAssetID,
               let borrowedSlotPath = state.borrowedSlotPath,
               let installedHash = state.installedVideoSHA256 {
                let slotURL = URL(fileURLWithPath: borrowedSlotPath)
                guard fileManager.fileExists(atPath: slotURL.path),
                      try sha256(of: slotURL) == installedHash else {
                    return LockScreenHealth(state: .degraded, message: "The borrowed Apple Aerial slot no longer contains MacDrop's video.", lastBackup: state.installedAt)
                }
                guard indexSelectsAsset(try loadIndex(), assetID: borrowedAssetID) else {
                    return LockScreenHealth(state: .degraded, message: "The borrowed Aerial is installed, but it is not selected for the lock screen.", lastBackup: state.installedAt)
                }
                return LockScreenHealth(state: .healthy, message: "MacDrop is installed in Apple Aerial slot \(borrowedAssetID).", lastBackup: state.installedAt)
            }
            return LockScreenHealth(state: .degraded, message: "The legacy lock-screen setup must be applied again.", lastBackup: state.installedAt)
        } catch LockScreenIntegrationError.incompatibleSchema(let message) {
            return LockScreenHealth(state: .incompatible, message: message, lastBackup: state.installedAt)
        }
    }

    public func install(assetURL: URL, thumbnailURL: URL, name: String) throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            throw LockScreenIntegrationError.unsupportedOS
        }
        try appPaths.prepare()
        let entries = try loadEntries()
        let index = try loadIndex()
        let existingState = try loadState()
        let slot = try findBorrowedAerialSlot(in: entries, preferredID: existingState?.borrowedAssetID)
        let rollbackBackup = try createBackup(slot: slot.url, assetID: slot.assetID)
        let persistentBackup: URL
        if let existingState, existingState.active {
            persistentBackup = URL(fileURLWithPath: existingState.backupDirectory, isDirectory: true)
            try verifyBackup(at: persistentBackup)
            try ensureSlotBackup(at: persistentBackup, slot: slot.url, assetID: slot.assetID)
        } else {
            persistentBackup = rollbackBackup
        }

        do {
            try atomicCopy(from: assetURL, to: slot.url)

            let updatedEntries = removingMacDropAsset(from: entries)
            let updatedIndex = settingIdleChoice(in: index, assetID: slot.assetID)
            try atomicWriteJSON(updatedEntries, to: entriesURL)
            try atomicWritePlist(updatedIndex, to: indexURL)
            try agentRestarter()

            let installedHash = try sha256(of: slot.url)
            guard indexSelectsAsset(try loadIndex(), assetID: slot.assetID),
                  installedHash == (try sha256(of: assetURL)) else {
                throw LockScreenIntegrationError.verificationFailed("The borrowed Aerial slot was not installed and selected after WallpaperAgent restarted.")
            }
            try? fileManager.removeItem(at: installedVideoURL)
            try? fileManager.removeItem(at: installedThumbnailURL)
            let state = IntegrationState(
                active: true,
                assetID: slot.assetID,
                backupDirectory: persistentBackup.path,
                installedAt: .now,
                borrowedAssetID: slot.assetID,
                borrowedSlotPath: slot.url.path,
                installedVideoSHA256: installedHash
            )
            try atomicWriteEncodable(state, to: stateURL)
        } catch {
            try? restoreExactBackup(from: rollbackBackup)
            try? restoreSlotBackup(from: rollbackBackup, to: slot.url)
            try? agentRestarter()
            if let integrationError = error as? LockScreenIntegrationError { throw integrationError }
            throw LockScreenIntegrationError.mutationFailed(error.localizedDescription)
        }
    }

    public func restore() throws {
        guard let state = try loadState() else { throw LockScreenIntegrationError.noBackup }
        let backupDirectory = URL(fileURLWithPath: state.backupDirectory, isDirectory: true)
        guard fileManager.fileExists(atPath: backupDirectory.path) else { throw LockScreenIntegrationError.noBackup }
        try verifyBackup(at: backupDirectory)

        let currentEntries = try loadEntries()
        let currentIndex = try loadIndex()
        let backupIndex = try loadPlistDictionary(backupDirectory.appendingPathComponent("Index.plist"))

        let cleanedEntries = removingMacDropAsset(from: currentEntries)
        let restoredIndex = restoreOwnedIdleChoices(current: currentIndex, backup: backupIndex, assetID: state.assetID)
        try atomicWriteJSON(cleanedEntries, to: entriesURL)
        try atomicWritePlist(restoredIndex, to: indexURL)
        if let slotPath = state.borrowedSlotPath {
            try restoreSlotBackup(from: backupDirectory, to: URL(fileURLWithPath: slotPath))
        }
        try? fileManager.removeItem(at: installedVideoURL)
        try? fileManager.removeItem(at: installedThumbnailURL)
        try agentRestarter()

        let stillOwnsSelection: Bool
        if state.borrowedAssetID == nil {
            stillOwnsSelection = indexSelectsAsset(try loadIndex(), assetID: state.assetID)
        } else {
            stillOwnsSelection = false
        }
        guard !entriesContainsMacDropAsset(try loadEntries()), !stillOwnsSelection else {
            try? restoreExactBackup(from: backupDirectory)
            throw LockScreenIntegrationError.verificationFailed("MacDrop's manifest entry could not be removed.")
        }
        try? fileManager.removeItem(at: stateURL)
    }

    public func backupFolderURL() -> URL { appPaths.backups }

    public func refreshRendererAfterUnlockIfNeeded() {
        guard let state = try? loadState(), state.active, state.borrowedAssetID != nil else { return }
        Self.terminateProcess(named: "WallpaperAerialsExtension")
    }

    private func loadEntries() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: entriesURL.path) else {
            throw LockScreenIntegrationError.missingWallpaperData(entriesURL.path)
        }
        let entries = try loadJSONDictionary(entriesURL)
        guard entries["categories"] is [[String: Any]], entries["assets"] is [[String: Any]] else {
            throw LockScreenIntegrationError.incompatibleSchema("The Aerials manifest does not contain category and asset arrays.")
        }
        if let version = entries["version"] as? Int, !(1...100).contains(version) {
            throw LockScreenIntegrationError.incompatibleSchema("Unknown Aerials manifest version \(version).")
        }
        return entries
    }

    private func loadIndex() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            throw LockScreenIntegrationError.missingWallpaperData(indexURL.path)
        }
        let index = try loadPlistDictionary(indexURL)
        guard !index.isEmpty else {
            throw LockScreenIntegrationError.incompatibleSchema("The wallpaper store is empty.")
        }
        return index
    }

    private func loadJSONDictionary(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LockScreenIntegrationError.incompatibleSchema("\(url.lastPathComponent) is not a dictionary.")
        }
        return dictionary
    }

    private func loadPlistDictionary(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw LockScreenIntegrationError.incompatibleSchema("\(url.lastPathComponent) is not a dictionary.")
        }
        return dictionary
    }

    private func addingMacDropAsset(to source: [String: Any], name: String) throws -> [String: Any] {
        var result = source
        var categories = result["categories"] as? [[String: Any]] ?? []
        var assets = result["assets"] as? [[String: Any]] ?? []
        let videoURL = installedVideoURL.absoluteString
        let thumbnailURL = installedThumbnailURL.absoluteString
        let category: [String: Any] = [
            "id": Self.categoryID,
            "localizedNameKey": "MacDrop",
            "localizedDescriptionKey": "MacDrop video wallpapers",
            "preferredOrder": 900,
            "representativeAssetID": Self.assetID,
            "previewImage": thumbnailURL,
            "subcategories": [[
                "id": Self.subcategoryID,
                "localizedNameKey": "MacDrop",
                "localizedDescriptionKey": "MacDrop video wallpapers",
                "preferredOrder": 0,
                "representativeAssetID": Self.assetID,
                "previewImage": thumbnailURL
            ]]
        ]
        let asset: [String: Any] = [
            "id": Self.assetID,
            "localizedNameKey": name,
            "accessibilityLabel": name,
            "shotID": "MACDROP_CUSTOM",
            "showInTopLevel": true,
            "includeInShuffle": false,
            "preferredOrder": 0,
            "categories": [Self.categoryID],
            "subcategories": [Self.subcategoryID],
            "url-4K-SDR-240FPS": videoURL,
            "previewImage": thumbnailURL,
            "pointsOfInterest": ["0": "MACDROP_0"]
        ]
        categories.removeAll { ($0["id"] as? String) == Self.categoryID }
        assets.removeAll { ($0["id"] as? String) == Self.assetID || (($0["categories"] as? [String])?.contains(Self.categoryID) == true) }
        categories.append(category)
        assets.append(asset)
        result["categories"] = categories
        result["assets"] = assets
        return result
    }

    private func removingMacDropAsset(from source: [String: Any]) -> [String: Any] {
        var result = source
        if var categories = result["categories"] as? [[String: Any]] {
            categories.removeAll { ($0["id"] as? String) == Self.categoryID }
            result["categories"] = categories
        }
        if var assets = result["assets"] as? [[String: Any]] {
            assets.removeAll { ($0["id"] as? String) == Self.assetID || (($0["categories"] as? [String])?.contains(Self.categoryID) == true) }
            result["assets"] = assets
        }
        return result
    }

    private func entriesContainsMacDropAsset(_ entries: [String: Any]) -> Bool {
        (entries["assets"] as? [[String: Any]])?.contains { ($0["id"] as? String) == Self.assetID } == true
    }

    private func settingIdleChoice(in source: [String: Any], assetID: String) -> [String: Any] {
        let config: [String: Any] = ["assetID": assetID]
        let configData = try? PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0)
        let choice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.aerials",
            "Files": [],
            "Configuration": configData ?? Data()
        ]
        let replacement: [String: Any] = [
            "Content": ["Choices": [choice], "EncodedOptionValues": "$null", "Shuffle": "$null"],
            "LastSet": Date(),
            "LastUse": Date()
        ]
        return transformDictionaries(source) { dictionary in
            var dictionary = dictionary
            switch dictionary["Type"] as? String {
            case "linked", "individual", "idle":
                // Tahoe 26.6 resolves an Idle-only Aerial choice but keeps its
                // player in still mode on the real lock screen. Selecting an
                // Aerial in System Settings writes a linked choice; mirror that
                // proven structure so the renderer enters motion mode. MacDrop's
                // desktop windows remain independent and cover this system base.
                dictionary["Type"] = "linked"
                dictionary["Linked"] = replacement
                dictionary.removeValue(forKey: "Desktop")
                dictionary.removeValue(forKey: "Idle")
            default:
                break
            }
            return dictionary
        }
    }

    private func restoreOwnedIdleChoices(current: [String: Any], backup: [String: Any], assetID: String) -> [String: Any] {
        restoreDictionary(current: current, backup: backup, assetID: assetID)
    }

    private func restoreDictionary(current: [String: Any], backup: [String: Any], assetID: String) -> [String: Any] {
        var result = current
        var restoredSelectionKeys = Set<String>()
        let ownsLinkedChoice = (current["Type"] as? String) == "linked"
            && current["Linked"].map { containsAssetID($0, assetID: assetID) } == true
        let ownsIdleChoice = current["Idle"].map { containsAssetID($0, assetID: assetID) } == true
        if ownsLinkedChoice || ownsIdleChoice {
            if (backup["Type"] as? String) == "linked",
               let linked = backup["Linked"] as? [String: Any] {
                result["Type"] = "linked"
                result["Linked"] = linked
                result.removeValue(forKey: "Desktop")
                result.removeValue(forKey: "Idle")
                restoredSelectionKeys.formUnion(["Type", "Linked", "Desktop", "Idle"])
            } else {
                if let oldType = backup["Type"] { result["Type"] = oldType }
                if let oldDesktop = backup["Desktop"] { result["Desktop"] = oldDesktop }
                else { result.removeValue(forKey: "Desktop") }
                if let oldIdle = backup["Idle"] { result["Idle"] = oldIdle }
                else { result.removeValue(forKey: "Idle") }
                result.removeValue(forKey: "Linked")
                restoredSelectionKeys.formUnion(["Type", "Linked", "Desktop", "Idle"])
            }
        }
        for (key, value) in current {
            if restoredSelectionKeys.contains(key) { continue }
            if let child = value as? [String: Any], let backupChild = backup[key] as? [String: Any] {
                result[key] = restoreDictionary(current: child, backup: backupChild, assetID: assetID)
            }
        }
        return result
    }

    private func transformDictionaries(_ dictionary: [String: Any], transform: ([String: Any]) -> [String: Any]) -> [String: Any] {
        var mapped = dictionary
        for (key, value) in dictionary {
            if let child = value as? [String: Any] {
                mapped[key] = transformDictionaries(child, transform: transform)
            }
        }
        return transform(mapped)
    }

    private func containsAssetID(_ object: Any, assetID: String) -> Bool {
        if let value = object as? String { return value == assetID }
        if let data = object as? Data,
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            return containsAssetID(plist, assetID: assetID)
        }
        if let array = object as? [Any] { return array.contains { containsAssetID($0, assetID: assetID) } }
        if let dictionary = object as? [String: Any] { return dictionary.values.contains { containsAssetID($0, assetID: assetID) } }
        return false
    }

    private func indexSelectsAsset(_ index: [String: Any], assetID: String) -> Bool {
        func selectionContainsAsset(_ object: Any) -> Bool {
            guard let dictionary = object as? [String: Any] else { return false }
            if let idle = dictionary["Idle"] as? [String: Any], containsAssetID(idle, assetID: assetID) { return true }
            if (dictionary["Type"] as? String) == "linked",
               let linked = dictionary["Linked"] as? [String: Any],
               containsAssetID(linked, assetID: assetID) { return true }
            return dictionary.values.contains(where: selectionContainsAsset)
        }
        return selectionContainsAsset(index)
    }

    private struct BorrowedAerialSlot {
        let assetID: String
        let url: URL
    }

    private func findBorrowedAerialSlot(in entries: [String: Any], preferredID: String?) throws -> BorrowedAerialSlot {
        let assets = entries["assets"] as? [[String: Any]] ?? []
        let candidates = assets.compactMap { asset -> BorrowedAerialSlot? in
            guard let id = asset["id"] as? String,
                  id != Self.assetID,
                  !((asset["categories"] as? [String])?.contains(Self.categoryID) == true),
                  let remote = asset["url-4K-SDR-240FPS"] as? String,
                  let scheme = URL(string: remote)?.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return nil }
            let local = videosDirectory.appendingPathComponent("\(id).mov")
            guard fileManager.fileExists(atPath: local.path) else { return nil }
            return BorrowedAerialSlot(assetID: id, url: local)
        }.sorted { $0.assetID < $1.assetID }

        if let preferredID, let preferred = candidates.first(where: { $0.assetID == preferredID }) {
            return preferred
        }
        guard let slot = candidates.first else {
            throw LockScreenIntegrationError.missingWallpaperData(
                "Download one Apple Aerial in System Settings → Wallpaper before enabling the lock screen."
            )
        }
        return slot
    }

    private func createBackup(slot: URL, assetID: String) throws -> URL {
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let directory = appPaths.backups.appendingPathComponent(formatter.string(from: .now), isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let entriesData = try Data(contentsOf: entriesURL)
            let indexData = try Data(contentsOf: indexURL)
            try entriesData.write(to: directory.appendingPathComponent("entries.json"), options: .atomic)
            try indexData.write(to: directory.appendingPathComponent("Index.plist"), options: .atomic)
            try Data(contentsOf: slot).write(
                to: directory.appendingPathComponent(Self.slotBackupFilename),
                options: .atomic
            )
            let metadata = BackupMetadata(
                createdAt: .now,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                entriesSHA256: SHA256.hash(data: entriesData).hexString,
                indexSHA256: SHA256.hash(data: indexData).hexString,
                borrowedAssetID: assetID,
                slotSHA256: try sha256(of: slot)
            )
            try atomicWriteEncodable(metadata, to: directory.appendingPathComponent("backup.json"))
            return directory
        } catch {
            throw LockScreenIntegrationError.backupFailed(error.localizedDescription)
        }
    }

    private func verifyBackup(at directory: URL) throws {
        do {
            let entriesData = try Data(contentsOf: directory.appendingPathComponent("entries.json"))
            let indexData = try Data(contentsOf: directory.appendingPathComponent("Index.plist"))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(
                BackupMetadata.self,
                from: Data(contentsOf: directory.appendingPathComponent("backup.json"))
            )
            guard SHA256.hash(data: entriesData).hexString == metadata.entriesSHA256,
                  SHA256.hash(data: indexData).hexString == metadata.indexSHA256 else {
                throw LockScreenIntegrationError.backupFailed("Backup checksums do not match.")
            }
            if let slotHash = metadata.slotSHA256 {
                let slotBackup = directory.appendingPathComponent(Self.slotBackupFilename)
                guard fileManager.fileExists(atPath: slotBackup.path),
                      try sha256(of: slotBackup) == slotHash else {
                    throw LockScreenIntegrationError.backupFailed("The borrowed Aerial backup checksum does not match.")
                }
            }
        } catch let error as LockScreenIntegrationError {
            throw error
        } catch {
            throw LockScreenIntegrationError.backupFailed(error.localizedDescription)
        }
    }

    private func restoreExactBackup(from directory: URL) throws {
        try atomicCopy(from: directory.appendingPathComponent("entries.json"), to: entriesURL)
        try atomicCopy(from: directory.appendingPathComponent("Index.plist"), to: indexURL)
    }

    private func ensureSlotBackup(at directory: URL, slot: URL, assetID: String) throws {
        let destination = directory.appendingPathComponent(Self.slotBackupFilename)
        if fileManager.fileExists(atPath: destination.path) {
            try verifyBackup(at: directory)
            return
        }
        try atomicCopy(from: slot, to: destination)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadataURL = directory.appendingPathComponent("backup.json")
        let old = try decoder.decode(BackupMetadata.self, from: Data(contentsOf: metadataURL))
        let updated = BackupMetadata(
            createdAt: old.createdAt,
            operatingSystem: old.operatingSystem,
            entriesSHA256: old.entriesSHA256,
            indexSHA256: old.indexSHA256,
            borrowedAssetID: assetID,
            slotSHA256: try sha256(of: destination)
        )
        try atomicWriteEncodable(updated, to: metadataURL)
        try verifyBackup(at: directory)
    }

    private func restoreSlotBackup(from directory: URL, to slot: URL) throws {
        let backup = directory.appendingPathComponent(Self.slotBackupFilename)
        guard fileManager.fileExists(atPath: backup.path) else { return }
        try atomicCopy(from: backup, to: slot)
    }

    private func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).hexString
    }

    private func loadState() throws -> IntegrationState? {
        guard fileManager.fileExists(atPath: stateURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IntegrationState.self, from: Data(contentsOf: stateURL))
    }

    private func atomicCopy(from source: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private func atomicWriteJSON(_ dictionary: [String: Any], to destination: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(data, to: destination)
    }

    private func atomicWritePlist(_ dictionary: [String: Any], to destination: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        try atomicWrite(data, to: destination)
    }

    private func atomicWriteEncodable<T: Encodable>(_ value: T, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try atomicWrite(encoder.encode(value), to: destination)
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private static func restartSystemWallpaperAgent() throws {
        terminateProcess(named: "WallpaperAerialsExtension")
        terminateProcess(named: "WallpaperAgent")

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            probe.arguments = ["-x", "WallpaperAgent"]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            try probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus == 0 { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw LockScreenIntegrationError.verificationFailed("WallpaperAgent did not restart within five seconds.")
    }

    private static func terminateProcess(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = [name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
