import XCTest

@testable import FolderSync

final class AddressConverterTests: XCTestCase {
    func testExtractIPPortReturnsValidAddress() {
        let multiaddr = "/ip4/192.168.1.100/tcp/51027"
        let result = AddressConverter.extractIPPort(from: multiaddr)

        XCTAssertEqual(result?.ip, "192.168.1.100")
        XCTAssertEqual(result?.port, 51027)
    }

    func testExtractIPPortRejectsInvalidInputs() {
        // Port 0 should be rejected
        XCTAssertNil(AddressConverter.extractIPPort(from: "/ip4/10.0.0.1/tcp/0"))
        // IP 0.0.0.0 should be rejected
        XCTAssertNil(AddressConverter.extractIPPort(from: "/ip4/0.0.0.0/tcp/4001"))
        // Unsupported protocol should be rejected
        XCTAssertNil(AddressConverter.extractIPPort(from: "/dns4/example.com/tcp/4001"))
    }

    func testExtractFirstAddressPicksFirstValid() {
        let addresses = [
            "/ip4/0.0.0.0/tcp/0",  // invalid
            "/ip4/172.16.0.5/tcp/7000",  // valid and should be picked
            "/ip4/192.168.1.10/tcp/0",  // invalid
        ]

        XCTAssertEqual(AddressConverter.extractFirstAddress(from: addresses), "172.16.0.5:7000")
    }

    func testExtractFirstAddressReturnsNilWhenNoValid() {
        let addresses = ["/ip4/0.0.0.0/tcp/0", "/ip4/10.0.0.1/tcp/0"]
        XCTAssertNil(AddressConverter.extractFirstAddress(from: addresses))
    }
}
