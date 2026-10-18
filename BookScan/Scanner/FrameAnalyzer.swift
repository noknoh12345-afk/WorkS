import Foundation
import CoreVideo
import Vision
import ScanCore

/// カメラの1フレームから「動き・鮮明さ・紙の輪郭・紙の上の手」を求める（videoQueue 上で使う）
final class FrameAnalyzer {
    static let thumbW = 32
    static let thumbH = 24

    private let documentRequest = VNDetectDocumentSegmentationRequest()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private var frameIndex = 0
    private var lastQuad: Quad?
    private var lastQuadTime = -10.0
    private var lastHand = false
    private var lastHandTime = -10.0

    /// 撮影時に使う：直近で安定していた紙の輪郭
    private(set) var recentQuad: Quad?

    func reset() {
        frameIndex = 0
        lastQuad = nil
        lastHand = false
        recentQuad = nil
    }

    func analyze(_ pb: CVPixelBuffer, time: Double, adjustingFocus: Bool) -> FrameSample {
        frameIndex += 1
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let (thumb, sharpness) = lumaMetrics(pb)
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)

        // 紙の輪郭は毎フレーム、手は2フレームに1回
        if let q = detectDocument(pb) {
            lastQuad = q
            lastQuadTime = time
            recentQuad = q
        } else if time - lastQuadTime > 0.25 {
            lastQuad = nil
        }
        if frameIndex % 2 == 0 {
            lastHand = detectHandOverPage(pb, quad: lastQuad)
            lastHandTime = time
        } else if time - lastHandTime > 0.4 {
            lastHand = false
        }
        return FrameSample(time: time, thumb: thumb, sharpness: sharpness, quad: lastQuad,
                           handOverPage: lastHand, adjustingFocus: adjustingFocus)
    }

    // MARK: 輝度から縮小画像と鮮明さ

    private func lumaMetrics(_ pb: CVPixelBuffer) -> ([UInt8], Double) {
        let planar = CVPixelBufferIsPlanar(pb)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb) else {
            return ([UInt8](repeating: 0, count: Self.thumbW * Self.thumbH), 0)
        }
        let width = planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)

        // 32x24 の平均（各セルから 8x8 点を間引いて平均）
        var thumb = [UInt8](repeating: 0, count: Self.thumbW * Self.thumbH)
        let cellW = width / Self.thumbW
        let cellH = height / Self.thumbH
        let sx = max(1, cellW / 8), sy = max(1, cellH / 8)
        for ty in 0..<Self.thumbH {
            for tx in 0..<Self.thumbW {
                var sum = 0, n = 0
                var y = ty * cellH
                while y < (ty + 1) * cellH {
                    let row = p + y * rowBytes
                    var x = tx * cellW
                    while x < (tx + 1) * cellW {
                        sum += Int(row[x])
                        n += 1
                        x += sx
                    }
                    y += sy
                }
                thumb[ty * Self.thumbW + tx] = UInt8(n > 0 ? sum / n : 0)
            }
        }

        // 中央部分の鮮明さ（320x240 程度に間引いてラプラシアン分散）
        let cw = width / 2, ch = height / 2
        let ox = width / 4, oy = height / 4
        let step = max(1, cw / 320)
        let gw = cw / step, gh = ch / step
        guard gw >= 3, gh >= 3 else { return (thumb, 0) }
        var gray = [UInt8](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            let row = p + (oy + gy * step) * rowBytes
            for gx in 0..<gw {
                gray[gy * gw + gx] = row[ox + gx * step]
            }
        }
        let sharp = ImageMetrics.laplacianVariance(GrayImage(width: gw, height: gh, pixels: gray))
        return (thumb, sharp)
    }

    // MARK: Vision

    /// 正規化座標（バッファの左上原点）の紙の輪郭
    private func detectDocument(_ pb: CVPixelBuffer) -> Quad? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        do { try handler.perform([documentRequest]) } catch { return nil }
        guard let obs = documentRequest.results?.first, obs.confidence >= 0.5 else { return nil }
        let q = Quad(topLeft: Point2(Double(obs.topLeft.x), 1 - Double(obs.topLeft.y)),
                     topRight: Point2(Double(obs.topRight.x), 1 - Double(obs.topRight.y)),
                     bottomRight: Point2(Double(obs.bottomRight.x), 1 - Double(obs.bottomRight.y)),
                     bottomLeft: Point2(Double(obs.bottomLeft.x), 1 - Double(obs.bottomLeft.y)))
        guard q.isConvex, q.area > 0.08 else { return nil }
        return q
    }

    /// 紙の内側（縁から15%以上内側）に手・指があるか。縁を押さえる指は許す
    private func detectHandOverPage(_ pb: CVPixelBuffer, quad: Quad?) -> Bool {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        do { try handler.perform([handRequest]) } catch { return false }
        guard let hands = handRequest.results, !hands.isEmpty else { return false }
        let region = quad ?? Quad(topLeft: Point2(0.25, 0.25), topRight: Point2(0.75, 0.25),
                                  bottomRight: Point2(0.75, 0.75), bottomLeft: Point2(0.25, 0.75))
        let inset = quad == nil ? 0.0 : 0.15
        for hand in hands {
            guard let points = try? hand.recognizedPoints(.all) else { continue }
            var inside = 0
            for (_, pt) in points where pt.confidence > 0.35 {
                let p = Point2(Double(pt.location.x), 1 - Double(pt.location.y))
                if region.containsInset(p, inset: inset) { inside += 1 }
            }
            // 指先1本だけ（ページを押さえる）は無視して、手のひら・複数の指が入っていたら手とみなす
            if inside >= 4 { return true }
        }
        return false
    }
}
