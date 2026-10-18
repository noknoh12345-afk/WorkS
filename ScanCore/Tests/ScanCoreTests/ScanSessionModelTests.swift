import XCTest
@testable import ScanCore

final class ScanSessionModelTests: XCTestCase {
    func text(_ page: Int) -> String {
        var rng = SeededRandom(UInt64(page) * 104729 + 7)
        let chars = Array("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん日本語文章研究実験結果方法時間場所人物記録資料説明理由")
        var s = ""
        while s.count < 200 { s.append(chars[rng.int(0...(chars.count - 1))]) }
        return s
    }

    func cand(_ page: Int, number: Int? = -1, flags: Set<PageFlag> = [], noise: UInt64 = 1) -> PageCandidate {
        let n: [Int] = number == -1 ? [page] : (number.map { [$0] } ?? [])
        return PageCandidate(numbers: n, text: Fixtures.ocrNoise(text(page), rate: 0.04, seed: noise), hash: nil, flags: flags)
    }

    func numbers(_ m: ScanSessionModel) -> [Int?] { m.records.map(\.number) }

    func testForwardScanning() {
        let m = ScanSessionModel()
        for p in 1...6 { m.apply(cand(p)) }
        XCTAssertEqual(numbers(m), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(m.lastNumber, 6)
    }

    func testFlipBackToMissedPageThenContinue() {
        let m = ScanSessionModel()
        for p in [1, 2, 4, 5] { m.apply(cand(p)) }
        XCTAssertEqual(m.missingNumbers, [3])
        // 戻って p3 を撮る
        let (o, _) = m.apply(cand(3))
        if case .inserted(_, let at) = o { XCTAssertEqual(at, 2) } else { XCTFail("\(o)") }
        // そのまま p4 を見せる（撮影済み）→ スキップ、p5 もスキップ、p6 で続きから
        if case .skipped = m.apply(cand(4, noise: 9)).0 {} else { XCTFail() }
        if case .skipped = m.apply(cand(5, noise: 9)).0 {} else { XCTFail() }
        m.apply(cand(6))
        XCTAssertEqual(numbers(m), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(m.missingNumbers, [])
    }

    func testManualInsertCursorWithoutPageNumbers() {
        // ページ番号のない本：3枚目の後ろに撮り逃しを2枚差し込む
        let m = ScanSessionModel()
        var ids: [UUID] = []
        for p in [1, 2, 3, 6, 7] {
            let id = UUID()
            m.apply(cand(p, number: nil), newID: id)
            ids.append(id)
        }
        m.setCursor(after: ids[2])
        let a = UUID(), b = UUID()
        m.apply(cand(4, number: nil), newID: a)
        m.apply(cand(5, number: nil), newID: b)
        XCTAssertEqual(m.ids, [ids[0], ids[1], ids[2], a, b, ids[3], ids[4]])
        // 解除すると末尾に戻る
        m.setCursor(after: nil)
        let c = UUID()
        m.apply(cand(8, number: nil), newID: c)
        XCTAssertEqual(m.ids.last, c)
    }

    func testCursorShiftsWhenEarlierPageRemoved() {
        let m = ScanSessionModel()
        var ids: [UUID] = []
        for p in 1...4 {
            let id = UUID()
            m.apply(cand(p, number: nil), newID: id)
            ids.append(id)
        }
        m.setCursor(after: ids[2]) // 位置 3
        m.remove(ids[0])          // 前のページを削除 → 位置 2
        let x = UUID()
        m.apply(cand(9, number: nil), newID: x)
        XCTAssertEqual(m.ids, [ids[1], ids[2], x, ids[3]])
    }

    func testExplicitRetakeKeepsPositionAndNumber() {
        let m = ScanSessionModel()
        var ids: [UUID] = []
        for p in 1...3 {
            let id = UUID()
            m.apply(cand(p), newID: id)
            ids.append(id)
        }
        m.setReplaceTarget(ids[1])
        let new = UUID()
        // 撮り直しでは番号が読めなかった
        let (o, _) = m.apply(cand(2, number: nil, noise: 5), newID: new)
        XCTAssertEqual(o, .replaced(old: ids[1], new: new, at: 1))
        XCTAssertEqual(m.ids, [ids[0], new, ids[2]])
        XCTAssertEqual(m.records[1].number, 2)
        XCTAssertNil(m.replaceTarget)
    }

    func testAutoRetakeReplacesBlurryPageAndIsLimited() {
        let m = ScanSessionModel()
        let blurry = UUID()
        m.apply(cand(1), newID: UUID())
        m.apply(cand(2, flags: [.blur]), newID: blurry)
        XCTAssertTrue(m.canAutoRetake(blurry))
        let second = UUID()
        let (o, _) = m.apply(cand(2, flags: [.blur], noise: 3), newID: second)
        // まだブレている撮り直しは差し替えない（悪化しないものだけ採用）
        XCTAssertEqual(o, .skipped(duplicateOf: blurry))
        let good = UUID()
        let (o2, _) = m.apply(cand(2, noise: 4), newID: good)
        XCTAssertEqual(o2, .replaced(old: blurry, new: good, at: 1))
        XCTAssertEqual(m.retakeCounts[good], 1)
    }

    func testAppendingToExistingBookSkipsItsLastPage() {
        let last = PageRecord(id: UUID(), number: 40, confidence: .high, text: text(40), hash: nil)
        let m = ScanSessionModel(context: [last])
        XCTAssertEqual(m.lastNumber, 40)
        if case .skipped(let d) = m.apply(cand(40)).0 { XCTAssertEqual(d, last.id) } else { XCTFail() }
        m.apply(cand(41))
        m.apply(cand(42))
        XCTAssertEqual(numbers(m), [41, 42])
    }

    func testEstimatedDisplayNumbers() {
        let m = ScanSessionModel()
        let chapter = UUID()
        m.apply(cand(10))
        m.apply(cand(11, number: nil), newID: chapter)
        m.apply(cand(12))
        XCTAssertEqual(m.displayNumber(chapter)?.number, 11)
        XCTAssertEqual(m.displayNumber(chapter)?.estimated, true)
    }

    func testQualityJudge() {
        XCTAssertEqual(QualityJudge.flags(textCharCount: 300, meanConfidence: 0.9, lowConfidenceRatio: 0.05, handOverPage: false, cropFound: true), [])
        XCTAssertEqual(QualityJudge.flags(textCharCount: 300, meanConfidence: 0.3, lowConfidenceRatio: 0.7, handOverPage: false, cropFound: true), [.blur])
        XCTAssertEqual(QualityJudge.flags(textCharCount: 5, meanConfidence: 0.2, lowConfidenceRatio: 1, handOverPage: true, cropFound: false), [.hand, .noCrop])
    }

    func testQuadRotationForPhotoOrientation() {
        // センサー座標（横長）で左上寄りにある紙
        let q = Quad(topLeft: Point2(0.1, 0.2), topRight: Point2(0.5, 0.2),
                     bottomRight: Point2(0.5, 0.9), bottomLeft: Point2(0.1, 0.9))
        // 縦持ち（90°）：センサーの左上は写真の右上になる
        let r = q.rotated(clockwiseDegrees: 90)
        XCTAssertEqual(r.topLeft, Point2(1 - 0.9, 0.1))
        XCTAssertEqual(r.topRight, Point2(1 - 0.2, 0.1))
        XCTAssertEqual(r.bottomRight, Point2(1 - 0.2, 0.5))
        XCTAssertEqual(r.bottomLeft, Point2(1 - 0.9, 0.5))
        XCTAssertEqual(q.rotated(clockwiseDegrees: 0), q)
        XCTAssertEqual(q.rotated(clockwiseDegrees: 360), q)
        // 4回まわすと元に戻る
        let roundTrip = q.rotated(clockwiseDegrees: 90).rotated(clockwiseDegrees: 90)
            .rotated(clockwiseDegrees: 90).rotated(clockwiseDegrees: 90)
        XCTAssertLessThan(roundTrip.maxCornerDistance(to: q), 1e-9)
        XCTAssertTrue(r.isConvex)
        XCTAssertEqual(r.area, q.area, accuracy: 1e-9)
    }

    func testRetakeTargetIsProtectedFromWrongPage() {
        let m = ScanSessionModel()
        var ids: [UUID] = []
        for p in 10...15 {
            let id = UUID()
            m.apply(cand(p), newID: id)
            ids.append(id)
        }
        // p12 を撮り直すつもりが、めくった先の p16 が写った
        m.setReplaceTarget(ids[2])
        let (o, _) = m.apply(cand(16), newID: UUID())
        if case .inserted(_, let at) = o { XCTAssertEqual(at, 6) } else { XCTFail("\(o)") }
        XCTAssertEqual(m.replaceTarget, ids[2], "撮り直し指定は残す")
        // 戻って p12 を写すと差し替わる
        let new = UUID()
        XCTAssertEqual(m.apply(cand(12, noise: 8), newID: new).0, .replaced(old: ids[2], new: new, at: 2))
    }

    func testForcedInsertAfterDuplicate() {
        let m = ScanSessionModel()
        let a = UUID(), b = UUID()
        m.apply(cand(1), newID: a)
        m.apply(cand(2), newID: b)
        let x = UUID()
        XCTAssertEqual(m.insertForced(cand(1, noise: 5), newID: x, after: a), 1)
        XCTAssertEqual(m.ids, [a, x, b])
    }
}

