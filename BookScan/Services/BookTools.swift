import Foundation
import UIKit
import ImageIO
import PDFKit

extension ImageIOHelper {
    /// ファイルを開かずにピクセルサイズだけ読む
    static func pixelSize(url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 回転を考慮した表示サイズ
    static func displaySize(bookID: UUID, page: Page) -> CGSize? {
        guard let s = pixelSize(url: Paths.pageFile(bookID: bookID, fileName: page.fileName)) else { return nil }
        return page.normalizedRotation % 2 == 1 ? CGSize(width: s.height, height: s.width) : s
    }
}

/// 見開きで撮った1枚を左右2ページに分ける
enum SpreadSplitter {
    /// のど（綴じ目の影）の位置を推定する。見つからなければ中央
    static func gutterX(_ image: CGImage) -> Int {
        let fullW = image.width
        let fullH = image.height
        guard fullW > 20, fullH > 20 else { return fullW / 2 }
        let w = 600
        let scale = Double(w) / Double(fullW)
        let h = max(20, Int(Double(fullH) * scale))
        var buffer = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return fullW / 2 }

        // 上下の端は影や机が映りやすいので中央 80% の行だけを見る
        let y0 = h / 10, y1 = h - h / 10
        var columns = [Double](repeating: 0, count: w)
        for x in 0..<w {
            var sum = 0
            for y in y0..<y1 { sum += Int(buffer[y * w + x]) }
            columns[x] = Double(sum) / Double(max(y1 - y0, 1))
        }
        // 平滑化
        var smooth = columns
        let r = 4
        for x in 0..<w {
            let a = max(0, x - r), b = min(w - 1, x + r)
            smooth[x] = columns[a...b].reduce(0, +) / Double(b - a + 1)
        }
        let lo = Int(Double(w) * 0.38), hi = Int(Double(w) * 0.62)
        var best = w / 2
        var bestValue = Double.greatestFiniteMagnitude
        for x in lo..<hi where smooth[x] < bestValue {
            bestValue = smooth[x]
            best = x
        }
        let window = smooth[lo..<hi].sorted()
        let median = window[window.count / 2]
        // はっきりした影がない場合は中央で分ける
        if median - bestValue < 6 { return fullW / 2 }
        return Int(Double(best) / scale)
    }

    /// 左右に切り分けた CGImage（左, 右）
    static func split(_ image: CGImage) -> (CGImage, CGImage)? {
        let x = gutterX(image)
        let h = image.height
        guard x > 10, x < image.width - 10,
              let left = image.cropping(to: CGRect(x: 0, y: 0, width: x, height: h)),
              let right = image.cropping(to: CGRect(x: x, y: 0, width: image.width - x, height: h)) else { return nil }
        return (left, right)
    }
}

enum PDFPageRenderer {
    /// PDF の1ページを長辺 maxPixel の画像にする
    static func render(_ page: PDFPage, maxPixel: CGFloat = 2600) -> UIImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = abs(page.rotation) % 180 == 90
        let w = rotated ? bounds.height : bounds.width
        let h = rotated ? bounds.width : bounds.height
        guard w > 0, h > 0 else { return nil }
        let s = maxPixel / max(w, h)
        let size = CGSize(width: (w * s).rounded(), height: (h * s).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: s, y: -s)
            page.draw(with: .mediaBox, to: cg)
        }
    }
}
