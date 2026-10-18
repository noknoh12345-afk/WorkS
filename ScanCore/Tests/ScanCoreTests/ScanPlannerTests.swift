import XCTest
@testable import ScanCore

/// 撮影結果を本に入れる判断（重複・差し込み・差し替え・抜け）
final class ScanPlannerTests: XCTestCase {
    let planner = ScanPlanner()

    /// ページごとに異なる本文（よく出る言い回しは共通に含める）
    func text(_ page: Int, noiseSeed: UInt64 = 0) -> String {
        var rng = SeededRandom(UInt64(page) * 7919 + 13)
        let chars = Array("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん日本語文章研究実験結果方法時間場所人物記録資料説明理由問題解決社会経済文化歴史自然科学技術生活家族学校会議計画")
        let common = ["である。", "している。", "ことが", "について", "として", "と考えられる。"]
        var s = ""
        while s.count < 260 {
            if rng.double() < 0.18 {
                s += common[rng.int(0...(common.count - 1))]
            } else {
                for _ in 0..<rng.int(3...8) { s.append(chars[rng.int(0...(chars.count - 1))]) }
                s += "、"
            }
        }
        return noiseSeed == 0 ? s : Fixtures.ocrNoise(s, rate: 0.05, seed: noiseSeed)
    }

    func record(_ page: Int, number: Int? = nil, flags: Set<PageFlag> = []) -> PageRecord {
        PageRecord(id: UUID(), number: number ?? page, confidence: .high, text: text(page), hash: nil, flags: flags)
    }

    func candidate(_ page: Int, numbers: [Int]? = nil, noise: UInt64 = 99, flags: Set<PageFlag> = []) -> PageCandidate {
        PageCandidate(numbers: numbers ?? [page], text: text(page, noiseSeed: noise), hash: nil, flags: flags)
    }

    func testSequentialPagesAppend() {
        var records: [PageRecord] = []
        var last: Int?
        for p in 1...12 {
            let plan = planner.plan(candidate(p), records: records, lastNumber: last)
            XCTAssertEqual(plan.action, .insert(at: records.count), "p\(p)")
            XCTAssertEqual(plan.number, p)
            records.append(record(p))
            last = p
        }
    }

    func testSamePageTwiceIsSkipped() {
        let records = (1...5).map { record($0) }
        let plan = planner.plan(candidate(5, noise: 7), records: records, lastNumber: 5)
        XCTAssertEqual(plan.action, .skipDuplicate(of: records[4].id))
    }

    func testDuplicateDetectedEvenWithoutPageNumber() {
        let records = (1...5).map { record($0) }
        let plan = planner.plan(candidate(3, numbers: [], noise: 3), records: records, lastNumber: 5)
        XCTAssertEqual(plan.action, .skipDuplicate(of: records[2].id))
    }

    func testMissedPageGoesBackIntoCorrectPlace() {
        // p13 を撮り逃して p14, p15 に進んだあと、戻って p13 を撮る
        var records = [10, 11, 12, 14, 15].map { record($0) }
        XCTAssertEqual(ScanPlanner.missingNumbers(records), [13])
        let plan = planner.plan(candidate(13), records: records, lastNumber: 15)
        XCTAssertEqual(plan.action, .insert(at: 3))
        XCTAssertEqual(plan.confidence, .high)
        records.insert(record(13), at: 3)
        XCTAssertEqual(ScanPlanner.missingNumbers(records), [])
    }

    func testFlaggedPageIsReplacedByCleanRetake() {
        let records = [record(1), record(2, flags: [.blur]), record(3)]
        let plan = planner.plan(candidate(2), records: records, lastNumber: 3)
        XCTAssertEqual(plan.action, .replace(records[1].id))
    }

    func testFlaggedRetakeDoesNotReplaceCleanPage() {
        let records = [record(1), record(2), record(3)]
        let plan = planner.plan(candidate(2, flags: [.blur]), records: records, lastNumber: 3)
        XCTAssertEqual(plan.action, .skipDuplicate(of: records[1].id))
    }

