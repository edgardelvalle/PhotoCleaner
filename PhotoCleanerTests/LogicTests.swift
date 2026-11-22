import XCTest
@testable import PhotoCleaner

final class DHashTests: XCTestCase {
    func testHashOfGradientIsAllOnes() {
        // Each row gets darker to the right, so every "left > right" bit is set.
        let row: [UInt8] = [200, 180, 160, 140, 120, 100, 80, 60, 40]
        let pixels = Array(repeating: row, count: 8).flatMap { $0 }
        XCTAssertEqual(DHash.hash(grayscale: pixels), UInt64.max)
    }

    func testFlatImageIsNotInformative() {
        let pixels = [UInt8](repeating: 128, count: 72)
        let hash = DHash.hash(grayscale: pixels)
        XCTAssertEqual(hash, 0)
        XCTAssertFalse(DHash.isInformative(hash!))
    }

    func testWrongSizeReturnsNil() {
        XCTAssertNil(DHash.hash(grayscale: [1, 2, 3]))
    }

    func testDistanceCountsDifferentBits() {
        XCTAssertEqual(DHash.distance(0b1010, 0b0110), 2)
        XCTAssertEqual(DHash.distance(.max, 0), 64)
    }
}

final class UnionFindTests: XCTestCase {
    func testUnionJoinsSets() {
        var sets = UnionFind(count: 5)
        XCTAssertTrue(sets.union(0, 1))
        XCTAssertTrue(sets.union(1, 2))
        XCTAssertFalse(sets.union(0, 2))
        XCTAssertEqual(sets.find(0), sets.find(2))
        XCTAssertNotEqual(sets.find(0), sets.find(3))
    }
}

final class SimilarityGrouperTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(_ id: String, minutes: Double, hash: UInt64? = nil, burst: String? = nil) -> GroupingItem {
        GroupingItem(id: id, date: base.addingTimeInterval(minutes * 60), dHash: hash, burstID: burst)
    }

    func testIdenticalHashesGroupAcrossDays() {
        let items = [
            item("a", minutes: 0, hash: 0xF0F0_1234),
            item("b", minutes: 60 * 24 * 5, hash: 0xF0F0_1234),
            item("c", minutes: 60 * 24 * 9, hash: 0x0F0F_9999),
        ]
        let groups = SimilarityGrouper().group(items) { _, _ in nil }
        XCTAssertEqual(groups, [["a", "b"]])
    }

    func testNearHashesOnlyGroupWithinSession() {
        let close: UInt64 = 0xF0F0_1234
        let nearlyClose = close ^ 0b111 // 3 bits differ
        let items = [
            item("a", minutes: 0, hash: close),
            item("b", minutes: 2, hash: nearlyClose),
            item("c", minutes: 600, hash: nearlyClose ^ 0b1000_0000), // other session
        ]
        let groups = SimilarityGrouper().group(items) { _, _ in nil }
        XCTAssertEqual(groups, [["a", "b"]])
    }

    func testFeatureDistanceUsesThreshold() {
        let items = [item("a", minutes: 0), item("b", minutes: 1), item("c", minutes: 2)]
        let distances: [String: Float] = ["a|b": 0.2, "b|c": 0.6, "a|c": 0.7]
        let groups = SimilarityGrouper().group(items) { distances["\($0)|\($1)"] }
        XCTAssertEqual(groups, [["a", "b"]])
    }

    func testBurstsAreGrouped() {
        let items = [item("a", minutes: 0, burst: "x"), item("b", minutes: 0.1, burst: "x"), item("c", minutes: 0.2)]
        let groups = SimilarityGrouper().group(items) { _, _ in nil }
        XCTAssertEqual(groups, [["a", "b"]])
    }

    func testNewestGroupFirst() {
        let items = [
            item("old1", minutes: 0, hash: 0xAAAA),
            item("old2", minutes: 1, hash: 0xAAAA),
            item("new1", minutes: 5000, hash: 0xBBBB),
            item("new2", minutes: 5001, hash: 0xBBBB),
        ]
        let groups = SimilarityGrouper().group(items) { _, _ in nil }
        XCTAssertEqual(groups, [["new1", "new2"], ["old1", "old2"]])
    }
}

final class KeeperPickerTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 0)

    func testFavoriteWins() {
        let picked = KeeperPicker.pick([
            KeeperCandidate(id: "a", isFavorite: false, aestheticsScore: 0.9, pixelCount: 100, date: date),
            KeeperCandidate(id: "b", isFavorite: true, aestheticsScore: 0.1, pixelCount: 100, date: date),
        ])
        XCTAssertEqual(picked?.id, "b")
        XCTAssertEqual(picked?.reason, .favorite)
    }

    func testBestQualityThenLargest() {
        let byQuality = KeeperPicker.pick([
            KeeperCandidate(id: "a", isFavorite: false, aestheticsScore: 0.2, pixelCount: 500, date: date),
            KeeperCandidate(id: "b", isFavorite: false, aestheticsScore: 0.6, pixelCount: 100, date: date),
        ])
        XCTAssertEqual(byQuality?.id, "b")
        XCTAssertEqual(byQuality?.reason, .bestQuality)

        let bySize = KeeperPicker.pick([
            KeeperCandidate(id: "a", isFavorite: false, aestheticsScore: nil, pixelCount: 500, date: date),
            KeeperCandidate(id: "b", isFavorite: false, aestheticsScore: nil, pixelCount: 100, date: date),
        ])
        XCTAssertEqual(bySize?.id, "a")
        XCTAssertEqual(bySize?.reason, .largest)
    }
}

final class OneOffScorerTests: XCTestCase {
    func testReceiptIsSuggested() {
        var signals = OneOffSignals()
        signals.hasReceiptWords = true
        signals.textCharacterCount = 120
        signals.ageInDays = 40
        XCTAssertEqual(OneOffScorer.evaluate(signals)?.reason, "Looks like a receipt")
    }

    func testUtilityAloneIsEnough() {
        var signals = OneOffSignals()
        signals.isUtility = true
        signals.ageInDays = 10
        XCTAssertEqual(OneOffScorer.evaluate(signals)?.reason, "Looks like a quick reference photo")
    }

    func testProtectedPhotosAreNeverSuggested() {
        var signals = OneOffSignals()
        signals.isUtility = true
        signals.hasDocument = true
        signals.ageInDays = 100
        for protect in [\OneOffSignals.isFavorite, \.isInUserAlbum, \.isInDuplicateGroup, \.isScreenshot] {
            var protected = signals
            protected[keyPath: protect] = true
            XCTAssertNil(OneOffScorer.evaluate(protected))
        }
    }

    func testRecentPhotosAreSkipped() {
        var signals = OneOffSignals()
        signals.isUtility = true
        signals.ageInDays = 1
        XCTAssertNil(OneOffScorer.evaluate(signals))
    }

    func testWeakSignalIsNotEnough() {
        var signals = OneOffSignals()
        signals.aestheticsScore = -0.5
        signals.ageInDays = 30
        XCTAssertNil(OneOffScorer.evaluate(signals))
    }

    func testReceiptWords() {
        XCTAssertTrue(ReceiptWords.matches(["COFFEE 3.50", "SUBTOTAL 3.50"]))
        XCTAssertTrue(ReceiptWords.matches(["Total 12.00", "Visa ****1234"]))
        XCTAssertFalse(ReceiptWords.matches(["Happy birthday!"]))
    }
}
