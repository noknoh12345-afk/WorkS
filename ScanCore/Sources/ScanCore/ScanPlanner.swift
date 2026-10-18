import Foundation

public enum PageFlag: String, Codable, CaseIterable, Hashable {
    case blur
    case hand
    case noCrop

    /// 撮り直しで直せる問題か
    public var isRetakeable: Bool { self == .blur || self == .hand }
}

public enum NumberConfidence: Int, Codable, Comparable {
    case none = 0, low, medium, high
    public static func < (a: NumberConfidence, b: NumberConfidence) -> Bool { a.rawValue < b.rawValue }
}

/// 既にスキャン済みのページ
public struct PageRecord: Equatable {
    public var id: UUID
    public var number: Int?
    public var confidence: NumberConfidence
    public var textKey: String
    public var trigrams: Set<String>
    public var hash: ImageHash?
    public var flags: Set<PageFlag>

    public init(id: UUID, number: Int?, confidence: NumberConfidence, text: String,
                hash: ImageHash?, flags: Set<PageFlag> = []) {
        self.id = id
        self.number = number
        self.confidence = number == nil ? .none : confidence
        self.textKey = TextSimilarity.normalize(text)
        self.trigrams = TextSimilarity.trigrams(textKey)
        self.hash = hash
        self.flags = flags
    }

    public var hasReliableNumber: Bool { number != nil && confidence >= .medium }
}

/// 新しく撮れたページ
public struct PageCandidate: Equatable {
    public var numbers: [Int]
    public var textKey: String
    public var trigrams: Set<String>
    public var hash: ImageHash?
    public var flags: Set<PageFlag>

    public init(numbers: [Int], text: String, hash: ImageHash?, flags: Set<PageFlag> = []) {
        self.numbers = numbers
        self.textKey = TextSimilarity.normalize(text)
        self.trigrams = TextSimilarity.trigrams(textKey)
        self.hash = hash
        self.flags = flags
    }
}

public enum PlanAction: Equatable {
    case insert(at: Int)
    case replace(UUID)
    case skipDuplicate(of: UUID)
}

public struct Plan: Equatable {
    public var action: PlanAction
    public var number: Int?
    public var confidence: NumberConfidence
}

public enum Verdict: Equatable { case same, different }

/// 撮れたページを「どこに入れるか／重複か／差し替えか」決める
public struct ScanPlanner {
    public var duplicateTextThreshold = 0.5
    public var distinctTextThreshold = 0.15
    public var numberOverrideTextThreshold = 0.85
    /// 同じページ撮り直しの99%が0.32未満、別ページは最小0.37（テストで計測）。
    /// 別ページを消してしまう方が害が大きいので、低めにして「迷ったら残す」
    public var hashThreshold = 0.30
    public var minTextForCompare = 40

    public init() {}

    // MARK: ページ番号の確からしさ

    public func resolveNumber(_ c: PageCandidate, records: [PageRecord], lastNumber: Int?) -> (Int?, NumberConfidence) {
        guard let first = c.numbers.first else { return (nil, .none) }
        let known = records.filter(\.hasReliableNumber).compactMap(\.number)
        guard let lo = known.min(), let hi = known.max() else {
            if let last = lastNumber, let n = c.numbers.first(where: { $0 > last && $0 <= last + 3 }) {
                return (n, .high)
            }
            return (first, .medium)
        }
        let present = Set(known)
        for n in c.numbers {
            if present.contains(n) { return (n, .high) }
            if n > lo && n < hi { return (n, .high) }
            if let last = lastNumber, n > last && n <= last + 3 { return (n, .high) }
            if n > hi && n <= hi + 3 { return (n, .high) }
            if n < lo && n >= lo - 3 { return (n, .high) }
        }
        return (first, .low)
    }

    // MARK: 同じページか

    public func verdict(_ c: PageCandidate, number: Int?, confidence: NumberConfidence, _ r: PageRecord) -> Verdict {
        let longText = c.textKey.count >= minTextForCompare && r.textKey.count >= minTextForCompare
        let textScore: Double? = longText ? TextSimilarity.score(c.trigrams, r.trigrams) : nil

        if let n = number, confidence >= .medium, r.hasReliableNumber, let rn = r.number {
            if n != rn {
                // 番号の読み違いで本文がほぼ同じ → 同じページ
                return (textScore ?? 0) >= numberOverrideTextThreshold ? .same : .different
            }
            // 番号は同じでも本文がまるで違う → 番号の読み違い
            if let t = textScore, t < distinctTextThreshold { return .different }
            return .same
        }
        if let t = textScore { return t >= duplicateTextThreshold ? .same : .different }

        // 文字が少ないページ（図・写真・漫画など）は画像で比較
        // 白紙どうしなど比べる模様がないときは「別ページ」として残す（消すより安全）
        if c.textKey.count < minTextForCompare && r.textKey.count < minTextForCompare,
           let h1 = c.hash, let h2 = r.hash, let d = h1.dissimilarity(to: h2) {
            return d <= hashThreshold ? .same : .different
        }
        return .different
    }

