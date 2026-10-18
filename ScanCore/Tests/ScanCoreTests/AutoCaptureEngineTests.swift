import XCTest
@testable import ScanCore

/// 実際の撮影の流れを 15fps のフレーム列で再現して、撮影回数とタイミングを確かめる
final class AutoCaptureEngineTests: XCTestCase {
    struct Sim {
        var engine: AutoCaptureEngine
        var t = 0.0
        var rng = SeededRandom(42)
        var captures: [Double] = []
        let fps = 15.0
        var captureLatency = 0.25 // シャッターから撮影完了まで
        var pendingFinish: Double?

        init(_ tuning: CaptureTuning = CaptureTuning()) { engine = AutoCaptureEngine(tuning: tuning) }

        mutating func frame(_ thumb: [UInt8], quad: Quad?, hand: Bool = false, focusing: Bool = false, sharpness: Double = 100) {
            if let f = pendingFinish, t >= f {
                engine.notifyCaptureFinished(success: true)
                pendingFinish = nil
            }
            let s = FrameSample(time: t, thumb: thumb, sharpness: sharpness, quad: quad, handOverPage: hand, adjustingFocus: focusing)
            if engine.process(s) {
                captures.append(t)
                pendingFinish = t + captureLatency
            }
            t += 1 / fps
        }

        /// 手持ちで静止（小さな手ぶれ＋ノイズ）
        mutating func hold(page seed: UInt64, seconds: Double, jitter: Int = 3, quad: Quad? = Fixtures.quad,
                           hand: Bool = false, focusing: Bool = false) {
            let img = Fixtures.pageImage(seed: seed)
            let n = Int(seconds * fps)
            for _ in 0..<n {
                let thumb = Fixtures.noisy(img, amplitude: jitter, rng: &rng)
                let q = quad.map { Fixtures.jittered($0, 0.006, rng: &rng) }
                frame(thumb, quad: q, hand: hand, focusing: focusing)
            }
        }

        /// めくり（大きな動き。手が紙の上を通る）
        mutating func turn(seconds: Double = 0.5, hand: Bool = true) {
            let n = max(1, Int(seconds * fps))
            for i in 0..<n {
                let thumb = Fixtures.turningFrame(rng: &rng)
                frame(thumb, quad: i % 3 == 0 ? nil : Fixtures.jittered(Fixtures.quad, 0.2, rng: &rng), hand: hand && i > 1 && i < n - 1)
            }
        }
    }

    func testCapturesFirstPageOnceWhenStill() {
        var sim = Sim()
        sim.hold(page: 1, seconds: 4)
        XCTAssertEqual(sim.captures.count, 1)
        XCTAssertLessThan(sim.captures[0], 1.2, "静止してすぐ撮る")
        XCTAssertEqual(sim.engine.status, .turnPage)
    }

    func testEachTurnCapturesExactlyOnce() {
        var sim = Sim()
        for page in 1...10 as ClosedRange<UInt64> {
            sim.hold(page: page, seconds: 1.6)
            sim.turn()
        }
        sim.hold(page: 11, seconds: 2)
        XCTAssertEqual(sim.captures.count, 11)
    }

    func testFastFlippingStillCapturesEveryPage() {
        var sim = Sim(CaptureTuning.preset(.fast))
        for page in 1...20 as ClosedRange<UInt64> {
            sim.hold(page: page, seconds: 0.7)
            sim.turn(seconds: 0.35)
        }
        XCTAssertEqual(sim.captures.count, 20)
    }

    func testTurnStartingDuringShutterIsNotLost() {
        // シャッターが切れた直後（撮影処理中）にめくり始めても次のページを取りこぼさない
        var sim = Sim()
        sim.captureLatency = 0.5
        sim.hold(page: 1, seconds: 0.8)
        XCTAssertEqual(sim.captures.count, 1)
        sim.turn(seconds: 0.7)
        sim.hold(page: 2, seconds: 1.5)
        XCTAssertEqual(sim.captures.count, 2)
    }

