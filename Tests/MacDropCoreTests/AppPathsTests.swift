import XCTest
import MacDropCore

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
}