    // MARK: 決定

    /// - Parameters:
    ///   - records: このスキャンで撮ったページ（本の中の並び順）
    ///   - context: 追記先の本の直前のページなど、重複だけ確認したいページ
    ///   - lastNumber: 直前に撮ったページの番号
    ///   - cursor: 「この後ろに差し込む」指定（records 内の挿入位置）
    ///   - replaceTarget: 「撮り直す」指定
    public func plan(_ c: PageCandidate, records: [PageRecord], context: [PageRecord] = [],
                     lastNumber: Int? = nil, cursor: Int? = nil, replaceTarget: UUID? = nil) -> Plan {
        var (number, conf) = resolveNumber(c, records: records, lastNumber: lastNumber)

        if let target = replaceTarget, let r = records.first(where: { $0.id == target }) {
            // 撮り直しのつもりで別のページを写した（番号が確実に違い、本文も別物）なら差し替えない
            let clearlyOther = conf >= .medium && r.hasReliableNumber && number != nil && number != r.number
                && verdict(c, number: number, confidence: conf, r) == .different
            if !clearlyOther {
                return Plan(action: .replace(target), number: number, confidence: conf)
            }
        }

        for r in records where verdict(c, number: number, confidence: conf, r) == .same {
            let retakeableOld = r.flags.filter(\.isRetakeable)
            let retakeableNew = c.flags.filter(\.isRetakeable)
            if !retakeableOld.isEmpty && retakeableNew.isEmpty {
                return Plan(action: .replace(r.id), number: number ?? r.number, confidence: max(conf, r.confidence))
            }
            if !retakeableOld.isEmpty && retakeableNew.isStrictSubset(of: retakeableOld) {
                return Plan(action: .replace(r.id), number: number ?? r.number, confidence: max(conf, r.confidence))
            }
            return Plan(action: .skipDuplicate(of: r.id), number: number, confidence: conf)
        }
        for r in context where verdict(c, number: number, confidence: conf, r) == .same {
            return Plan(action: .skipDuplicate(of: r.id), number: number, confidence: conf)
        }

        // 既にある番号と同じなのに本文が別物 → 番号の読み違い。位置決めに使わない
        if let n = number, conf >= .medium,
           records.contains(where: { $0.hasReliableNumber && $0.number == n }) {
            conf = .low
        }

        if let cursor {
            return Plan(action: .insert(at: min(max(cursor, 0), records.count)), number: number, confidence: conf)
        }
        if conf == .high, let n = number, records.contains(where: \.hasReliableNumber) {
            if let i = records.firstIndex(where: { $0.hasReliableNumber && ($0.number ?? Int.min) > n }) {
                // 直前の番号付きページより後ろ、かつ次の番号付きページより前
                return Plan(action: .insert(at: i), number: number, confidence: conf)
            }
        }
        return Plan(action: .insert(at: records.count), number: number, confidence: conf)
    }

    // MARK: 抜けページ

    /// 番号のないページは前後の番号から推定して埋め、それでも足りない番号を返す
    public static func missingNumbers(_ records: [PageRecord], maxGap: Int = 20) -> [Int] {
        estimate(records, maxGap: maxGap).missing
    }

    /// 番号のないページの推定番号
    public static func estimatedNumbers(_ records: [PageRecord], maxGap: Int = 20) -> [UUID: Int] {
        estimate(records, maxGap: maxGap).estimated
    }

    static func estimate(_ records: [PageRecord], maxGap: Int) -> (missing: [Int], estimated: [UUID: Int]) {
        let numbered = records.enumerated().filter { $0.element.hasReliableNumber }
        var missing: [Int] = []
        var estimated: [UUID: Int] = [:]
        guard numbered.count >= 1 else { return ([], [:]) }

        for (a, b) in zip(numbered, numbered.dropFirst()) {
            guard let na = a.element.number, let nb = b.element.number else { continue }
            let between = Array(records[(a.offset + 1)..<b.offset])
            guard nb > na, nb - na <= maxGap else { continue }
            var next = na + 1
            for r in between where next < nb {
                estimated[r.id] = next
                next += 1
            }
            if next < nb { missing.append(contentsOf: next..<nb) }
        }
        // 最後の番号付きページより後ろの番号なしページ
        if let last = numbered.last, let n = last.element.number {
            var next = n + 1
            for r in records[(last.offset + 1)...] where !r.hasReliableNumber {
                estimated[r.id] = next
                next += 1
            }
        }
        // 最初の番号付きページより前（さかのぼって推定）
        if let first = numbered.first, let n = first.element.number, first.offset > 0 {
            var prev = n - 1
            for r in records[..<first.offset].reversed() where !r.hasReliableNumber {
                if prev < 1 { break }
                estimated[r.id] = prev
                prev -= 1
            }
        }
        return (Array(Set(missing)).sorted(), estimated)
    }
}