    func testHandJitterWithoutTurningDoesNotRecapture() {
        var sim = Sim()
        sim.hold(page: 1, seconds: 1.5)
        // 手ぶれが大きめの手持ち（めくりはしない）
        sim.hold(page: 1, seconds: 6, jitter: 6)
        XCTAssertEqual(sim.captures.count, 1)
    }

    func testDoesNotCaptureWhileHandIsOverPage() {
        var sim = Sim()
        sim.hold(page: 1, seconds: 3, hand: true)
        XCTAssertEqual(sim.captures.count, 0)
        XCTAssertEqual(sim.engine.status, .handOverPage)
        sim.hold(page: 1, seconds: 1.5)
        XCTAssertEqual(sim.captures.count, 1)
    }

    func testWaitsForFocusButNotForever() {
        var sim = Sim()
        sim.hold(page: 1, seconds: 0.8, focusing: true)
        XCTAssertEqual(sim.captures.count, 0)
        sim.hold(page: 1, seconds: 1.0, focusing: true)
        XCTAssertEqual(sim.captures.count, 1, "ピント待ちは最大1秒")
    }

    func testNoDocumentNeedsLongerStillness() {
        var sim = Sim()
        sim.hold(page: 1, seconds: 1.0, quad: nil)
        XCTAssertEqual(sim.captures.count, 0)
        sim.hold(page: 1, seconds: 1.0, quad: nil)
        XCTAssertEqual(sim.captures.count, 1)
    }

    func testFallbackWhenTurnWasMissed() {
        // めくりの動きが映らなかった（画面外で差し替えた）場合でも、長く静止すれば撮る
        var sim = Sim()
        sim.hold(page: 1, seconds: 1.5)
        sim.hold(page: 2, seconds: 4)
        XCTAssertEqual(sim.captures.count, 2)
    }

    func testFailedCaptureRearms() {
        var sim = Sim()
        let img = Fixtures.pageImage(seed: 1)
        var fired = false
        for _ in 0..<30 {
            let thumb = Fixtures.noisy(img, amplitude: 2, rng: &sim.rng)
            let s = FrameSample(time: sim.t, thumb: thumb, sharpness: 100, quad: Fixtures.quad)
            if sim.engine.process(s) {
                fired = true
                sim.engine.notifyCaptureFinished(success: false)
                break
            }
            sim.t += 1 / 15
        }
        XCTAssertTrue(fired)
        XCTAssertTrue(sim.engine.isArmed)
        sim.captureLatency = 0.1
        sim.hold(page: 1, seconds: 1.5)
        XCTAssertEqual(sim.captures.count, 1)
    }

    func testRetakeBeforeTurn() {
        var sim = Sim()
        sim.hold(page: 1, seconds: 1.5)
        XCTAssertEqual(sim.captures.count, 1)
        XCTAssertTrue(sim.engine.requestRetakeIfNotTurned())
        sim.hold(page: 1, seconds: 1.5)
        XCTAssertEqual(sim.captures.count, 2)
        sim.turn()
        sim.hold(page: 2, seconds: 0.2)
        XCTAssertFalse(sim.engine.requestRetakeIfNotTurned(), "めくった後は撮り直さない")
    }

    func testManualCaptureResetsCycle() {
        var sim = Sim()
        sim.engine.autoEnabled = false
        sim.hold(page: 1, seconds: 2)
        XCTAssertEqual(sim.captures.count, 0)
        sim.engine.notifyCaptureStarted(thumb: nil)
        sim.engine.notifyCaptureFinished(success: true)
        sim.engine.autoEnabled = true
        sim.hold(page: 1, seconds: 2)
        XCTAssertEqual(sim.captures.count, 0, "手動で撮ったページを自動でもう一度撮らない")
        sim.turn()
        sim.hold(page: 2, seconds: 1.5)
        XCTAssertEqual(sim.captures.count, 1)
    }

    func testBlurryMomentIsSkipped() {
        var sim = Sim()
        let img = Fixtures.pageImage(seed: 1)
        // 静止中に一瞬だけピンボケ
        var captureSharpness: [Double] = []
        for i in 0..<40 {
            let sharp = (i >= 6 && i <= 12) ? 30.0 : 100.0
            let thumb = Fixtures.noisy(img, amplitude: 2, rng: &sim.rng)
            let s = FrameSample(time: sim.t, thumb: thumb, sharpness: sharp, quad: Fixtures.quad)
            if sim.engine.process(s) { captureSharpness.append(sharp) }
            sim.t += 1 / 15
        }
        XCTAssertEqual(captureSharpness, [100.0])
    }

