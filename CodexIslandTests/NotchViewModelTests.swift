import AppKit
import XCTest
@testable import Codex_Island

@MainActor
final class NotchViewModelTests: XCTestCase {
    func testHoverLeaveClosesAfterDelayWhenOpenedByHover() async {
        let viewModel = makeViewModel(hoverCloseDelay: 0.05)
        viewModel.setHovering(true)

        viewModel.setHovering(false)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(viewModel.status, .closed)
        XCTAssertFalse(viewModel.isHovering)
    }

    func testHoverLeaveDoesNotCloseManuallyOpenedPanel() async {
        let viewModel = makeViewModel(hoverCloseDelay: 0.05)
        viewModel.notchOpen(reason: .click)

        viewModel.setHovering(true)
        viewModel.setHovering(false)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(viewModel.status, .opened)
        XCTAssertEqual(viewModel.openReason, .click)
    }

    func testReEnteringBeforeDelayCancelsPendingHoverClose() async {
        let viewModel = makeViewModel(hoverCloseDelay: 0.1)
        viewModel.setHovering(true)
        viewModel.setHovering(false)

        try? await Task.sleep(for: .milliseconds(40))
        viewModel.setHovering(true)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(viewModel.status, .opened)
        XCTAssertTrue(viewModel.isHovering)
    }

    private func makeViewModel(hoverCloseDelay: TimeInterval = 2.0) -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: CGRect(x: 0, y: 0, width: 200, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            windowHeight: 750,
            hasPhysicalNotch: true,
            hoverCloseDelay: hoverCloseDelay,
            monitorEvents: false
        )
    }
}
