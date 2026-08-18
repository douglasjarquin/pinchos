import Darwin
import XCTest
@testable import pinchos

@MainActor
final class ShutdownCoordinatorTests: XCTestCase {
    func testRepeatedSignalsUseOneCleanupAndFirstSignalExitCode() async {
        var cleanupCount = 0
        let coordinator = ShutdownCoordinator(
            signalNumbers: [],
            cleanup: {
                cleanupCount += 1
            },
            forcedExit: { _ in XCTFail("cleanup should not force exit") },
            autoFinishOnCleanup: false
        )

        coordinator.requestShutdown(reason: .signal(SIGTERM))
        coordinator.requestShutdown(reason: .signal(SIGINT))
        let exitCode = await coordinator.finish(exitCode: 0)

        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(exitCode, 143)
    }

    func testNormalCompletionUsesCleanupAndPreservesExitCode() async {
        var cleanupCount = 0
        let coordinator = ShutdownCoordinator(
            signalNumbers: [],
            cleanup: {
                cleanupCount += 1
            },
            forcedExit: { _ in XCTFail("normal completion should not force exit") },
            autoFinishOnCleanup: false
        )

        let exitCode = await coordinator.finish(exitCode: 7)

        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(exitCode, 7)
    }

    func testCleanupTimeoutForcesDeterministicExitAndUnblocksCompletion() async {
        var forcedExitCode: Int32?
        let coordinator = ShutdownCoordinator(
            signalNumbers: [],
            cleanupTimeoutNanoseconds: 50_000_000,
            cleanup: {
                try? await Task.sleep(nanoseconds: 500_000_000)
            },
            forcedExit: { code in
                forcedExitCode = code
            },
            autoFinishOnCleanup: false
        )

        let exitCode = await coordinator.finish(exitCode: 0)

        XCTAssertEqual(forcedExitCode, 125)
        XCTAssertEqual(exitCode, 125)
    }

    func testAutoFinishCallsCompletionOnceForNormalQuit() async {
        var completionReasons: [ShutdownReason] = []
        let coordinator = ShutdownCoordinator(
            signalNumbers: [],
            cleanup: {},
            forcedExit: { _ in XCTFail("normal quit should not force exit") },
            autoFinishOnCleanup: true,
            onFinished: { reason in
                completionReasons.append(reason)
            }
        )

        coordinator.requestShutdown(reason: .normalQuit)
        coordinator.requestShutdown(reason: .signal(SIGTERM))
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(completionReasons, [.normalQuit])
    }

    func testAppDelegateNormalQuitUsesSharedCoordinator() async throws {
        let delegate = AppDelegate()

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTFail("normal Quit did not finish through the shared shutdown coordinator")
    }
}