    /// 実際の使い方：シャッターが切れるまで（最大5秒）押さえてからめくる。
    /// 手ぶれの強さ・紙を押さえる手・ピント合わせ・長い休憩をランダムに混ぜる
    func testRandomizedLongSessionCapturesEachPageExactlyOnce() {
        for speed in CaptureSpeed.allCases {
            var sim = Sim(CaptureTuning.preset(speed))
            var rng = SeededRandom(2024)
            let pages = 200
            var waits: [Double] = []
            for page in 1...pages {
                let seed = UInt64(page)
                let before = sim.captures.count
                let start = sim.t
                if rng.double() < 0.2 {
                    sim.hold(page: seed, seconds: 0.2 + rng.double() * 0.6, jitter: rng.int(1...4), hand: true)
                }
                if rng.double() < 0.15 {
                    sim.hold(page: seed, seconds: 0.2 + rng.double() * 0.4, jitter: 2, focusing: true)
                }
                // 手ぶれ：ふだんは小さく、ときどき大きい
                let jitter = rng.double() < 0.15 ? rng.int(5...6) : rng.int(1...4)
                var held = 0.0
                while sim.captures.count == before && held < 5 {
                    sim.hold(page: seed, seconds: 0.2, jitter: jitter)
                    held += 0.2
                }
                XCTAssertEqual(sim.captures.count, before + 1, "speed \(speed) page \(page) was never captured")
                waits.append(sim.t - start)
                // シャッター後すぐめくる人も、少し待つ人も
                sim.hold(page: seed, seconds: rng.double() * 0.8, jitter: jitter)
                if rng.double() < 0.05 {
                    sim.hold(page: seed, seconds: 8, jitter: rng.int(1...4))
                }
                if page < pages {
                    sim.turn(seconds: 0.25 + rng.double() * 0.6, hand: rng.double() < 0.8)
                }
            }
            XCTAssertEqual(sim.captures.count, pages, "speed \(speed)")
            XCTAssertEqual(sim.engine.missedPageCount, 0, "speed \(speed)")
            let typical = ImageMetrics.percentile(waits, 0.5)
            XCTAssertLessThan(typical, CaptureTuning.preset(speed).stableDuration + 0.8, "speed \(speed) median wait")
        }
    }

    func testTurningBeforeShutterIsReportedAsMissed() {
        var sim = Sim()
        sim.hold(page: 1, seconds: 1.5)
        XCTAssertEqual(sim.captures.count, 1)
        sim.turn()
        // 2ページ目をちらっと見せただけで、撮る前にめくってしまう
        sim.hold(page: 2, seconds: 0.45, jitter: 9)
        sim.turn()
        sim.hold(page: 3, seconds: 1.5)
        XCTAssertEqual(sim.captures.count, 2)
        XCTAssertEqual(sim.engine.missedPageCount, 1)
    }

    func testQuickFlipThroughIsNotCountedAsMisses() {
        // 連続でパラパラめくる（ページが落ち着いて見えない）のは撮り逃しにしない
        var sim = Sim()
        sim.hold(page: 1, seconds: 1.5)
        sim.turn(seconds: 1.5)
        sim.hold(page: 9, seconds: 1.5)
        XCTAssertEqual(sim.engine.missedPageCount, 0)
        XCTAssertEqual(sim.captures.count, 2)
    }

    func testArmCapturesCurrentPageAgain() {
        var sim = Sim()
        sim.hold(page: 1, seconds: 1.5)
        XCTAssertEqual(sim.captures.count, 1)
        sim.engine.arm()
        sim.hold(page: 1, seconds: 1.5)
        XCTAssertEqual(sim.captures.count, 2)
        sim.hold(page: 1, seconds: 3)
        XCTAssertEqual(sim.captures.count, 2)
    }
}

