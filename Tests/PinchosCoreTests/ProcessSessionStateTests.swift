import XCTest
@testable import PinchosCore

final class ProcessSessionStateTests: XCTestCase {
    private typealias State = SupervisorProcessSession.State

    private enum Case: CaseIterable {
        case spawned
        case running
        case commandExited
        case terminating
        case released
        case exited
    }

    private func makeState(_ lifecycleCase: Case) -> State {
        let state = State()
        switch lifecycleCase {
        case .spawned:
            break
        case .running:
            _ = state.markStarted()
        case .commandExited:
            _ = state.markStarted()
            _ = state.markCommandExited()
        case .terminating:
            _ = state.markStarted()
            _ = state.beginTermination()
        case .released:
            _ = state.markStarted()
            _ = state.markReleased()
        case .exited:
            _ = state.markStarted()
            _ = state.markExited()
        }
        return state
    }

    func testOwnedOnlyBeforeTerminationReleaseOrExit() {
        let owned: [Case: Bool] = [
            .spawned: true,
            .running: true,
            .commandExited: true,
            .terminating: false,
            .released: false,
            .exited: false,
        ]
        for lifecycleCase in Case.allCases {
            XCTAssertEqual(makeState(lifecycleCase).isOwned, owned[lifecycleCase], "\(lifecycleCase)")
        }
    }

    func testDescendantsOnlyAfterStartWhileOwnedAndNotReportedGone() {
        let expected: [Case: Bool] = [
            .spawned: false,
            .running: true,
            .commandExited: true,
            .terminating: false,
            .released: false,
            .exited: false,
        ]
        for lifecycleCase in Case.allCases {
            XCTAssertEqual(makeState(lifecycleCase).hasDescendants, expected[lifecycleCase], "\(lifecycleCase)")
        }
    }

    func testDescendantsReportedGoneClearsDescendantsAndKeepsOwnership() {
        let state = makeState(.commandExited)

        _ = state.markDescendantsGone()

        XCTAssertFalse(state.hasDescendants)
        XCTAssertTrue(state.isOwned)
    }

    func testDescendantsReportedGoneSurvivesCommandExit() {
        let state = makeState(.running)

        _ = state.markDescendantsGone()
        XCTAssertTrue(state.markCommandExited())

        XCTAssertFalse(state.hasDescendants)
        XCTAssertTrue(state.isOwned)
    }

    func testCommandExitAppliesOnce() {
        let state = makeState(.running)

        XCTAssertTrue(state.markCommandExited())
        XCTAssertFalse(state.markCommandExited())
        XCTAssertTrue(state.isOwned)
    }

    func testCommandExitIsRejectedOnceTerminationHasBegun() {
        let state = makeState(.terminating)

        XCTAssertFalse(state.markCommandExited())
        XCTAssertFalse(state.isOwned)
    }

    func testCommandExitIsRejectedAfterReleaseOrExit() {
        XCTAssertFalse(makeState(.released).markCommandExited())
        XCTAssertFalse(makeState(.exited).markCommandExited())
    }

    func testTerminationAppliesOnceFromEveryOwnedCase() {
        for lifecycleCase in [Case.spawned, .running, .commandExited] {
            let state = makeState(lifecycleCase)

            XCTAssertTrue(state.beginTermination(), "\(lifecycleCase)")
            XCTAssertFalse(state.beginTermination(), "\(lifecycleCase)")
            XCTAssertFalse(state.isOwned, "\(lifecycleCase)")
            XCTAssertFalse(state.hasDescendants, "\(lifecycleCase)")
        }
    }

    func testTerminationIsRejectedAfterReleaseOrExit() {
        XCTAssertFalse(makeState(.released).beginTermination())
        XCTAssertFalse(makeState(.exited).beginTermination())
    }

    func testReleaseEndsOwnershipFromEveryOwnedCase() {
        for lifecycleCase in [Case.spawned, .running, .commandExited] {
            let state = makeState(lifecycleCase)

            XCTAssertTrue(state.markReleased(), "\(lifecycleCase)")
            XCTAssertFalse(state.isOwned, "\(lifecycleCase)")
            XCTAssertFalse(state.hasDescendants, "\(lifecycleCase)")
            XCTAssertFalse(state.beginTermination(), "\(lifecycleCase)")
        }
    }

    func testReleaseIsANoOpOnceOwnershipHasEnded() {
        for lifecycleCase in [Case.terminating, .released, .exited] {
            let state = makeState(lifecycleCase)

            XCTAssertFalse(state.markReleased(), "\(lifecycleCase)")
            XCTAssertFalse(state.isOwned, "\(lifecycleCase)")
        }
    }

    func testStartIsRejectedOutsideSpawned() {
        for lifecycleCase in Case.allCases where lifecycleCase != .spawned {
            XCTAssertFalse(makeState(lifecycleCase).markStarted(), "\(lifecycleCase)")
        }
    }

    func testExitObservedFromEveryCaseYieldsExited() {
        for lifecycleCase in Case.allCases {
            let state = makeState(lifecycleCase)

            XCTAssertEqual(state.markExited(), lifecycleCase != .exited, "\(lifecycleCase)")
            XCTAssertFalse(state.isOwned, "\(lifecycleCase)")
            XCTAssertFalse(state.hasDescendants, "\(lifecycleCase)")
            XCTAssertFalse(state.markCommandExited(), "\(lifecycleCase)")
            XCTAssertFalse(state.beginTermination(), "\(lifecycleCase)")
            XCTAssertFalse(state.markReleased(), "\(lifecycleCase)")
        }
    }
}
