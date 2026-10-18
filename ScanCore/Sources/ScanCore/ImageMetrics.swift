import Foundation

/// 8bit グレースケール画像（行優先）
public struct GrayImage: Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height, "invalid GrayImage")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
    }

    @inline(__always)
    public func at(_ x: Int, _ y: Int) -> UInt8 { pixels[y * width + x] }
}

/// 256bit の差分ハッシュ（dHash）。明暗差がはっきりした位置だけを比較に使う
public struct ImageHash: Equatable, Codable, Hashable {
    public var bits: [UInt64]
    /// 隣との明暗差が十分ある（＝ノイズに左右されにくい）位置
    public var strong: [UInt64]

    public init(bits: [UInt64], strong: [UInt64]) {
        self.bits = bits
        self.strong = strong
    }

    /// 0（同じ）〜1。比べられる模様が少なすぎる（白紙など）ときは nil
    public func dissimilarity(to other: ImageHash) -> Double? {
        guard bits.count == other.bits.count, strong.count == other.strong.count else { return nil }
        var union = 0
        var diff = 0
        for i in 0..<bits.count {
            let s = strong[i] | other.strong[i]
            union += s.nonzeroBitCount
            diff += ((bits[i] ^ other.bits[i]) & s).nonzeroBitCount
        }
        guard union >= 24 else { return nil }
        return Double(diff) / Double(union)
    }
}

public enum ImageMetrics {
    /// 同じ大きさの2枚の差（0〜1）
    public static func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count) / 255.0
    }

    /// 明るさとコントラストの差を打ち消した「内容」の違い（同じ内容なら 0 付近、別物なら 0.5 以上）
    public static func contentDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 1 }
        func stats(_ v: [UInt8]) -> (Double, Double) {
            var s = 0.0, s2 = 0.0
            for p in v { let d = Double(p); s += d; s2 += d * d }
            let n = Double(v.count)
            let mean = s / n
            let variance = max(s2 / n - mean * mean, 0)
            return (mean, max(sqrt(variance), 4.0))
        }
        let (ma, sa) = stats(a)
        let (mb, sb) = stats(b)
        var sum = 0.0
        for i in 0..<a.count {
            let za = (Double(a[i]) - ma) / sa
            let zb = (Double(b[i]) - mb) / sb
            sum += abs(za - zb)
        }
        return sum / Double(a.count) / 2.0
    }

    /// 平均プーリングで縮小
    public static func downsample(_ img: GrayImage, width w: Int, height h: Int) -> GrayImage {
        precondition(w > 0 && h > 0)
        var out = [UInt8](repeating: 0, count: w * h)
        for oy in 0..<h {
            let y0 = oy * img.height / h
            let y1 = max(y0 + 1, (oy + 1) * img.height / h)
            for ox in 0..<w {
                let x0 = ox * img.width / w
                let x1 = max(x0 + 1, (ox + 1) * img.width / w)
                var sum = 0
                var n = 0
                for y in y0..<min(y1, img.height) {
                    let row = y * img.width
                    for x in x0..<min(x1, img.width) {
                        sum += Int(img.pixels[row + x])
                        n += 1
                    }
                }
                out[oy * w + ox] = UInt8(n > 0 ? sum / n : 0)
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    /// 3x3 ラプラシアンの分散（ピントの鋭さの目安。大きいほど鮮明）
    public static func laplacianVariance(_ img: GrayImage) -> Double {
        guard img.width >= 3, img.height >= 3 else { return 0 }
        var sum = 0.0, sum2 = 0.0
        var n = 0.0
        let w = img.width
        img.pixels.withUnsafeBufferPointer { p in
            for y in 1..<(img.height - 1) {
                let row = y * w
                for x in 1..<(w - 1) {
                    let c = Int(p[row + x]) * 4
                    let l = c - Int(p[row + x - 1]) - Int(p[row + x + 1]) - Int(p[row - w + x]) - Int(p[row + w + x])
                    let d = Double(l)
                    sum += d
                    sum2 += d * d
                    n += 1
                }
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return max(sum2 / n - mean * mean, 0)
    }

    /// 差分ハッシュ（16x16 = 256bit）。撮り直した同じページなら差が小さい
    public static func differenceHash(_ img: GrayImage, strongDelta: Int = 4) -> ImageHash {
        let small = downsample(img, width: 17, height: 16)
        var bits = [UInt64](repeating: 0, count: 4)
        var strong = [UInt64](repeating: 0, count: 4)
        var k = 0
        for y in 0..<16 {
            for x in 0..<16 {
                let a = Int(small.at(x, y)), b = Int(small.at(x + 1, y))
                let mask = UInt64(1) << UInt64(k % 64)
                if a > b { bits[k / 64] |= mask }
                if abs(a - b) >= strongDelta { strong[k / 64] |= mask }
                k += 1
            }
        }
        return ImageHash(bits: bits, strong: strong)
    }

    /// 0〜1 の分位点
    public static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded())))
        return sorted[idx]
    }
}
