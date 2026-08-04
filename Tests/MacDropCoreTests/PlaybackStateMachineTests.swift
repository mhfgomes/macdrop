import XCTest
import MacDropCore

final class PlaybackStateMachineTests: XCTestCase {
    func testAllReasonsMustClearBeforeResume() {
        var machine = PlaybackStateMachine()
        machine.set(.manual, active: true)
        machine.set(.thermalPressure, active: true)
        XCTAssertTrue(machine.isPaused)

        machine.set(.thermalPressure, active: false)
        XCTAssertTrue(machine.isPaused)
        XCTAssertEqual(machine.reasons, [.manual])

        machine.set(.manual, active: false)
        XCTAssertFalse(machine.isPaused)
    }

    func testSettingAReasonIsIdempotent() {
        var machine = PlaybackStateMachine()
        machine.set(.systemSleep, active: true)
        machine.set(.systemSleep, active: true)
        XCTAssertEqual(machine.reasons.count, 1)
    }
}
