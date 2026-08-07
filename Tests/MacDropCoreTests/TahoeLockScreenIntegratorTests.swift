import Foundation
import XCTest
import MacDropCore

final class TahoeLockScreenIntegratorTests: XCTestCase {
    func testInstallUsesLinkedAerialChoiceAndRestoresPreviousChoice() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalEntries = try Data(contentsOf: fixture.entriesURL)

        let integrator = TahoeLockScreenIntegrator(
            appPaths: fixture.appPaths,
            home: fixture.home,
            agentRestarter: {}
        )
        try integrator.install(assetURL: fixture.videoURL, thumbnailURL: fixture.thumbnailURL, name: "Test Loop")
        XCTAssertEqual(try integrator.health().state, .healthy)

        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.entriesURL)) as? [String: Any]
        let assets = installed?["assets"] as? [[String: Any]]
        XCTAssertFalse(assets?.contains { ($0["id"] as? String) == TahoeLockScreenIntegrator.assetID } == true)
        XCTAssertTrue(assets?.contains { ($0["id"] as? String) == "11111111-2222-4333-8444-555555555555" } == true)

        let installedIndex = try PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.indexURL), format: nil) as? [String: Any]
        let installedDefault = installedIndex?["SystemDefault"] as? [String: Any]
        XCTAssertEqual(installedDefault?["Type"] as? String, "linked")
        XCTAssertEqual(Self.provider(in: installedDefault?["Linked"]), "com.apple.wallpaper.choice.aerials")
        XCTAssertNil(installedDefault?["Desktop"])
        XCTAssertNil(installedDefault?["Idle"])
        XCTAssertEqual(try Data(contentsOf: fixture.slotURL), try Data(contentsOf: fixture.videoURL))

        try integrator.restore()
        XCTAssertEqual(try integrator.health().state, .disabled)
        XCTAssertEqual(try Data(contentsOf: fixture.entriesURL), originalEntries)

        let restoredIndex = try PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.indexURL), format: nil) as? [String: Any]
        let systemDefault = restoredIndex?["SystemDefault"] as? [String: Any]
        XCTAssertEqual(systemDefault?["Type"] as? String, "linked")
        XCTAssertNil(systemDefault?["Idle"])
        XCTAssertNil(systemDefault?["Desktop"])
        XCTAssertEqual(Self.provider(in: systemDefault?["Linked"]), "fixture.previous")
        XCTAssertEqual(try Data(contentsOf: fixture.slotURL), fixture.slotOriginalData)
    }

    func testHealthDetectsManifestEntryThatIsNotSelected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalIndex = try Data(contentsOf: fixture.indexURL)
        let integrator = TahoeLockScreenIntegrator(appPaths: fixture.appPaths, home: fixture.home, agentRestarter: {})
        try integrator.install(assetURL: fixture.videoURL, thumbnailURL: fixture.thumbnailURL, name: "Test")
        try originalIndex.write(to: fixture.indexURL)
        XCTAssertEqual(try integrator.health().state, .degraded)
    }

    func testUnknownManifestVersionIsRejectedWithoutMutation() throws {
        let fixture = try Fixture(version: 10_000)
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.entriesURL)
        let integrator = TahoeLockScreenIntegrator(appPaths: fixture.appPaths, home: fixture.home, agentRestarter: {})
        XCTAssertThrowsError(try integrator.install(assetURL: fixture.videoURL, thumbnailURL: fixture.thumbnailURL, name: "Test"))
        XCTAssertEqual(try Data(contentsOf: fixture.entriesURL), before)
    }

    func testRestoreRejectsCorruptedBackup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let integrator = TahoeLockScreenIntegrator(appPaths: fixture.appPaths, home: fixture.home, agentRestarter: {})
        try integrator.install(assetURL: fixture.videoURL, thumbnailURL: fixture.thumbnailURL, name: "Test")
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.appPaths.backups, includingPropertiesForKeys: nil).first)
        try Data("corrupted".utf8).write(to: backup.appendingPathComponent("entries.json"))
        XCTAssertThrowsError(try integrator.restore())
        XCTAssertEqual(try integrator.health().state, .healthy)
    }

    func testHealthRollsBackInterruptedInstallJournal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalEntries = try Data(contentsOf: fixture.entriesURL)
        let originalIndex = try Data(contentsOf: fixture.indexURL)
        let integrator = TahoeLockScreenIntegrator(appPaths: fixture.appPaths, home: fixture.home, agentRestarter: {})
        try integrator.install(assetURL: fixture.videoURL, thumbnailURL: fixture.thumbnailURL, name: "Test")

        let journalURL = fixture.appPaths.root.appendingPathComponent("lock-screen-operation-journal.json")
        var journal = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        )
        journal["status"] = "inProgress"
        try JSONSerialization.data(withJSONObject: journal, options: [.prettyPrinted, .sortedKeys])
            .write(to: journalURL, options: .atomic)

        XCTAssertEqual(try integrator.health().state, .disabled)
        XCTAssertEqual(try Data(contentsOf: fixture.entriesURL), originalEntries)
        XCTAssertEqual(try Data(contentsOf: fixture.indexURL), originalIndex)
        XCTAssertEqual(try Data(contentsOf: fixture.slotURL), fixture.slotOriginalData)

        let recovered = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        )
        XCTAssertEqual(recovered["status"] as? String, "rolledBack")
    }

    func testReinstallWithDifferentAerialUsesNewPersistentBackup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let integrator = TahoeLockScreenIntegrator(appPaths: fixture.appPaths, home: fixture.home, agentRestarter: {})
        try integrator.install(assetURL: fixture.videoURL, thumbnailURL: fixture.thumbnailURL, name: "First")

        let firstBackup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.appPaths.backups,
                includingPropertiesForKeys: nil
            ).first
        )
        let firstSlotBackup = firstBackup.appendingPathComponent("aerial-slot.original.mov")
        let firstSlotBackupData = try Data(contentsOf: firstSlotBackup)

        let replacementAssetID = "66666666-7777-4888-8999-AAAAAAAAAAAA"
        let replacementSlot = fixture.slotURL.deletingLastPathComponent()
            .appendingPathComponent("\(replacementAssetID).mov")
        let replacementOriginalData = Data("replacement-apple-aerial".utf8)
        try replacementOriginalData.write(to: replacementSlot)
        try FileManager.default.removeItem(at: fixture.slotURL)
        let replacementAsset: [String: Any] = [
            "id": replacementAssetID,
            "categories": ["fixture.apple"],
            "url-4K-SDR-240FPS": "https://example.invalid/replacement-aerial.mov"
        ]
        let replacementEntries: [String: Any] = [
            "version": 1,
            "categories": [],
            "assets": [replacementAsset]
        ]
        try JSONSerialization.data(
            withJSONObject: replacementEntries,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: fixture.entriesURL)

        Thread.sleep(forTimeInterval: 0.01)
        try integrator.install(assetURL: fixture.videoURL, thumbnailURL: fixture.thumbnailURL, name: "Second")

        let state = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.appPaths.root.appendingPathComponent("lock-screen-state.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(state["borrowedAssetID"] as? String, replacementAssetID)
        let secondBackup = URL(
            fileURLWithPath: try XCTUnwrap(state["backupDirectory"] as? String),
            isDirectory: true
        )
        XCTAssertNotEqual(secondBackup.standardizedFileURL, firstBackup.standardizedFileURL)

        let firstMetadata = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: firstBackup.appendingPathComponent("backup.json"))
            ) as? [String: Any]
        )
        let secondMetadata = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: secondBackup.appendingPathComponent("backup.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(firstMetadata["borrowedAssetID"] as? String, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(secondMetadata["borrowedAssetID"] as? String, replacementAssetID)
        XCTAssertEqual(try Data(contentsOf: firstSlotBackup), firstSlotBackupData)

        try integrator.restore()
        XCTAssertEqual(try Data(contentsOf: replacementSlot), replacementOriginalData)
        XCTAssertEqual(try Data(contentsOf: firstSlotBackup), fixture.slotOriginalData)
    }

    private static func provider(in selection: Any?) -> String? {
        let selection = selection as? [String: Any]
        let content = selection?["Content"] as? [String: Any]
        let choices = content?["Choices"] as? [[String: Any]]
        return choices?.first?["Provider"] as? String
    }
}

