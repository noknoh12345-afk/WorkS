import Foundation

public struct Point2: Equatable, Codable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to o: Point2) -> Double {
        let dx = x - o.x, dy = y - o.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// 書類の四隅（正規化座標）
public struct Quad: Equatable, Codable {
    public var topLeft: Point2
    public var topRight: Point2
    public var bottomRight: Point2
    public var bottomLeft: Point2

    public init(topLeft: Point2, topRight: Point2, bottomRight: Point2, bottomLeft: Point2) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public static let full = Quad(topLeft: Point2(0, 0), topRight: Point2(1, 0),
                                  bottomRight: Point2(1, 1), bottomLeft: Point2(0, 1))

    public var points: [Point2] { [topLeft, topRight, bottomRight, bottomLeft] }

    public func maxCornerDistance(to o: Quad) -> Double {
        zip(points, o.points).map { $0.distance(to: $1) }.max() ?? 0
    }

    /// 面積（靴ひも公式）
    public var area: Double {
        let p = points
        var s = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    public var isConvex: Bool {
        let p = points
        var sign = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-9 { return false }
            if sign == 0 { sign = cross } else if sign * cross < 0 { return false }
        }
        return true
    }

    /// 4点から、位置に合わせて左上・右上・右下・左下を決め直す
    public static func ordered(_ pts: [Point2]) -> Quad? {
        guard pts.count == 4 else { return nil }
        guard let tl = pts.min(by: { $0.x + $0.y < $1.x + $1.y }),
              let br = pts.max(by: { $0.x + $0.y < $1.x + $1.y }),
              let tr = pts.max(by: { $0.x - $0.y < $1.x - $1.y }),
              let bl = pts.min(by: { $0.x - $0.y < $1.x - $1.y }) else { return nil }
        let q = Quad(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
        return Set(q.points.map { "\($0.x),\($0.y)" }).count == 4 ? q : nil
    }

    /// カメラのセンサー座標（横向き）の四隅を、時計回りに degrees 回転した写真の座標に変換
    public func rotated(clockwiseDegrees degrees: Double) -> Quad {
        let k = ((Int((degrees / 90).rounded()) % 4) + 4) % 4
        func map(_ p: Point2) -> Point2 {
            switch k {
            case 1: return Point2(1 - p.y, p.x)
            case 2: return Point2(1 - p.x, 1 - p.y)
            case 3: return Point2(p.y, 1 - p.x)
            default: return p
            }
        }
        return Quad.ordered(points.map(map)) ?? self
    }

    /// 内側に縮めた領域に点が入るか（手が紙の上にあるかの判定に使う）
    public func containsInset(_ pt: Point2, inset: Double) -> Bool {
        let c = Point2(points.map(\.x).reduce(0, +) / 4, points.map(\.y).reduce(0, +) / 4)
        let shrunk = points.map { Point2(c.x + ($0.x - c.x) * (1 - inset), c.y + ($0.y - c.y) * (1 - inset)) }
        var sign = 0.0
        for i in 0..<4 {
            let a = shrunk[i], b = shrunk[(i + 1) % 4]
            let cross = (b.x - a.x) * (pt.y - a.y) - (b.y - a.y) * (pt.x - a.x)
            if sign == 0 { sign = cross } else if sign * cross < 0 { return false }
        }
        return true
    }
}

/// 1フレーム分の解析結果
public struct FrameSample {
    public var time: Double
    public var thumb: [UInt8]
    public var sharpness: Double
    public var quad: Quad?
    public var handOverPage: Bool
    public var adjustingFocus: Bool

    public init(time: Double, thumb: [UInt8], sharpness: Double, quad: Quad?,
                handOverPage: Bool = false, adjustingFocus: Bool = false) {
        self.time = time
        self.thumb = thumb
        self.sharpness = sharpness
        self.quad = quad
        self.handOverPage = handOverPage
        self.adjustingFocus = adjustingFocus
    }
}

public enum CaptureSpeed: String, CaseIterable, Identifiable {
    case careful, normal, fast
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .careful: return "慎重"
        case .normal: return "標準"
        case .fast: return "速い"
        }
    }
}

public struct CaptureTuning: Equatable {
    /// 枠が見えているとき、何秒静止したら撮るか
    public var stableDuration: Double = 0.55
    /// 枠が見つからないとき、何秒静止したら撮るか
    public var noDocumentStableDuration: Double = 1.4
    /// 「静止」とみなす動きの下限・上限（手ぶれに合わせて自動調整される）
    public var minStableMotion: Double = 0.010
    public var maxStableMotion: Double = 0.040
    /// 「めくり」とみなす動き
    public var minTurnMotion: Double = 0.035
    public var turnMinDuration: Double = 0.10
    /// 枠の四隅の揺れ許容
    public var quadStableTolerance: Double = 0.025
    /// ピント合わせを待つ最長時間
    public var maxFocusWait: Double = 1.0
    /// めくりを見逃したときの保険：長く静止＆内容が変わっていれば撮る
    public var fallbackStableDuration: Double = 2.5
    public var fallbackContentChange: Double = 0.35
    /// 静止中に最も鮮明だった瞬間からどれだけ落ちたら待つか
    public var sharpnessDropRatio: Double = 0.6
    /// 撮影待ちのページがこの秒数以上見えていたのにめくられたら「撮り逃し」とみなす
    public var missDetectionVisibleTime: Double = 0.25

