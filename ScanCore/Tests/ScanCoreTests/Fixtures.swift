import Foundation
@testable import ScanCore

/// 決定的な疑似乱数（テストの再現性のため）
struct SeededRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 33)) &* 0xff51afd7ed558ccd
        z = (z ^ (z >> 33)) &* 0xc4ceb9fe1a85ec53
        return z ^ (z >> 33)
    }
    mutating func double() -> Double { Double(next() % 1_000_000) / 1_000_000 }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }
}

enum Fixtures {
    static let thumbW = 32
    static let thumbH = 24

    /// 「ページ」らしい画像：白地に文字の行と図版（seed ごとに配置が変わる）。
    /// レイアウトは 32x24 の粗いグリッドで決め、指定サイズに拡大して描く（行の太さが画像サイズに比例）
    static func pageImage(seed: UInt64, width: Int = 32, height: Int = 24, shiftX: Int = 0, shiftY: Int = 0,
                          brightness: Int = 0) -> GrayImage {
        var rng = SeededRandom(seed)
        let gw = 32, gh = 24
        var grid = [UInt8](repeating: 235, count: gw * gh)
        let lines = rng.int(5...9)
        for _ in 0..<lines {
            let y = rng.int(2...(gh - 3))
            let x0 = rng.int(2...(gw / 3))
            let x1 = rng.int((gw / 2)...(gw - 3))
            for x in x0...x1 { grid[y * gw + x] = UInt8(rng.int(30...90)) }
        }
        if rng.double() < 0.5 {
            let bx = rng.int(2...(gw / 2)), by = rng.int(2...(gh / 2))
            for y in by..<min(gh, by + gh / 4) {
                for x in bx..<min(gw, bx + gw / 3) { grid[y * gw + x] = 120 }
            }
        }
        var px = [UInt8](repeating: 235, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let sx = x - shiftX, sy = y - shiftY
                guard sx >= 0, sx < width, sy >= 0, sy < height else { continue }
                let gx = min(gw - 1, sx * gw / width), gy = min(gh - 1, sy * gh / height)
                px[y * width + x] = grid[gy * gw + gx]
            }
        }
        if brightness != 0 {
            px = px.map { UInt8(max(0, min(255, Int($0) + brightness))) }
        }
        return GrayImage(width: width, height: height, pixels: px)
    }

    /// カメラのノイズを加える
    static func noisy(_ img: GrayImage, amplitude: Int, rng: inout SeededRandom) -> [UInt8] {
        img.pixels.map { p in
            let n = rng.int(-amplitude...amplitude)
            return UInt8(max(0, min(255, Int(p) + n)))
        }
    }

    /// めくり途中の画像（手と紙が大きく動く）
    static func turningFrame(rng: inout SeededRandom) -> [UInt8] {
        (0..<(thumbW * thumbH)).map { _ in UInt8(rng.int(0...255)) }
    }

    static let quad = Quad(topLeft: Point2(0.1, 0.1), topRight: Point2(0.9, 0.1),
                           bottomRight: Point2(0.9, 0.9), bottomLeft: Point2(0.1, 0.9))

    static func jittered(_ q: Quad, _ amount: Double, rng: inout SeededRandom) -> Quad {
        func j(_ p: Point2) -> Point2 { Point2(p.x + (rng.double() - 0.5) * amount, p.y + (rng.double() - 0.5) * amount) }
        return Quad(topLeft: j(q.topLeft), topRight: j(q.topRight), bottomRight: j(q.bottomRight), bottomLeft: j(q.bottomLeft))
    }

    // 自作の日本語テキスト（別々のページの本文）
    static let pageA = """
    朝の駅はいつもより静かだった。改札を抜けると、冷たい風が頬に当たり、思わず上着の襟を立てた。
    ホームには数人の乗客が並んでいて、それぞれが手元の画面を眺めている。遠くで踏切の音が鳴り始め、
    やがて銀色の車両がゆっくりと滑り込んできた。窓の向こうに見える景色は、昨日と何も変わらないはずなのに、
    今朝はどこか新しく感じられた。
    """
    static let pageB = """
    研究室に着くと、机の上に一通の封筒が置かれていた。差出人の名前はなく、宛名だけが丁寧な文字で書かれている。
    中には古い写真が一枚と、短い手紙が入っていた。写真には海辺の町が写っていて、手前に小さな灯台が見える。
    手紙には、この場所を探してほしいとだけ記されていた。私はしばらく写真を見つめたまま、動けなかった。
    """
    static let pageC = """
    第三章では、実験の手順と結果について説明する。まず、試料を一定の温度で十分に乾燥させ、重さを正確に測定した。
    次に、それぞれの試料を三つの条件に分けて保存し、一週間ごとに変化を記録した。その結果、湿度の高い条件では
    表面の色が早い段階で変わることが確認された。以下の表に、測定した値をまとめて示す。
    """

    /// 文字認識のゆれを再現（文字の置き換え・欠落・改行位置の違い）
    static func ocrNoise(_ s: String, rate: Double, seed: UInt64) -> String {
        var rng = SeededRandom(seed)
        let confusions: [Character: Character] = ["は": "ば", "た": "だ", "し": "じ", "口": "ロ", "一": "ー", "が": "か", "て": "で", "ろ": "る"]
        var out = ""
        for ch in s {
            let r = rng.double()
            if ch == "\n" { if rng.double() < 0.5 { out.append(" ") }; continue }
            if r < rate * 0.4 { continue }
            if r < rate, let c = confusions[ch] { out.append(c); continue }
            if r < rate { out.append("・"); continue }
            out.append(ch)
            if rng.double() < 0.02 { out.append("\n") }
        }
        return out
    }
}
