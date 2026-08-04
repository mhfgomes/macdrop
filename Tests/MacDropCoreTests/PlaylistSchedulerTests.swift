import XCTest
import MacDropCore

final class PlaylistSchedulerTests: XCTestCase {
    private let scheduler = PlaylistScheduler()

    func testSequentialWraps() {
        let ids = [UUID(), UUID(), UUID()]
        XCTAssertEqual(scheduler.nextID(in: ids, current: ids[2], order: .sequential), ids[0])
        XCTAssertEqual(scheduler.previousID(in: ids, current: ids[0]), ids[2])
    }

    func testShuffleNeverImmediatelyRepeats() {
        let ids = [UUID(), UUID(), UUID()]
        for _ in 0..<100 {
            XCTAssertNotEqual(scheduler.nextID(in: ids, current: ids[1], order: .shuffle), ids[1])
        }
    }

    func testSingleItemIsStable() {
        let id = UUID()
        XCTAssertEqual(scheduler.nextID(in: [id], current: id, order: .shuffle), id)
    }

    func testEmptyPlaylistReturnsNil() {
        XCTAssertNil(scheduler.nextID(in: [], current: nil, order: .sequential))
        XCTAssertNil(scheduler.previousID(in: [], current: nil))
    }
}
