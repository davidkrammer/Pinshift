import XCTest
@testable import Pinshift

final class LocationControlsTests: XCTestCase {
    private let place = Place(name: "Vienna", detail: "Austria", latitude: 48.2082, longitude: 16.3738)

    private func controls(phase: String = "idle", desired: Bool = false, mayBeActive: Bool = false, pending: String? = nil) -> LocationControls {
        var state = HostSnapshot()
        state.target = "test-iphone"
        state.phase = phase
        state.desired = desired
        state.mayBeActive = mayBeActive
        return LocationControls(state: state, pendingCommand: pending, connected: true, place: place)
    }

    func testStartCannotBeSentTwiceWhileAwaitingAcknowledgement() {
        let idle = controls()
        XCTAssertEqual(idle.action, .start)
        XCTAssertTrue(idle.enabled)
        let sending = controls(pending: "start")
        XCTAssertEqual(sending.title, "Starting…")
        XCTAssertFalse(sending.enabled)
        XCTAssertFalse(sending.canMove)
    }

    func testAcceptedStartCanBeStoppedWhileDeviceIsStillApplying() {
        let applying = controls(phase: "applying", desired: true)
        XCTAssertEqual(applying.action, .stop)
        XCTAssertTrue(applying.enabled)
        XCTAssertFalse(applying.canMove)
    }

    func testStopDoesNotBecomeStartBeforeDeviceConfirmsClear() {
        let sending = controls(phase: "active", desired: true, mayBeActive: true, pending: "stop")
        XCTAssertEqual(sending.action, .stop)
        XCTAssertFalse(sending.enabled)

        // The Mac can acknowledge Stop before the worker records its active latch.
        let clearing = controls(phase: "clearing", desired: false, mayBeActive: false)
        XCTAssertEqual(clearing.action, .stop)
        XCTAssertEqual(clearing.title, "Stopping…")
        XCTAssertFalse(clearing.enabled)

        let cleared = controls(phase: "cleared")
        XCTAssertEqual(cleared.action, .start)
        XCTAssertTrue(cleared.enabled)
    }

    func testPendingRestoreAllowsStopRetryButNeverStart() {
        let waiting = controls(phase: "clearPending")
        XCTAssertEqual(waiting.action, .stop)
        XCTAssertTrue(waiting.enabled)
        XCTAssertFalse(waiting.canMove)
    }

    func testChangingDraftKeepsPrimaryStopAndDisablesMoveWhileClearing() {
        var active = controls(phase: "active", desired: true, mayBeActive: true)
        active.place = Place(name: "Prague", detail: "Czechia", latitude: 50.08, longitude: 14.43)
        XCTAssertEqual(active.action, .stop)
        XCTAssertTrue(active.canMove)
        active.state.phase = "clearing"
        XCTAssertEqual(active.action, .stop)
        XCTAssertFalse(active.canMove)
    }

    func testDisconnectedRemoteCannotSendEitherAction() {
        var idle = controls()
        idle.connected = false
        XCTAssertFalse(idle.enabled)
        var active = controls(phase: "active", desired: true)
        active.connected = false
        XCTAssertEqual(active.action, .stop)
        XCTAssertFalse(active.enabled)
        XCTAssertFalse(active.canMove)
    }

    func testStopIsAvailableEvenIfSelectionOrTargetIsUnavailable() {
        var active = controls(phase: "failed", mayBeActive: true)
        active.place.latitude = .nan
        active.state.target = nil
        XCTAssertEqual(active.action, .stop)
        XCTAssertTrue(active.enabled)
        XCTAssertFalse(active.canMove)
    }

    func testStartRequiresAValidLocationAndTarget() {
        var idle = controls()
        idle.place = .initial
        XCTAssertFalse(idle.enabled)
        idle.place = place
        idle.state.target = nil
        XCTAssertFalse(idle.enabled)
    }
}