    public init() {}

    public static func preset(_ speed: CaptureSpeed) -> CaptureTuning {
        var t = CaptureTuning()
        switch speed {
        case .careful:
            t.stableDuration = 0.9
            t.noDocumentStableDuration = 2.0
            t.turnMinDuration = 0.15
        case .normal:
            break
        case .fast:
            t.stableDuration = 0.32
            t.noDocumentStableDuration = 1.0
            t.turnMinDuration = 0.07
        }
        return t
    }
}

public enum ScanStatus: Equatable {
    case starting
    case findingPage
    case holdStill(Double)
    case focusing
    case capturing
    case turnPage
    case turning
    case handOverPage
    case paused
}

/// 紙のめくりを見て、1ページにつき1回だけ自動撮影するための状態機械
public final class AutoCaptureEngine {
    public var tuning: CaptureTuning
    public var autoEnabled = true
    public private(set) var status: ScanStatus = .starting
    public private(set) var lastMotion: Double = 0
    public private(set) var stableProgress: Double = 0
    /// 最後の撮影以降にめくりを検知した回数
    public private(set) var turnsSinceCapture = 0
    /// 撮影する前にめくられてしまったページの数（累計）。増えたら利用者に知らせる
    public private(set) var missedPageCount = 0

    private var lastTime: Double?
    private var prevThumb: [UInt8]?
    private var motionHistory: [(t: Double, m: Double)] = []
    private var stableSince: Double?
    private var stableMaxSharpness = 0.0
    private var movingSince: Double?
    private var turnCountedForCurrentMove = false
    private var armed = true
    private var hasCaptured = false
    private var inFlight = false
    private var capturedThumb: [UInt8]?
    private var lastQuad: Quad?
    private var focusWaitStart: Double?
    private var lastSoftOutlier: Double?
    /// 撮影待ちのページが落ち着いて見えていた時間（めくられたら「撮り逃し」と判断する材料）
    private var visibleUncapturedSince: Double?

    public init(tuning: CaptureTuning = CaptureTuning()) {
        self.tuning = tuning
    }

    public func reset() {
        status = .starting
        lastMotion = 0
        stableProgress = 0
        turnsSinceCapture = 0
        lastTime = nil
        prevThumb = nil
        motionHistory = []
        stableSince = nil
        stableMaxSharpness = 0
        movingSince = nil
        turnCountedForCurrentMove = false
        armed = true
        hasCaptured = false
        inFlight = false
        capturedThumb = nil
        lastQuad = nil
        focusWaitStart = nil
        lastSoftOutlier = nil
        visibleUncapturedSince = nil
        missedPageCount = 0
    }

    public var isCapturing: Bool { inFlight }
    public var isArmed: Bool { armed }

    /// 手動撮影など、外から撮影が始まったことを伝える
    public func notifyCaptureStarted(thumb: [UInt8]?) {
        inFlight = true
        armed = false
        hasCaptured = true
        turnsSinceCapture = 0
        capturedThumb = thumb ?? prevThumb
        stableSince = nil
        stableMaxSharpness = 0
        status = .capturing
    }

    /// 撮影が終わった。失敗したらもう一度撮れる状態に戻す
    public func notifyCaptureFinished(success: Bool) {
        inFlight = false
        stableSince = nil
        stableMaxSharpness = 0
        if !success { armed = true }
    }

    /// 次に静止したら撮る状態にする（撮り直し対象が今写っているページのとき）
    public func arm() {
        guard !inFlight else { return }
        armed = true
        stableSince = nil
    }

    /// ブレ・手写りだったページを、めくる前ならそのまま撮り直す
    @discardableResult
    public func requestRetakeIfNotTurned() -> Bool {
        guard hasCaptured, turnsSinceCapture == 0, !inFlight else { return false }
        armed = true
        stableSince = nil
        return true
    }