private final class Fixture {
    let root: URL
    let home: URL
    let appPaths: AppPaths
    let entriesURL: URL
    let indexURL: URL
    let videoURL: URL
    let thumbnailURL: URL
    let slotURL: URL
    let slotOriginalData = Data("apple-aerial-fixture".utf8)

    init(version: Int = 1) throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacDropTests-\(UUID().uuidString)")
        let fixtureHome = fixtureRoot.appendingPathComponent("home")
        root = fixtureRoot
        home = fixtureHome
        appPaths = AppPaths(root: fixtureRoot.appendingPathComponent("app"))
        entriesURL = fixtureHome.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json")
        indexURL = fixtureHome.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        videoURL = fixtureRoot.appendingPathComponent("input.mov")
        thumbnailURL = fixtureRoot.appendingPathComponent("thumbnail.jpg")
        slotURL = fixtureHome.appendingPathComponent(
            "Library/Application Support/com.apple.wallpaper/aerials/videos/11111111-2222-4333-8444-555555555555.mov"
        )
        try FileManager.default.createDirectory(at: entriesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: slotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try appPaths.prepare()

        let appleAsset: [String: Any] = [
            "id": "11111111-2222-4333-8444-555555555555",
            "categories": ["fixture.apple"],
            "url-4K-SDR-240FPS": "https://example.invalid/apple-aerial.mov"
        ]
        let entries: [String: Any] = ["version": version, "categories": [], "assets": [appleAsset]]
        try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]).write(to: entriesURL)
        let previousChoice: [String: Any] = ["Provider": "fixture.previous", "Files": [], "Configuration": Data()]
        let linked: [String: Any] = ["Content": ["Choices": [previousChoice]], "LastSet": Date.distantPast]
        let index: [String: Any] = [
            "SystemDefault": ["Type": "linked", "Linked": linked],
            "AllSpacesAndDisplays": ["Type": "linked", "Linked": linked],
            "Displays": [String: Any](),
            "Spaces": [String: Any]()
        ]
        try PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0).write(to: indexURL)
        try Data("hevc-video-fixture".utf8).write(to: videoURL)
        try Data("jpeg-fixture".utf8).write(to: thumbnailURL)
        try slotOriginalData.write(to: slotURL)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
