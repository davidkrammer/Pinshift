import XCTest
@testable import Pinshift

final class ProtocolTests: XCTestCase {
    func testPairingRoundTripAndMalformedCodes() throws {
        let p = Pairing(id: UUID().uuidString, name: "David’s Mac", key: Data(repeating: 7, count: 32))
        let parsed = try Pairing(url: p.url)
        XCTAssertEqual(parsed.id, p.id); XCTAssertEqual(parsed.key, p.key)
        XCTAssertThrowsError(try Pairing(url: "https://example.com"))
        XCTAssertThrowsError(try Pairing(url: "pinshift://pair?id=invalid&name=Mac&key=AA=="))
    }
    func testRejectsInvalidLocationBeforeSendingToDevice() {
        XCTAssertFalse(Place(name: "Invalid", detail: "", latitude: .nan, longitude: 0).isValid)
        XCTAssertFalse(Place(name: "Invalid", detail: "", latitude: 91, longitude: 0).isValid)
        XCTAssertFalse(Place(name: "Invalid", detail: "", latitude: 0, longitude: 181).isValid)
        XCTAssertTrue(Place(name: "Valid", detail: "", latitude: -90, longitude: -180).isValid)
    }
    func testPendingRestoreStillRequiresStop() {
        var s = HostSnapshot(); s.phase = "clearPending"; s.mayBeActive = true
        XCTAssertTrue(s.needsStop); XCTAssertFalse(s.active)
    }
}
