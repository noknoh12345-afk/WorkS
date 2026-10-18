import Foundation
import UIKit
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import ScanCore

/// 1回の撮影の処理依頼
struct ScanJob {
    let id = UUID()
    let data: Data
    let spread: Bool
    let rtl: Bool
    let bookID: UUID
    let filter: PageFilter
    let quality: Double
    let keepRaw: Bool
    /// 撮影直前のプレビューで見えていた紙の輪郭（センサー座標。写真で見つからないときの予備）
    let previewQuad: Quad?
    /// 写真の回転（センサーの横向きから時計回りの角度）
    let captureAngle: Double
}

/// 処理済みのページ（ファイルは保存済み）
struct ProcessedPage {
    var page: Page
    var candidate: PageCandidate
    var numberCandidates: [Int]
}

enum CaptureProcessor {
    /// 重い処理。呼び出し側で順番に（直列で）実行すること
    static func process(_ job: ScanJob) -> [ProcessedPage] {
        autoreleasepool { () -> [ProcessedPage] in
            guard let full = decodeOriented(job.data) else { return [] }
            Paths.ensure(Paths.bookDir(job.bookID))

            // 元写真（あとから範囲を調整できるように）
            var rawName: String?
            if job.keepRaw {
                let name = "raw/\(UUID().uuidString).jpg"
                if ImageIOHelper.writeJPEG(full, to: Paths.pageFile(bookID: job.bookID, fileName: name), quality: 0.85) {
                    rawName = name
                }
            }

            // 紙の輪郭 → 台形補正
            let detected = detectQuad(full, spread: job.spread)
            let fromPreview = job.previewQuad.map { $0.rotated(clockwiseDegrees: job.captureAngle) }
            let quad = detected ?? fromPreview.flatMap { usableQuad($0, spread: job.spread) }
            let cropFound = quad != nil
            let corrected = quad.flatMap { perspectiveCorrect(full, quad: $0) } ?? full

            // 見開きなら左右に分ける（綴じ方向の順）
            var images: [(CGImage, String?)] = [(corrected, nil)]
            if job.spread, let halves = SpreadSplitter.split(corrected) {
                let l = (halves.0, Optional("left")), r = (halves.1, Optional("right"))
                images = job.rtl ? [r, l] : [l, r]
            }

            var out: [ProcessedPage] = []
            for (image, half) in images {
                autoreleasepool {
                    var page = Page(fileName: UUID().uuidString + ".jpg", filter: job.filter)
                    guard ImageIOHelper.writeJPEG(image, to: Paths.pageFile(bookID: job.bookID, fileName: page.fileName),
                                                  quality: job.quality) else { return }
                    page.rawFileName = rawName
                    page.rawHalf = half
                    page.quad = (quad ?? .full).flatArray

                    let ocr = recognize(image)
                    page.ocrLines = ocr.lines
                    page.ocrRotation = 0
                    let numbers = PageNumberParser.candidates(from: ocr.boxes)
                    let hand = handOverPage(image)
                    let flags = QualityJudge.flags(textCharCount: ocr.charCount,
                                                   meanConfidence: ocr.meanConfidence,
                                                   lowConfidenceRatio: ocr.lowConfidenceRatio,
                                                   handOverPage: hand,
                                                   cropFound: cropFound)
                    page.flags = flags.map(\.rawValue).sorted()
                    let candidate = PageCandidate(numbers: numbers,
                                                  text: ocr.lines.map(\.text).joined(),
                                                  hash: hash(image),
                                                  flags: flags)
                    out.append(ProcessedPage(page: page, candidate: candidate, numberCandidates: numbers))
                }
            }
            return out
        }
    }

    // MARK: 読み込み

