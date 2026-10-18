import Foundation

/// 文字認識の1行（座標はページに対する正規化座標・原点は左上）
public struct TextBox: Equatable {
    public var text: String
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var confidence: Double

    public init(text: String, x: Double, y: Double, w: Double, h: Double, confidence: Double = 1) {
        self.text = text
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.confidence = confidence
    }
}

/// 余白に印刷されたページ番号を読み取る
public enum PageNumberParser {
    public static let maxPageNumber = 3000

    /// 「12」「- 12 -」「p.12」「12頁」「１２」「一二」「百二十三」などを数値に
    public static func parseNumber(_ raw: String) -> Int? {
        var s = foldWidth(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // 前後の飾りを外す
        let decorations: [String] = ["ページ", "頁", "page", "Page", "PAGE", "pp.", "pp", "p.", "P.", "p", "P", "No.", "no."]
        for d in decorations {
            if s.hasPrefix(d) { s = String(s.dropFirst(d.count)) }
            if s.hasSuffix(d) { s = String(s.dropLast(d.count)) }
        }
        let trimSet = CharacterSet(charactersIn: " -–—―‐−~〜・.,:;()[]{}<>«»「」『』【】〔〕（）［］｛｝〈〉《》|/\\*•·")
        s = s.trimmingCharacters(in: trimSet.union(.whitespaces))
        guard !s.isEmpty, s.count <= 6 else { return nil }

        if s.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard let v = Int(s), v > 0, v <= maxPageNumber else { return nil }
            // 先頭ゼロ（"007" など）はページ番号ではない可能性が高い
            if s.count > 1 && s.hasPrefix("0") { return nil }
            return v
        }
        if let v = parseKanji(s), v > 0, v <= maxPageNumber { return v }
        return nil
    }

    /// 全角数字・英字を半角に
    static func foldWidth(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            var v = u.value
            if v == 0x3000 { v = 0x20 }
            if v >= 0xFF01 && v <= 0xFF5E { v -= 0xFEE0 }
            if let scalar = Unicode.Scalar(v) { out.append(scalar) }
        }
        return String(out)
    }

    static let kanjiDigits: [Character: Int] = [
        "〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9
    ]

    /// 漢数字（「一二三」形式と「百二十三」形式の両方）
    static func parseKanji(_ s: String) -> Int? {
        let chars = Array(s)
        guard !chars.isEmpty else { return nil }
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
        let hasUnit = chars.contains { units[$0] != nil }
        if !hasUnit {
            var v = 0
            for c in chars {
                guard let d = kanjiDigits[c] else { return nil }
                v = v * 10 + d
            }
            if chars.count > 1 && kanjiDigits[chars[0]] == 0 { return nil }
            return v
        }
        var total = 0
        var current = 0
        for c in chars {
            if let d = kanjiDigits[c] {
                current = current * 10 + d
            } else if let u = units[c] {
                total += (current == 0 ? 1 : current) * u
                current = 0
            } else {
                return nil
            }
        }
        return total + current
    }

    /// 見出し（柱）の端にある番号「第2章 方法 37」などを拾う
    static func edgeNumber(_ text: String) -> Int? {
        let parts = foldWidth(text)
            .split(whereSeparator: { $0 == " " || $0 == "\u{3000}" || $0 == "\t" })
            .map(String.init)
        guard parts.count >= 2 else { return nil }
        if let last = parts.last, let v = parseNumber(last) { return v }
        if let first = parts.first, let v = parseNumber(first) { return v }
        return nil
    }

    /// ページ番号の候補（可能性の高い順）
    public static func candidates(from boxes: [TextBox]) -> [Int] {
        var scored: [(Int, Double)] = []
        for b in boxes {
            let top = b.y < 0.13
            let bottom = b.y + b.h > 0.87
            let side = b.x < 0.08 || b.x + b.w > 0.92
            let upperOrLower = b.y < 0.3 || b.y + b.h > 0.7
            guard top || bottom || (side && upperOrLower) else { continue }
            // 本文の行のように横に長いものは対象外（柱は別扱い）
            let cx = b.x + b.w / 2
            let centered = abs(cx - 0.5) < 0.12
            let outer = cx < 0.2 || cx > 0.8
            let conf = max(0.2, min(1, b.confidence))

            if let v = parseNumber(b.text) {
                var score = (bottom ? 1.0 : top ? 0.9 : 0.6) * conf
                if centered || outer { score += 0.15 }
                // 端に近いほど高く
                let edgeDistance = min(b.y, 1 - (b.y + b.h))
                score += max(0, 0.08 - edgeDistance)
                scored.append((v, score))
            } else if top || bottom, b.w < 0.75, let v = edgeNumber(b.text) {
                var score = 0.55 * conf
                if outer { score += 0.1 }
                scored.append((v, score))
            }
        }
        scored.sort { $0.1 > $1.1 }
        var seen = Set<Int>()
        var out: [Int] = []
        for (v, _) in scored where !seen.contains(v) {
            seen.insert(v)
            out.append(v)
        }
        return out
    }
}