    func testExplicitReplaceTarget() {
        let records = [record(1), record(2), record(3)]
        let plan = planner.plan(candidate(9), records: records, lastNumber: 3, replaceTarget: records[0].id)
        XCTAssertEqual(plan.action, .replace(records[0].id))
    }

    func testCursorInsertion() {
        let records = [1, 2, 3, 4].map { PageRecord(id: UUID(), number: nil, confidence: .none, text: text($0), hash: nil) }
        let unnumbered = PageCandidate(numbers: [], text: text(50), hash: nil)
        let plan = planner.plan(unnumbered, records: records, cursor: 2)
        XCTAssertEqual(plan.action, .insert(at: 2))
    }

    func testMisreadNumberWithDifferentTextIsNotDuplicate() {
        // p.18 を p.13 と読み違えた（本文は別物）
        let records = (10...17).map { record($0) }
        let plan = planner.plan(candidate(18, numbers: [13]), records: records, lastNumber: 17)
        // 重複扱いせず、怪しい番号では位置を決めない（末尾に追加）
        XCTAssertEqual(plan.action, .insert(at: records.count))
        XCTAssertEqual(plan.confidence, .low)
    }

    func testMisreadNumberWithSameTextIsDuplicate() {
        // 同じ p.12 を撮り直したが番号を 17 と読み違えた
        let records = (10...14).map { record($0) }
        let c = PageCandidate(numbers: [17], text: text(12), hash: nil)
        let plan = planner.plan(c, records: records, lastNumber: 14)
        XCTAssertEqual(plan.action, .skipDuplicate(of: records[2].id))
    }

    func testImplausibleNumberIsLowConfidenceAndAppended() {
        let records = (10...14).map { record($0) }
        // 図のキャプション「2024」を番号と読んだ
        let plan = planner.plan(candidate(15, numbers: [2024]), records: records, lastNumber: 14)
        XCTAssertEqual(plan.action, .insert(at: 5))
        XCTAssertEqual(plan.confidence, .low)
    }

    func testPrefersPlausibleCandidate() {
        let records = (10...14).map { record($0) }
        let plan = planner.plan(candidate(15, numbers: [2024, 15]), records: records, lastNumber: 14)
        XCTAssertEqual(plan.number, 15)
        XCTAssertEqual(plan.confidence, .high)
    }

    func testPicturePagesUseImageHash() {
        let img1 = Fixtures.pageImage(seed: 300, width: 170, height: 160)
        let img1b = Fixtures.pageImage(seed: 300, width: 170, height: 160, shiftX: 1, shiftY: 2, brightness: -10)
        let img2 = Fixtures.pageImage(seed: 301, width: 170, height: 160)
        let r = PageRecord(id: UUID(), number: nil, confidence: .none, text: "", hash: ImageMetrics.differenceHash(img1))
        let same = PageCandidate(numbers: [], text: "", hash: ImageMetrics.differenceHash(img1b))
        let other = PageCandidate(numbers: [], text: "", hash: ImageMetrics.differenceHash(img2))
        XCTAssertEqual(planner.plan(same, records: [r]).action, .skipDuplicate(of: r.id))
        XCTAssertEqual(planner.plan(other, records: [r]).action, .insert(at: 1))
    }

    func testBlankPagesAreKept() {
        // 白紙ページが続いても消さない
        var rng = SeededRandom(3)
        let blank = GrayImage(width: 170, height: 160, fill: 232)
        func blankHash() -> ImageHash {
            ImageMetrics.differenceHash(GrayImage(width: 170, height: 160, pixels: Fixtures.noisy(blank, amplitude: 10, rng: &rng)))
        }
        let r = PageRecord(id: UUID(), number: nil, confidence: .none, text: "", hash: blankHash())
        let c = PageCandidate(numbers: [], text: "", hash: blankHash())
        XCTAssertEqual(planner.plan(c, records: [r]).action, .insert(at: 1))
    }

