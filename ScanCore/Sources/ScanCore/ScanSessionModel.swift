import Foundation

/// 撮影結果の品質を判定する（撮り直しを勧めるかどうか）
public enum QualityJudge {
    /// - Parameters:
    ///   - textCharCount: 認識できた文字数
    ///   - meanConfidence: 認識の平均確信度（0〜1）
    ///   - lowConfidenceRatio: 確信度 0.4 未満だった行の割合
    ///   - handOverPage: 紙の内側に手・指が写っている
    ///   - cropFound: 紙の輪郭が見つかったか
    public static func flags(textCharCount: Int, meanConfidence: Double, lowConfidenceRatio: Double,
                             handOverPage: Bool, cropFound: Bool) -> Set<PageFlag> {
        var flags = Set<PageFlag>()
        if textCharCount >= 30 && (meanConfidence < 0.4 || lowConfidenceRatio > 0.5) {
            flags.insert(.blur)
        }
        if handOverPage { flags.insert(.hand) }
        if !cropFound { flags.insert(.noCrop) }
        return flags
    }
}

/// 1回の連続スキャンで撮ったページの並びと、差し込み・撮り直しの状態
public final class ScanSessionModel {
    public enum Outcome: Equatable {
        case inserted(id: UUID, at: Int)
        case replaced(old: UUID, new: UUID, at: Int)
        case skipped(duplicateOf: UUID)
    }

    public private(set) var records: [PageRecord] = []
    /// 「この後ろに差し込む」の挿入位置（nil なら自動）
    public private(set) var cursor: Int?
    /// 「撮り直す」の対象
    public private(set) var replaceTarget: UUID?
    /// 直前に撮った（または見せた）ページの番号
    public private(set) var lastNumber: Int?
    /// 追記先の本の直前のページ（重複確認用）
    public var context: [PageRecord]
    public var planner: ScanPlanner
    /// ページごとの自動撮り直し回数
    public private(set) var retakeCounts: [UUID: Int] = [:]

    public init(context: [PageRecord] = [], planner: ScanPlanner = ScanPlanner()) {
        self.context = context
        self.planner = planner
        self.lastNumber = context.last(where: \.hasReliableNumber)?.number
    }

    public var ids: [UUID] { records.map(\.id) }

    public func index(of id: UUID) -> Int? { records.firstIndex { $0.id == id } }

    public func record(_ id: UUID) -> PageRecord? { records.first { $0.id == id } }

    /// 撮れたページを適用する
    @discardableResult
    public func apply(_ c: PageCandidate, newID: UUID = UUID()) -> (Outcome, Plan) {
        let plan = planner.plan(c, records: records, context: context, lastNumber: lastNumber,
                                cursor: cursor, replaceTarget: replaceTarget)
        let newRecord = PageRecord(id: newID, number: plan.number, confidence: plan.confidence,
                                   text: c.textKey, hash: c.hash, flags: c.flags)
        switch plan.action {
        case .insert(let at):
            records.insert(newRecord, at: at)
            if let cur = cursor, at <= cur { cursor = cur + 1 }
            if newRecord.hasReliableNumber { lastNumber = newRecord.number }
            return (.inserted(id: newID, at: at), plan)

        case .replace(let old):
            guard let i = index(of: old) else {
                records.append(newRecord)
                return (.inserted(id: newID, at: records.count - 1), plan)
            }
            var replaced = newRecord
            // 番号が読めなかった撮り直しでも、元のページの番号は引き継ぐ
            if replaced.number == nil, let n = records[i].number {
                replaced.number = n
                replaced.confidence = records[i].confidence
            }
            records[i] = replaced
            retakeCounts[newID] = (retakeCounts[old] ?? 0) + 1
            retakeCounts[old] = nil
            if replaceTarget == old { replaceTarget = nil }
            if replaced.hasReliableNumber { lastNumber = replaced.number }
            return (.replaced(old: old, new: newID, at: i), plan)

        case .skipDuplicate(let dup):
            // 撮影済みのページを見せた＝そこまで戻った。次の番号判定の基準にする
            if let r = record(dup) ?? context.first(where: { $0.id == dup }), r.hasReliableNumber {
                lastNumber = r.number
            }
            return (.skipped(duplicateOf: dup), plan)
        }
    }

    /// 重複としてスキップしたページを、利用者の指示で追加する
    @discardableResult
    public func insertForced(_ c: PageCandidate, newID: UUID, after id: UUID?) -> Int {
        let at = id.flatMap { index(of: $0) }.map { $0 + 1 } ?? records.count
        let r = PageRecord(id: newID, number: nil, confidence: .none, text: c.textKey, hash: c.hash, flags: c.flags)
        records.insert(r, at: at)
        if let cur = cursor, at <= cur { cursor = cur + 1 }
        return at
    }

    /// このページの後ろに差し込む（nil で解除＝自動に戻す）
    public func setCursor(after id: UUID?) {
        guard let id, let i = index(of: id) else {
            cursor = nil
            return
        }
        cursor = i + 1
        if let n = records[i].number, records[i].hasReliableNumber { lastNumber = n }
    }

    /// 先頭に差し込む
    public func setCursorAtStart() { cursor = 0 }

    public func setReplaceTarget(_ id: UUID?) {
        guard let id else {
            replaceTarget = nil
            return
        }
        replaceTarget = index(of: id) == nil ? nil : id
    }

    public func remove(_ id: UUID) {
        guard let i = index(of: id) else { return }
        records.remove(at: i)
        if let cur = cursor, i < cur { cursor = cur - 1 }
        if replaceTarget == id { replaceTarget = nil }
        retakeCounts[id] = nil
    }

    /// 並びを外から変更したとき（ページ管理画面など）に同期する
    public func reorder(to ids: [UUID]) {
        let map = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let reordered = ids.compactMap { map[$0] }
        guard reordered.count == records.count else { return }
        records = reordered
    }

    /// 自動撮り直しをしてよいか（同じページで何度も繰り返さない）
    public func canAutoRetake(_ id: UUID, limit: Int = 2) -> Bool {
        (retakeCounts[id] ?? 0) < limit
    }

    public var missingNumbers: [Int] { ScanPlanner.missingNumbers(records) }

    /// 表示用のページ番号（推定なら estimated = true）
    public func displayNumber(_ id: UUID) -> (number: Int, estimated: Bool)? {
        if let r = record(id), r.hasReliableNumber, let n = r.number { return (n, false) }
        if let e = ScanPlanner.estimatedNumbers(records)[id] { return (e, true) }
        return nil
    }
}