    /// 向き情報を反映して読み込む
    static func decodeOriented(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 4032
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 3024
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h)
        ] as [CFString: Any] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
    }

    static func downscaled(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longSide = max(image.width, image.height)
        guard longSide > maxPixel else { return image }
        let s = Double(maxPixel) / Double(longSide)
        let w = max(1, Int(Double(image.width) * s)), h = max(1, Int(Double(image.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func gray(_ image: CGImage, width w: Int, height h: Int) -> GrayImage? {
        var buffer = [UInt8](repeating: 0, count: w * h)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? GrayImage(width: w, height: h, pixels: buffer) : nil
    }

    // MARK: 紙の輪郭

    static func usableQuad(_ q: Quad, spread: Bool) -> Quad? {
        guard q.isConvex, q.area > (spread ? 0.2 : 0.1) else { return nil }
        return q
    }

    /// 写真の中の紙（見開きなら本全体）の四隅。正規化・左上原点
    static func detectQuad(_ image: CGImage, spread: Bool) -> Quad? {
        guard let small = downscaled(image, maxPixel: 1280) else { return nil }
        let handler = VNImageRequestHandler(cgImage: small, orientation: .up, options: [:])
        let doc = VNDetectDocumentSegmentationRequest()
        if (try? handler.perform([doc])) != nil, let obs = doc.results?.first, obs.confidence >= 0.5,
           let q = usableQuad(quad(from: obs), spread: spread) {
            return q
        }
        let rect = VNDetectRectanglesRequest()
        rect.maximumObservations = 1
        rect.minimumSize = spread ? 0.4 : 0.3
        rect.minimumAspectRatio = 0.3
        rect.maximumAspectRatio = 1.0
        rect.quadratureTolerance = 25
        rect.minimumConfidence = 0.6
        if (try? handler.perform([rect])) != nil, let obs = rect.results?.first,
           let q = usableQuad(quad(from: obs), spread: spread) {
            return q
        }
        return nil
    }

    static func quad(from obs: VNRectangleObservation) -> Quad {
        Quad(topLeft: Point2(Double(obs.topLeft.x), 1 - Double(obs.topLeft.y)),
             topRight: Point2(Double(obs.topRight.x), 1 - Double(obs.topRight.y)),
             bottomRight: Point2(Double(obs.bottomRight.x), 1 - Double(obs.bottomRight.y)),
             bottomLeft: Point2(Double(obs.bottomLeft.x), 1 - Double(obs.bottomLeft.y)))
    }

    /// 四隅（正規化・左上原点）で台形補正
    static func perspectiveCorrect(_ image: CGImage, quad q: Quad) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        func ci(_ p: Point2) -> CGPoint { CGPoint(x: p.x * w, y: (1 - p.y) * h) }
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = CIImage(cgImage: image)
        f.topLeft = ci(q.topLeft)
        f.topRight = ci(q.topRight)
        f.bottomRight = ci(q.bottomRight)
        f.bottomLeft = ci(q.bottomLeft)
        guard var out = f.outputImage else { return nil }
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.origin.x, y: -out.extent.origin.y))
        let rect = out.extent.integral
        guard rect.width > 64, rect.height > 64 else { return nil }
        return ImageProcessor.context.createCGImage(out, from: rect)
    }

    // MARK: 文字認識

    struct OCRResult {
        var lines: [OCRLine] = []
        var boxes: [TextBox] = []
        var charCount = 0
        var meanConfidence = 1.0
        var lowConfidenceRatio = 0.0
    }

    static func recognize(_ image: CGImage) -> OCRResult {
        guard let src = downscaled(image, maxPixel: 2600) else { return OCRResult() }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ja-JP", "en-US"]
        let handler = VNImageRequestHandler(cgImage: src, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return OCRResult() }
        var r = OCRResult()
        var confSum = 0.0
        var low = 0
        for obs in request.results ?? [] {
            guard let c = obs.topCandidates(1).first else { continue }
            let b = obs.boundingBox
            let line = OCRLine(text: c.string, x: Double(b.minX), y: Double(1 - b.maxY), w: Double(b.width), h: Double(b.height))
            r.lines.append(line)
            r.boxes.append(TextBox(text: c.string, x: line.x, y: line.y, w: line.w, h: line.h, confidence: Double(c.confidence)))
            r.charCount += c.string.count
            confSum += Double(c.confidence)
            if c.confidence < 0.4 { low += 1 }
        }
        if !r.lines.isEmpty {
            r.meanConfidence = confSum / Double(r.lines.count)
            r.lowConfidenceRatio = Double(low) / Double(r.lines.count)
        }
        return r
    }

    // MARK: 手写り・指紋

    /// 補正後のページの内側に手・指が写っているか
    static func handOverPage(_ image: CGImage) -> Bool {
        guard let small = downscaled(image, maxPixel: 1024) else { return false }
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let handler = VNImageRequestHandler(cgImage: small, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return false }
        for hand in request.results ?? [] {
            guard let pts = try? hand.recognizedPoints(.all) else { continue }
            var inside = 0
            for (_, p) in pts where p.confidence > 0.4 {
                let pt = Point2(Double(p.location.x), 1 - Double(p.location.y))
                if Quad.full.containsInset(pt, inset: 0.2) { inside += 1 }
            }
            if inside >= 4 { return true }
        }
        return false
    }

    static func hash(_ image: CGImage) -> ImageHash? {
        guard let g = gray(image, width: 272, height: 256) else { return nil }
        return ImageMetrics.differenceHash(g)
    }

    // MARK: 範囲の調整（元写真から作り直す）

    /// 元写真と四隅からページ画像を作り直す
    static func rebuild(rawURL: URL, quad: Quad, half: String?) -> CGImage? {
        guard let raw = ImageIOHelper.load(url: rawURL), let corrected = perspectiveCorrect(raw, quad: quad) else { return nil }
        guard let half else { return corrected }
        guard let halves = SpreadSplitter.split(corrected) else { return corrected }
        return half == "right" ? halves.1 : halves.0
    }
}

extension Quad {
    var flatArray: [Double] {
        [topLeft.x, topLeft.y, topRight.x, topRight.y, bottomRight.x, bottomRight.y, bottomLeft.x, bottomLeft.y]
    }

    init?(flat: [Double]?) {
        guard let f = flat, f.count == 8 else { return nil }
        self.init(topLeft: Point2(f[0], f[1]), topRight: Point2(f[2], f[3]),
                  bottomRight: Point2(f[4], f[5]), bottomLeft: Point2(f[6], f[7]))
    }
}
