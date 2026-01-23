import XCTest

@testable import FolderSync

final class P2PDiscoveryTests: XCTestCase {
    func testMdnsDefaultAllows() {
        let env: [String: String] = [:]
        XCTAssertTrue(P2PNode.isMdnsAllowed(env: env))
    }

    func testMdnsExplicitFalseValues() {
        let falseValues = ["0", "false", "no", "off", "FALSE", "No"]
        for value in falseValues {
            let env = ["FOLDERSYNC_ENABLE_MDNS": value]
            XCTAssertFalse(P2PNode.isMdnsAllowed(env: env), "Expected \(value) to disable mDNS")
        }
    }

    func testMdnsExplicitTrueValues() {
        let trueValues = ["1", "true", "yes", "on", "TRUE", "YeS", "anything"]
        for value in trueValues {
            let env = ["FOLDERSYNC_ENABLE_MDNS": value]
            XCTAssertTrue(P2PNode.isMdnsAllowed(env: env), "Expected \(value) to allow mDNS")
        }
    }
}
