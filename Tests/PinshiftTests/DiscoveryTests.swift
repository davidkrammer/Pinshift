import XCTest
@testable import Pinshift

final class DiscoveryTests: XCTestCase {
    func testDetectsSleepingPairedPhoneWithoutIncludingSimulatorOrUnavailablePhone() throws {
        let data = Data(#"{"result":{"devices":[{"properties":{"hardware":{"reality":"physical","deviceType":"iPhone","udid":"phone"},"connection":{"state":"disconnected","transportType":"localNetwork"},"state":{"name":"My iPhone"}}},{"properties":{"hardware":{"reality":"simulated","deviceType":"iPhone","udid":"sim"},"connection":{"state":"connected","transportType":"sameMachine"}}},{"properties":{"hardware":{"reality":"physical","deviceType":"iPhone","udid":"offline"},"connection":{"state":"unavailable"}}}]}}"#.utf8)
        XCTAssertEqual(try CoreDeviceInventory.phones(in: data), [PhoneDevice(id: "phone", name: "My iPhone")])
    }
    func testSupportsPreviousXcodeDeviceSchema() throws {
        let data = Data(#"{"result":{"devices":[{"hardwareProperties":{"reality":"physical","deviceType":"iPhone","udid":"phone"},"connectionProperties":{"tunnelState":"connected","transportType":"wired"},"deviceProperties":{"name":"USB iPhone"}}]}}"#.utf8)
        XCTAssertEqual(try CoreDeviceInventory.phones(in: data), [PhoneDevice(id: "phone", name: "USB iPhone")])
        XCTAssertThrowsError(try CoreDeviceInventory.phones(in: Data("invalid".utf8)))
    }
}
