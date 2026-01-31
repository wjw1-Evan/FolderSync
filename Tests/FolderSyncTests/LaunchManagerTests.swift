import ServiceManagement
import XCTest

@testable import FolderSync

/// 模拟开机启动服务
class MockLaunchService: LaunchServiceProtocol {
    var mockStatus: SMAppService.Status = .notRegistered
    var registerCalled = false
    var unregisterCalled = false

    var status: SMAppService.Status {
        return mockStatus
    }

    func register() throws {
        registerCalled = true
        mockStatus = .enabled
    }

    func unregister() throws {
        unregisterCalled = true
        mockStatus = .notRegistered
    }
}

final class LaunchManagerTests: XCTestCase {

    @MainActor
    func testInitializationSyncStatus() {
        let mock = MockLaunchService()
        mock.mockStatus = .enabled

        let manager = LaunchManager(service: mock)

        XCTAssertTrue(manager.isEnabled)
    }

    @MainActor
    func testToggleEnabled() async throws {
        let mock = MockLaunchService()
        let manager = LaunchManager(service: mock)

        XCTAssertFalse(manager.isEnabled)

        try await manager.setEnabled(true)

        XCTAssertTrue(mock.registerCalled)
        XCTAssertTrue(manager.isEnabled)
    }

    @MainActor
    func testToggleDisabled() async throws {
        let mock = MockLaunchService()
        mock.mockStatus = .enabled
        let manager = LaunchManager(service: mock)

        XCTAssertTrue(manager.isEnabled)

        try await manager.setEnabled(false)

        XCTAssertTrue(mock.unregisterCalled)
        XCTAssertFalse(manager.isEnabled)
    }

    @MainActor
    func testRequiresApprovalStatus() {
        let mock = MockLaunchService()
        mock.mockStatus = .requiresApproval

        let manager = LaunchManager(service: mock)

        XCTAssertTrue(manager.isEnabled)
        XCTAssertTrue(manager.requiresApproval)
    }
}
