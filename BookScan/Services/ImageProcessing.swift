import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision

enum ImageProcessor {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func orientation(for rotation: Int) -> CGImagePropertyOrientation {
        switch ((rotation % 4) + 4) % 4 {
        case 1: return .right
        case 2: return .down
        case 3: return .left
        default: return .up
        }
    }

    /// 元画像にフィルターと回転を適用してレンダリングする
    static func render(url: URL, filter: PageFilter, rotation: Int, maxPixel: CGFloat?) -> CGImage? {
        let base: CIImage
        if let maxPixel {
            guard let cg = ImageIOHelper.downsample(url: url, maxPixel: maxPixel) else { return nil }
            base = CIImage(cgImage: cg)
        } else {
            guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
            base = ci
        }
        var out = apply(filter, to: base)
        out = out.oriented(orientation(for: rotation))
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.origin.x, y: -out.extent.origin.y))
        let rect = out.extent.integral
        guard rect.width > 0, rect.height > 0 else { return nil }
        return context.createCGImage(out, from: rect)
    }

    static func apply(_ filter: PageFilter, to input: CIImage) -> CIImage {
        let extent = input.extent
        var img = input
        switch filter {
        case .original:
            return input
        case .enhanced:
            img = enhanceDocument(img)
            img = sharpen(img, amount: 0.45)
        case .grayscale:
            img = enhanceDocument(img)
            let c = CIFilter.colorControls()
            c.inputImage = img
            c.saturation = 0
            c.contrast = 1.08
            img = c.outputImage ?? img
            img = sharpen(img, amount: 0.5)
        case .blackWhite:
            img = enhanceDocument(img)
            let c = CIFilter.colorControls()
            c.inputImage = img
            c.saturation = 0
            c.contrast = 1.15
            img = c.outputImage ?? img
            img = sharpen(img, amount: 0.4)
            let t = CIFilter.colorThresholdOtsu()
            t.inputImage = img
            img = t.outputImage ?? img
        }
        return img.cropped(to: extent)
    }

    /// 影の除去・背景の白色化・コントラスト強調（メモアプリの書類スキャン相当）
    static func enhanceDocument(_ input: CIImage) -> CIImage {
        if let f = CIFilter(name: "CIDocumentEnhancer") {
            f.setValue(input, forKey: kCIInputImageKey)
            f.setValue(1.0, forKey: "inputAmount")
            if let out = f.outputImage { return out.cropped(to: input.extent) }
        }
        return flattenIllumination(input)
    }

    /// CIDocumentEnhancer が使えない場合の代替: 背景の明るさムラを割り算で平坦化
    static func flattenIllumination(_ input: CIImage) -> CIImage {
        let extent = input.extent
        let longSide = max(extent.width, extent.height)
        let radius = max(8, longSide / 60)
        let maxed = input.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": radius / 3])
        let background = maxed.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius]).cropped(to: extent)
        // CIDivideBlendMode: 結果 = 背景画像 ÷ 入力画像 → 元画像 ÷ 推定した紙の明るさ
        let divided = background.applyingFilter("CIDivideBlendMode", parameters: ["inputBackgroundImage": input])
        let c = CIFilter.colorControls()
        c.inputImage = divided.cropped(to: extent)
        c.contrast = 1.12
        c.brightness = 0.0
        c.saturation = 1.1
        return (c.outputImage ?? input).cropped(to: extent)
    }

    static func sharpen(_ input: CIImage, amount: Float) -> CIImage {
        let s = CIFilter.unsharpMask()
        s.inputImage = input
        s.radius = 1.6
        s.intensity = amount
        return (s.outputImage ?? input).cropped(to: input.extent)
    }
}

enum DocumentDetector {
    /// 写真から書類の輪郭を検出し、台形補正して切り抜く。検出できなければ nil
    static func autoCrop(_ image: CGImage) -> CGImage? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first, obs.confidence > 0.6 else { return nil }

        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let pts = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft]
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let areaFraction = (xs.max()! - xs.min()!) * (ys.max()! - ys.min()!)
        // 画像ほぼ全体 or 小さすぎる検出は無視
        guard areaFraction > 0.15, areaFraction < 0.985 else { return nil }

        let f = CIFilter.perspectiveCorrection()
        f.inputImage = CIImage(cgImage: image)
        f.topLeft = CGPoint(x: obs.topLeft.x * w, y: obs.topLeft.y * h)
        f.topRight = CGPoint(x: obs.topRight.x * w, y: obs.topRight.y * h)
        f.bottomLeft = CGPoint(x: obs.bottomLeft.x * w, y: obs.bottomLeft.y * h)
        f.bottomRight = CGPoint(x: obs.bottomRight.x * w, y: obs.bottomRight.y * h)
        guard var out = f.outputImage else { return nil }
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.origin.x, y: -out.extent.origin.y))
        let rect = out.extent.integral
        guard rect.width > 32, rect.height > 32 else { return nil }
        return ImageProcessor.context.createCGImage(out, from: rect)
    }
}

enum OCRService {
    /// 日本語・英語の文字認識（回転を考慮）
    static func recognize(url: URL, rotation: Int) -> [OCRLine] {
        guard let cg = ImageIOHelper.downsample(url: url, maxPixel: 3200) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ja-JP", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, orientation: ImageProcessor.orientation(for: rotation), options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let observations = request.results ?? []
        return observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox
            return OCRLine(text: candidate.string,
                           x: Double(b.minX),
                           y: Double(1 - b.maxY),
                           w: Double(b.width),
                           h: Double(b.height))
        }
    }
}