    /// 1フレームを処理し、今撮るべきなら true
    public func process(_ s: FrameSample) -> Bool {
        let dt: Double = lastTime.map { max(0, min(0.5, s.time - $0)) } ?? 0
        _ = dt
        lastTime = s.time

        var motion = 0.0
        if let p = prevThumb, p.count == s.thumb.count {
            motion = ImageMetrics.meanAbsDiff(p, s.thumb)
        } else if prevThumb != nil {
            motion = 1
        }
        prevThumb = s.thumb
        lastMotion = motion

        motionHistory.append((s.time, motion))
        motionHistory.removeAll { s.time - $0.t > 1.5 }
        let floor = ImageMetrics.percentile(motionHistory.map(\.m), 0.2)
        let stableThreshold = min(max(floor * 2.2, tuning.minStableMotion), tuning.maxStableMotion)
        let turnThreshold = max(tuning.minTurnMotion, stableThreshold * 2.0)

        // 枠の揺れ
        var quadStable = true
        switch (s.quad, lastQuad) {
        case let (q?, lq?):
            quadStable = q.maxCornerDistance(to: lq) < tuning.quadStableTolerance
        case (nil, nil):
            quadStable = true
        default:
            quadStable = false
        }
        lastQuad = s.quad

        // めくりの検知（大きな動きが一定時間続く／手が紙の上で動く）
        let bigMotion = motion > turnThreshold
        let handMoving = s.handOverPage && motion > stableThreshold
        if bigMotion || handMoving {
            if movingSince == nil {
                movingSince = s.time
                turnCountedForCurrentMove = false
            }
            // 撮影中に始まっためくりも、撮影が終わった時点で数える（取りこぼし防止）
            if !turnCountedForCurrentMove, !inFlight, let since = movingSince,
               s.time - since >= tuning.turnMinDuration || handMoving {
                turnCountedForCurrentMove = true
                // 撮る前にめくられた：見えていたページを撮り逃した
                if armed, let seen = visibleUncapturedSince, since - seen >= tuning.missDetectionVisibleTime {
                    missedPageCount += 1
                }
                visibleUncapturedSince = nil
                if hasCaptured {
                    turnsSinceCapture += 1
                    armed = true
                }
            }
        } else {
            movingSince = nil
        }

        // 静止の判定（ごく短い揺れ1回までは許す）
        let strictStable = motion <= stableThreshold && !s.handOverPage && quadStable
        var isStable = strictStable
        if !strictStable, stableSince != nil, !s.handOverPage,
           motion <= stableThreshold * 1.8, motion < turnThreshold {
            if let last = lastSoftOutlier, s.time - last < 0.5 {
                isStable = false
            } else {
                lastSoftOutlier = s.time
                isStable = true
            }
        }
        if isStable {
            if stableSince == nil {
                stableSince = s.time
                stableMaxSharpness = s.sharpness
            }
            stableMaxSharpness = max(stableMaxSharpness, s.sharpness)
        } else {
            stableSince = nil
            stableMaxSharpness = 0
        }
        // 撮影待ちのページが見えている
        if armed && !inFlight && !bigMotion {
            if visibleUncapturedSince == nil { visibleUncapturedSince = s.time }
        } else if !armed || inFlight {
            visibleUncapturedSince = nil
        }
        let stableFor = stableSince.map { s.time - $0 } ?? 0
        let required = s.quad == nil ? tuning.noDocumentStableDuration : tuning.stableDuration
        stableProgress = armed ? min(1, stableFor / required) : 0

        if inFlight {
            status = .capturing
            return false
        }
        if s.handOverPage {
            status = .handOverPage
            return false
        }
        if bigMotion {
            status = hasCaptured ? .turning : .findingPage
            return false
        }

        // めくりを見逃した場合の保険
        if !armed, hasCaptured, stableFor >= tuning.fallbackStableDuration,
           let ct = capturedThumb, ct.count == s.thumb.count,
           ImageMetrics.contentDifference(ct, s.thumb) >= tuning.fallbackContentChange {
            armed = true
            turnsSinceCapture += 1
        }

        if !armed {
            status = autoEnabled ? .turnPage : .paused
            return false
        }
        guard autoEnabled else {
            status = .paused
            return false
        }
        guard isStable else {
            status = .holdStill(0)
            return false
        }
        if s.adjustingFocus {
            if focusWaitStart == nil { focusWaitStart = s.time }
            if let start = focusWaitStart, s.time - start < tuning.maxFocusWait {
                status = .focusing
                return false
            }
        } else {
            focusWaitStart = nil
        }
        let progress = min(1, stableFor / required)
        guard progress >= 1 else {
            status = .holdStill(progress)
            return false
        }
        if stableMaxSharpness > 0 && s.sharpness < stableMaxSharpness * tuning.sharpnessDropRatio {
            status = .holdStill(0.99)
            return false
        }

        // 撮影
        inFlight = true
        armed = false
        hasCaptured = true
        turnsSinceCapture = 0
        capturedThumb = s.thumb
        focusWaitStart = nil
        status = .capturing
        return true
    }
}
