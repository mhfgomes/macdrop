import XCTest
@testable import MacDropCore

final class AppPathsTests: XCTestCase {
    func testCreatesManagedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.library.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.backups.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.logs.path))
    }

    func testUsesIsolatedTemporaryRootForUITestingDefault() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "MacDropUITesting")
        let temporaryDirectory = URL(fileURLWithPath: "/tmp/macdrop-tests", isDirectory: true)
        let identifier = UUID()

        let root = AppPaths.defaultRoot(
            userDefaults: defaults,
            arguments: [],
            temporaryDirectory: temporaryDirectory,
            uiTestIdentifier: identifier
        )

        XCTAssertEqual(
            root,
            temporaryDirectory.appendingPathComponent(
                "MacDropUITests-\(identifier.uuidString)",
                isDirectory: true
            )
        )
    }

    func testUsesIsolatedTemporaryRootForUITestingArgument() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let temporaryDirectory = URL(fileURLWithPath: "/tmp/macdrop-tests", isDirectory: true)
        let identifier = UUID()

        let root = AppPaths.defaultRoot(
            userDefaults: defaults,
            arguments: ["/Applications/MacDrop.app/MacOS/MacDrop", "-MacDropUITesting"],
            temporaryDirectory: temporaryDirectory,
            uiTestIdentifier: identifier
        )

        XCTAssertEqual(
            root,
            temporaryDirectory.appendingPathComponent(
                "MacDropUITests-\(identifier.uuidString)",
                isDirectory: true
            )
        )
    }
}
