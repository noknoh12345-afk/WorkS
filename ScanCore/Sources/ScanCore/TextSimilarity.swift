import Foundation

/// 文字認識結果どうしの一致度（日本語は単語区切りがないので文字3-gramで比較）
public enum TextSimilarity {
    /// 全角英数→半角、小文字化、空白・記号の除去
    public static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            var v = u.value
            if v == 0x3000 { continue } // 全角スペース
            if v >= 0xFF01 && v <= 0xFF5E { v -= 0xFEE0 } // 全角 ASCII
            guard let scalar = Unicode.Scalar(v) else { continue }
            if scalar.properties.isWhitespace { continue }
            if isIgnorable(scalar) { continue }
            let lowered = scalar.properties.lowercaseMapping
            out.append(contentsOf: lowered.unicodeScalars)
        }
        return String(out)
    }

    private static func isIgnorable(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation, .mathSymbol,
             .currencySymbol, .modifierSymbol, .otherSymbol, .control, .format:
            return true
        default:
            return false
        }
    }

    public static func trigrams(_ normalized: String) -> Set<String> {
        let chars = Array(normalized)
        guard chars.count >= 3 else { return chars.isEmpty ? [] : [String(chars)] }
        var set = Set<String>()
        set.reserveCapacity(chars.count)
        for i in 0..<(chars.count - 2) {
            set.insert(String(chars[i..<(i + 3)]))
        }
        return set
    }

    /// 0〜1。撮り直した同じページ（認識ゆれ・一部隠れ）は高く、別ページは低くなる
    public static func score(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let union = a.count + b.count - inter
        let jaccard = union > 0 ? Double(inter) / Double(union) : 0
        let minCount = min(a.count, b.count)
        let containment = minCount >= 60 ? Double(inter) / Double(minCount) * 0.9 : 0
        return max(jaccard, containment)
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        score(trigrams(normalize(a)), trigrams(normalize(b)))
    }
}
