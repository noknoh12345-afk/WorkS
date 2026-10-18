import XCTest
@testable import ScanCore

final class ImageMetricsTests: XCTestCase {
    func testMeanAbsDiff() {
        let a = Fixtures.pageImage(seed: 1)
        XCTAssertEqual(ImageMetrics.meanAbsDiff(a.pixels, a.pixels), 0)
        let b = Fixtures.pageImage(seed: 2)
        XCTAssertGreaterThan(ImageMetrics.meanAbsDiff(a.pixels, b.pixels), 0.02)
    }

    func testLaplacianSharpVsBlurred() {
        let sharp = Fixtures.pageImage(seed: 3, width: 64, height: 48)
        let blurred = ImageMetrics.downsample(ImageMetrics.downsample(sharp, width: 16, height: 12), width: 64, height: 48)
        XCTAssertGreaterThan(ImageMetrics.laplacianVariance(sharp), ImageMetrics.laplacianVariance(blurred) * 3)
        XCTAssertEqual(ImageMetrics.laplacianVariance(GrayImage(width: 10, height: 10, fill: 200)), 0)
    }

    func testDifferenceHashSeparatesRetakesFromOtherPages() {
        // 同じページの撮り直し：ズレ（±3px）・明るさ（±15）・カメラのノイズ
        var rng = SeededRandom(5)
        let threshold = ScanPlanner().hashThreshold
        var sameBelow = 0
        var total = 0
        for seed in 1...400 as ClosedRange<UInt64> {
            let a = Fixtures.pageImage(seed: seed, width: 170, height: 160)
            let bImg = Fixtures.pageImage(seed: seed, width: 170, height: 160,
                                          shiftX: rng.int(-3...3), shiftY: rng.int(-3...3), brightness: rng.int(-15...15))
            let b = GrayImage(width: 170, height: 160, pixels: Fixtures.noisy(bImg, amplitude: 10, rng: &rng))
            let c = Fixtures.pageImage(seed: seed + 5000, width: 170, height: 160)
            let ha = ImageMetrics.differenceHash(a)
            XCTAssertEqual(ha.dissimilarity(to: ha), 0)
            if let d = ha.dissimilarity(to: ImageMetrics.differenceHash(b)) {
                total += 1
                if d <= threshold { sameBelow += 1 }
            }
            // 別のページを同じと判定することは一度もあってはならない
            let other = ha.dissimilarity(to: ImageMetrics.differenceHash(c)) ?? 1
            XCTAssertGreaterThan(other, threshold, "seed \(seed)")
        }
        XCTAssertGreaterThanOrEqual(Double(sameBelow) / Double(total), 0.95)
    }

    func testBlankPagesAreNotComparable() {
        var rng = SeededRandom(9)
        let blank = GrayImage(width: 170, height: 160, fill: 230)
        let a = GrayImage(width: 170, height: 160, pixels: Fixtures.noisy(blank, amplitude: 12, rng: &rng))
        let b = GrayImage(width: 170, height: 160, pixels: Fixtures.noisy(blank, amplitude: 12, rng: &rng))
        XCTAssertNil(ImageMetrics.differenceHash(a).dissimilarity(to: ImageMetrics.differenceHash(b)))
    }

    func testContentDifferenceIgnoresBrightness() {
        let a = Fixtures.pageImage(seed: 20)
        let brighter = Fixtures.pageImage(seed: 20, brightness: 15)
        let other = Fixtures.pageImage(seed: 21)
        XCTAssertLessThan(ImageMetrics.contentDifference(a.pixels, brighter.pixels), 0.1)
        XCTAssertGreaterThan(ImageMetrics.contentDifference(a.pixels, other.pixels), 0.35)
    }
}

final class TextSimilarityTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(TextSimilarity.normalize("ＡＢＣ　１２３ abc,。、"), "abc123abc")
    }

    func testSamePageWithOCRNoiseIsSimilar() {
        for seed in 1...20 as ClosedRange<UInt64> {
            let a = Fixtures.ocrNoise(Fixtures.pageA, rate: 0.06, seed: seed)
            let b = Fixtures.ocrNoise(Fixtures.pageA, rate: 0.06, seed: seed + 100)
            XCTAssertGreaterThan(TextSimilarity.similarity(a, b), 0.5, "seed \(seed)")
        }
    }

    func testPartiallyHiddenPageIsStillSimilar() {
        // 手で下半分が隠れた撮り直し
        let full = Fixtures.pageA
        let half = String(full.prefix(full.count / 2))
        XCTAssertGreaterThan(TextSimilarity.similarity(full, half), 0.5)
    }

    func testDifferentPagesAreDissimilar() {
        let pages = [Fixtures.pageA, Fixtures.pageB, Fixtures.pageC]
        for i in 0..<pages.count {
            for j in 0..<pages.count where i != j {
                let a = Fixtures.ocrNoise(pages[i], rate: 0.05, seed: UInt64(i * 7 + 1))
                let b = Fixtures.ocrNoise(pages[j], rate: 0.05, seed: UInt64(j * 7 + 2))
                XCTAssertLessThan(TextSimilarity.similarity(a, b), 0.15, "\(i) vs \(j)")
            }
        }
    }
}

final class PageNumberParserTests: XCTestCase {
    func testParseVariants() {
        let cases: [(String, Int?)] = [
            ("12", 12), ("- 12 -", 12), ("—12—", 12), ("p.12", 12), ("P12", 12), ("12頁", 12),
            ("12ページ", 12), ("１２", 12), ("（12）", 12), ("[204]", 204), ("一二", 12),
            ("百二十三", 123), ("二十", 20), ("十五", 15), ("三〇二", 302),
            ("0", nil), ("007", nil), ("12345", nil), ("abc", nil), ("1.2", nil), ("2024年", nil), ("", nil)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(PageNumberParser.parseNumber(input), expected, input)
        }
    }

    func testPicksBottomNumberAndIgnoresBody() {
        let boxes = [
            TextBox(text: "第2章 実験の方法", x: 0.1, y: 0.04, w: 0.4, h: 0.03),
            TextBox(text: "この実験では 3 種類の試料を用いた。", x: 0.1, y: 0.3, w: 0.8, h: 0.03),
            TextBox(text: "12", x: 0.1, y: 0.5, w: 0.05, h: 0.03), // 本文中の数字
            TextBox(text: "37", x: 0.47, y: 0.94, w: 0.06, h: 0.03)
        ]
        XCTAssertEqual(PageNumberParser.candidates(from: boxes).first, 37)
    }

    func testRunningHeadNumber() {
        let boxes = [
            TextBox(text: "第2章 実験の方法 41", x: 0.4, y: 0.03, w: 0.55, h: 0.03),
            TextBox(text: "本文の行が続く。", x: 0.1, y: 0.3, w: 0.8, h: 0.03)
        ]
        XCTAssertEqual(PageNumberParser.candidates(from: boxes), [41])
    }

    func testNoNumber() {
        let boxes = [TextBox(text: "はじめに", x: 0.4, y: 0.1, w: 0.2, h: 0.04)]
        XCTAssertTrue(PageNumberParser.candidates(from: boxes).isEmpty)
    }
}