    func testNoisyPicturePageRetakeIsDuplicate() {
        var rng = SeededRandom(4)
        let img = Fixtures.pageImage(seed: 77, width: 170, height: 160)
        let retake = Fixtures.pageImage(seed: 77, width: 170, height: 160, shiftX: -2, shiftY: 1, brightness: 8)
        let r = PageRecord(id: UUID(), number: nil, confidence: .none, text: "", hash: ImageMetrics.differenceHash(img))
        let c = PageCandidate(numbers: [], text: "",
                              hash: ImageMetrics.differenceHash(GrayImage(width: 170, height: 160, pixels: Fixtures.noisy(retake, amplitude: 8, rng: &rng))))
        XCTAssertEqual(planner.plan(c, records: [r]).action, .skipDuplicate(of: r.id))
    }

    func testContextDuplicateIsSkipped() {
        // 既存の本の最後のページをもう一度撮ってしまった
        let context = [record(30)]
        let plan = planner.plan(candidate(30), records: [], context: context)
        XCTAssertEqual(plan.action, .skipDuplicate(of: context[0].id))
    }

    func testUnnumberedChapterPageFillsGap() {
        // 章扉（番号なし）が p.15 にあたる
        let chapter = PageRecord(id: UUID(), number: nil, confidence: .none, text: "第二章 旅のはじまり", hash: nil)
        let records = [record(13), record(14), chapter, record(16)]
        XCTAssertEqual(ScanPlanner.missingNumbers(records), [])
        XCTAssertEqual(ScanPlanner.estimatedNumbers(records)[chapter.id], 15)
    }

    func testGapReportedWhenNotFilled() {
        let records = [record(1), record(2), record(5)]
        XCTAssertEqual(ScanPlanner.missingNumbers(records), [3, 4])
    }

    func testHugeJumpIsNotReportedAsGap() {
        let records = [record(1), record(2), record(80)]
        XCTAssertEqual(ScanPlanner.missingNumbers(records), [])
    }

    func testSpreadPairsAppendInOrder() {
        // 見開きで2ページずつ（左右）
        var records: [PageRecord] = []
        var last: Int?
        for spread in 0..<5 {
            for p in [spread * 2 + 1, spread * 2 + 2] {
                let plan = planner.plan(candidate(p), records: records, lastNumber: last)
                XCTAssertEqual(plan.action, .insert(at: records.count))
                records.append(record(p))
                last = p
            }
        }
        XCTAssertEqual(records.compactMap(\.number), Array(1...10))
    }

    func testLongBookStaysCorrect() {
        // 120ページ：ときどき重複撮影・撮り逃し→後から撮り直し
        var rng = SeededRandom(7)
        var records: [PageRecord] = []
        var last: Int?
        var skipped: [Int] = []
        var p = 1
        while p <= 120 {
            let roll = rng.double()
            if roll < 0.06 {
                skipped.append(p)   // 撮り逃し
                p += 1
                continue
            }
            let plan = planner.plan(candidate(p, noise: UInt64(p)), records: records, lastNumber: last)
            if case .insert(let at) = plan.action { records.insert(record(p), at: at) } else { XCTFail("p\(p) \(plan.action)") }
            last = p
            if roll > 0.92 {
                // 同じページをもう一度撮ってしまう
                let dup = planner.plan(candidate(p, noise: UInt64(p + 500)), records: records, lastNumber: last)
                if case .skipDuplicate = dup.action {} else { XCTFail("duplicate p\(p) \(dup.action)") }
            }
            p += 1
        }
        XCTAssertEqual(ScanPlanner.missingNumbers(records), skipped.filter { $0 > 1 && $0 < 120 })
        // 戻って撮り逃しを撮る（順不同）
        for s in skipped.shuffled(using: &rng) {
            let plan = planner.plan(candidate(s, noise: UInt64(s + 900)), records: records, lastNumber: last)
            guard case .insert(let at) = plan.action else { XCTFail("skipped p\(s) \(plan.action)"); continue }
            records.insert(record(s), at: at)
            last = s
        }
        XCTAssertEqual(records.compactMap(\.number), Array(1...120))
        XCTAssertEqual(ScanPlanner.missingNumbers(records), [])
    }
}

extension SeededRandom: RandomNumberGenerator {}
