import Foundation
import XCTest
@testable import PinchosCore

final class TailByteBufferTests: XCTestCase {
    func testEmptyBufferSnapshotsToEmptyData() {
        let buffer = TailByteBuffer(capacity: 8)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.snapshot(), Data())
        XCTAssertFalse(buffer.didEvict)
    }

    func testBelowCapacityRetainsEverythingInOrder() {
        var buffer = TailByteBuffer(capacity: 8)
        append(&buffer, bytes: [1, 2, 3])
        XCTAssertEqual(buffer.snapshot(), Data([1, 2, 3]))
        XCTAssertFalse(buffer.didEvict)
    }

    func testExactCapacityRetainsEverythingWithoutEviction() {
        var buffer = TailByteBuffer(capacity: 4)
        append(&buffer, bytes: [1, 2, 3, 4])
        XCTAssertEqual(buffer.snapshot(), Data([1, 2, 3, 4]))
        XCTAssertFalse(buffer.didEvict)
    }

    func testWraparoundRetainsOnlyTheMostRecentBytes() {
        var buffer = TailByteBuffer(capacity: 4)
        append(&buffer, bytes: [1, 2, 3, 4])
        append(&buffer, bytes: [5, 6])
        XCTAssertEqual(buffer.snapshot(), Data([3, 4, 5, 6]))
        XCTAssertTrue(buffer.didEvict)

        append(&buffer, bytes: [7])
        XCTAssertEqual(buffer.snapshot(), Data([4, 5, 6, 7]))
    }

    func testChunkLargerThanCapacityRetainsOnlyItsTail() {
        var buffer = TailByteBuffer(capacity: 4)
        append(&buffer, bytes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(buffer.snapshot(), Data([7, 8, 9, 10]))
        XCTAssertTrue(buffer.didEvict)
    }

    func testChunkLargerThanCapacityAfterExistingContentDropsPriorBytesEntirely() {
        var buffer = TailByteBuffer(capacity: 4)
        append(&buffer, bytes: [1, 2])
        append(&buffer, bytes: [3, 4, 5, 6, 7, 8])
        XCTAssertEqual(buffer.snapshot(), Data([5, 6, 7, 8]))
        XCTAssertTrue(buffer.didEvict)
    }

    func testRepeatedOneByteAppendsProduceCorrectTail() {
        var buffer = TailByteBuffer(capacity: 5)
        for value in UInt8(0)...UInt8(19) {
            append(&buffer, bytes: [value])
        }
        XCTAssertEqual(buffer.snapshot(), Data([15, 16, 17, 18, 19]))
        XCTAssertTrue(buffer.didEvict)
        XCTAssertEqual(buffer.reservedCapacity, 5, "reserved storage should never exceed capacity")
    }

    func testRepeatedOneByteAppendsGrowStorageByDoublingNotLinearly() {
        // With unconstrained budget, storage should grow by doubling (a
        // handful of reallocations), never by re-reserving one byte per
        // append - that would make `reservedCapacity` grow in lockstep
        // with byte count instead of jumping to the next power-of-two-ish
        // step.
        var buffer = TailByteBuffer(capacity: 1024)
        var observedSizes = Set<Int>()
        for value in UInt8(0)..<UInt8(200) {
            append(&buffer, bytes: [value])
            observedSizes.insert(buffer.reservedCapacity)
        }
        XCTAssertLessThan(observedSizes.count, 12, "expected O(log capacity) growth steps, saw sizes: \(observedSizes.sorted())")
    }

    func testDeterministicBinaryTailAcrossManyChunkSizes() {
        let allBytes = (0..<1000).map { UInt8($0 % 256) }
        let expectedTail = Data(allBytes.suffix(100))

        for chunkSize in [1, 3, 7, 64, 999, 1000, 5000] {
            var buffer = TailByteBuffer(capacity: 100)
            for chunk in allBytes.chunked(into: chunkSize) {
                append(&buffer, bytes: chunk)
            }
            XCTAssertEqual(buffer.snapshot(), expectedTail, "chunk size \(chunkSize) produced an unexpected tail")
        }
    }

    func testUTF8TailDecodingAtTruncatedBoundaryIsDeterministic() {
        // "a" (1 byte) + "\u{e9}" ("é", 2 bytes: 0xC3 0xA9).
        let bytes: [UInt8] = [0x61, 0xC3, 0xA9]

        var whole = TailByteBuffer(capacity: 3)
        append(&whole, bytes: bytes)
        XCTAssertEqual(String(decoding: whole.snapshot(), as: UTF8.self), "a\u{e9}")

        // Retaining only the last 2 bytes keeps a complete, valid scalar.
        var wholeScalar = TailByteBuffer(capacity: 2)
        append(&wholeScalar, bytes: bytes)
        XCTAssertEqual(wholeScalar.snapshot(), Data([0xC3, 0xA9]))
        XCTAssertEqual(String(decoding: wholeScalar.snapshot(), as: UTF8.self), "\u{e9}")

        // Retaining only the final byte leaves a lone UTF-8 continuation
        // byte with no lead byte. `String(decoding:as: UTF8.self)`
        // deterministically substitutes U+FFFD for it rather than merging
        // it with anything else or throwing.
        var splitScalar = TailByteBuffer(capacity: 1)
        append(&splitScalar, bytes: bytes)
        XCTAssertEqual(splitScalar.snapshot(), Data([0xA9]))
        XCTAssertEqual(String(decoding: splitScalar.snapshot(), as: UTF8.self), "\u{FFFD}")
    }

    func testBudgetCapsReservedCapacityBelowConfiguredLimit() {
        let budget = OutputMemoryBudget(totalBytes: 6)
        var buffer = TailByteBuffer(capacity: 1024, budget: budget)
        append(&buffer, bytes: Array(repeating: 0xAB, count: 200))

        XCTAssertLessThanOrEqual(buffer.reservedCapacity, 6)
        XCTAssertEqual(budget.reservedBytesSnapshot, buffer.reservedCapacity)
        XCTAssertTrue(buffer.didEvict)
        XCTAssertEqual(buffer.snapshot().count, buffer.reservedCapacity)
    }

    func testZeroBudgetDropsAllBytesWithoutCrashing() {
        let budget = OutputMemoryBudget(totalBytes: 0)
        var buffer = TailByteBuffer(capacity: 64, budget: budget)
        append(&buffer, bytes: [1, 2, 3])

        XCTAssertEqual(buffer.reservedCapacity, 0)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertTrue(buffer.didEvict)
        XCTAssertEqual(buffer.snapshot(), Data())
    }

    func testSharedBudgetAcrossMultipleBuffersIsMutuallyExclusive() {
        let budget = OutputMemoryBudget(totalBytes: 10)
        var first = TailByteBuffer(capacity: 100, budget: budget)
        var second = TailByteBuffer(capacity: 100, budget: budget)

        append(&first, bytes: Array(repeating: 1, count: 100))
        append(&second, bytes: Array(repeating: 2, count: 100))

        XCTAssertEqual(first.reservedCapacity + second.reservedCapacity, budget.reservedBytesSnapshot)
        XCTAssertLessThanOrEqual(budget.reservedBytesSnapshot, budget.totalBytes)
    }

    // MARK: - Near-linear performance

    func testAppendIsNearLinearInInputBytesForAFixedLimit() {
        let limit = 256 * 1024
        let small = measureAppendDuration(limit: limit, totalBytes: 4 * 1024 * 1024, chunkSize: 16 * 1024)
        let large = measureAppendDuration(limit: limit, totalBytes: 16 * 1024 * 1024, chunkSize: 16 * 1024)

        // 4x the input bytes should not cost dramatically more than ~4x the
        // time. A stale O(bytesRead x limit) implementation degrades far
        // worse than linearly as bytesRead grows; this generous bound
        // (8x for 4x the data) tolerates system noise while still catching
        // that class of regression.
        XCTAssertLessThan(large, max(small * 8, 0.2), "small=\(small)s large=\(large)s")
    }

    func testAppendCostDoesNotGrowWithLimitForAFixedInputSize() {
        let limits = [64 * 1024, 1024 * 1024, 4 * 1024 * 1024]
        let totalBytes = 4 * 1024 * 1024
        let chunkSize = 16 * 1024

        let durations = limits.map { measureAppendDuration(limit: $0, totalBytes: totalBytes, chunkSize: chunkSize) }
        let baseline = durations[0]

        // For the same total input, appending against a much larger limit
        // should not be dramatically slower.
        for (limit, duration) in zip(limits, durations) {
            XCTAssertLessThan(duration, max(baseline * 8, 0.2), "limit \(limit): durations=\(durations)")
        }
    }

    // MARK: - Helpers

    private func append(_ buffer: inout TailByteBuffer, bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            buffer.append(raw)
        }
    }

    private func measureAppendDuration(limit: Int, totalBytes: Int, chunkSize: Int) -> TimeInterval {
        var buffer = TailByteBuffer(capacity: limit)
        let chunk = [UInt8](repeating: 0x41, count: chunkSize)
        let chunkCount = totalBytes / chunkSize
        let start = Date()
        chunk.withUnsafeBytes { raw in
            for _ in 0..<chunkCount {
                buffer.append(raw)
            }
        }
        return Date().timeIntervalSince(start)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
