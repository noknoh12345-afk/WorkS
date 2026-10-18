import Foundation
import CoreGraphics

/// ページに適用する画像フィルター（元画像は常に保持し、非破壊で適用する）
enum PageFilter: String, Codable, CaseIterable, Identifiable {
    case original
    case enhanced
    case grayscale
    case blackWhite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "オリジナル"
        case .enhanced: return "補正カラー"
        case .grayscale: return "グレー"
        case .blackWhite: return "白黒"
        }
    }

    var symbol: String {
        switch self {
        case .original: return "photo"
        case .enhanced: return "wand.and.stars"
        case .grayscale: return "circle.lefthalf.filled"
        case .blackWhite: return "doc.plaintext"
        }
    }
}

/// 綴じ方向
enum BindingDirection: String, Codable, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left: return "左綴じ"
        case .right: return "右綴じ"
        }
    }

    var detail: String {
        switch self {
        case .left: return "横書きの本・書類（左から右へめくる）"
        case .right: return "縦書きの本・漫画（右から左へめくる）"
        }
    }
}

/// 文字認識の結果（座標は画像に対する正規化座標、原点は左上）
struct OCRLine: Codable, Hashable {
    var text: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

struct Page: Codable, Identifiable, Hashable {
    var id: UUID
    var fileName: String
    var filter: PageFilter
    /// 時計回りの90°回転数（0〜3）
    var rotation: Int
    var ocrLines: [OCRLine]?
    var ocrRotation: Int?
    var createdAt: Date
    /// 連続スキャンで撮った元写真（本のフォルダからの相対パス）
    var rawFileName: String?
    /// 元写真の中のページの四隅（左上, 右上, 右下, 左下 の x,y。正規化・左上原点）
    var quad: [Double]?
    /// 見開きを分けたページなら "left" / "right"
    var rawHalf: String?
    /// 撮影時に見つかった問題（"blur" / "hand" / "noCrop"）
    var flags: [String]?
    /// 紙に印刷されていたページ番号
    var printedNumber: Int?
    /// 画像を作り直すたびに増やす（キャッシュの区別用）
    var contentVersion: Int

    init(id: UUID = UUID(), fileName: String, filter: PageFilter, rotation: Int = 0) {
        self.id = id
        self.fileName = fileName
        self.filter = filter
        self.rotation = rotation
        self.ocrLines = nil
        self.ocrRotation = nil
        self.createdAt = Date()
        self.rawFileName = nil
        self.quad = nil
        self.rawHalf = nil
        self.flags = nil
        self.printedNumber = nil
        self.contentVersion = 0
    }

    enum CodingKeys: String, CodingKey {
        case id, fileName, filter, rotation, ocrLines, ocrRotation, createdAt
        case rawFileName, quad, rawHalf, flags, printedNumber, contentVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        filter = (try? c.decode(PageFilter.self, forKey: .filter)) ?? .original
        rotation = (try? c.decode(Int.self, forKey: .rotation)) ?? 0
        ocrLines = try? c.decode([OCRLine].self, forKey: .ocrLines)
        ocrRotation = try? c.decode(Int.self, forKey: .ocrRotation)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        rawFileName = try? c.decode(String.self, forKey: .rawFileName)
        quad = try? c.decode([Double].self, forKey: .quad)
        rawHalf = try? c.decode(String.self, forKey: .rawHalf)
        flags = try? c.decode([String].self, forKey: .flags)
        printedNumber = try? c.decode(Int.self, forKey: .printedNumber)
        contentVersion = (try? c.decode(Int.self, forKey: .contentVersion)) ?? 0
    }

    var normalizedRotation: Int { ((rotation % 4) + 4) % 4 }

    /// フィルター・回転・画像の版ごとのキャッシュキー
    var renderKey: String { "\(id.uuidString)-v\(contentVersion)-\(filter.rawValue)-r\(normalizedRotation)" }

    var hasIssues: Bool { !(flags ?? []).isEmpty }

    var issueLabels: [String] {
        (flags ?? []).compactMap {
            switch $0 {
            case "blur": return "ブレ"
            case "hand": return "手写り"
            case "noCrop": return "範囲未検出"
            default: return nil
            }
        }
    }

    var canAdjustCrop: Bool { rawFileName != nil }

    var needsOCR: Bool { ocrLines == nil || ocrRotation != normalizedRotation }

    var text: String {
        (ocrLines ?? []).map(\.text).joined(separator: "\n")
    }

    var hasValidOCR: Bool { ocrLines != nil && ocrRotation == normalizedRotation }
}

struct Book: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var author: String
    var shelf: String
    var binding: BindingDirection
    var pages: [Page]
    var coverPageID: UUID?
    var lastReadIndex: Int
    var bookmarks: [UUID]
    var lastOpenedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(title: String, binding: BindingDirection = .left) {
        self.id = UUID()
        self.title = title
        self.author = ""
        self.shelf = ""
        self.binding = binding
        self.pages = []
        self.coverPageID = nil
        self.lastReadIndex = 0
        self.bookmarks = []
        self.lastOpenedAt = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id, title, author, shelf, binding, pages, coverPageID, lastReadIndex, bookmarks, lastOpenedAt, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "無題"
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        shelf = (try? c.decode(String.self, forKey: .shelf)) ?? ""
        binding = (try? c.decode(BindingDirection.self, forKey: .binding)) ?? .left
        pages = (try? c.decode([Page].self, forKey: .pages)) ?? []
        coverPageID = try? c.decode(UUID.self, forKey: .coverPageID)
        lastReadIndex = (try? c.decode(Int.self, forKey: .lastReadIndex)) ?? 0
        bookmarks = (try? c.decode([UUID].self, forKey: .bookmarks)) ?? []
        lastOpenedAt = try? c.decode(Date.self, forKey: .lastOpenedAt)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }

    var coverPage: Page? {
        if let cid = coverPageID, let p = pages.first(where: { $0.id == cid }) { return p }
        return pages.first
    }

    var ocrDoneCount: Int { pages.filter { !$0.needsOCR }.count }

    /// 読書の進み具合（0〜1）
    var progress: Double {
        guard pages.count > 1 else { return lastReadIndex > 0 ? 1 : 0 }
        return Double(min(lastReadIndex, pages.count - 1)) / Double(pages.count - 1)
    }

    var isInProgress: Bool {
        lastOpenedAt != nil && pages.count > 1 && lastReadIndex > 0 && lastReadIndex < pages.count - 1
    }

    func isBookmarked(_ pageID: UUID) -> Bool { bookmarks.contains(pageID) }
}

/// 取り込み先の指定（nil の bookID は新しい本を作る）
struct ImportTarget: Identifiable, Equatable {
    let id = UUID()
    var bookID: UUID?
    var insertAt: Int?
    var replacing: UUID?
    /// メモアプリ方式（VisionKit）のスキャナーを使う
    var classic: Bool = false
}

/// 見開き表示の設定
enum SpreadMode: String, CaseIterable, Identifiable {
    case auto
    case single
    case double
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "横向きで見開き"
        case .single: return "常に1ページ"
        case .double: return "常に見開き"
        }
    }
}

struct ReadTarget: Identifiable {
    let id = UUID()
    let bookID: UUID
    let index: Int
    var highlight: String? = nil
}

struct PageRef: Identifiable {
    let bookID: UUID
    let pageID: UUID
    var id: UUID { pageID }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

enum ReaderMode: String, CaseIterable, Identifiable {
    case curl
    case slide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .curl: return "めくり"
        case .slide: return "スライド"
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case updated, created, title
    var id: String { rawValue }
    var label: String {
        switch self {
        case .updated: return "更新順"
        case .created: return "作成順"
        case .title: return "タイトル順"
        }
    }
}

enum AppSettings {
    static let defaultFilterKey = "defaultFilter"
    static let jpegQualityKey = "jpegQuality"
    static let defaultBindingKey = "defaultBinding"
    static let autoOCRKey = "autoOCR"
    static let autoCropKey = "autoCropPhotos"
    static let readerModeKey = "readerMode"
    static let librarySortKey = "librarySort"
    static let spreadModeKey = "spreadMode"
    static let coverAloneKey = "coverAlone"
    static let liveTextKey = "liveText"

    static var defaultFilter: PageFilter {
        PageFilter(rawValue: UserDefaults.standard.string(forKey: defaultFilterKey) ?? "") ?? .enhanced
    }

    static var jpegQuality: Double {
        let v = UserDefaults.standard.double(forKey: jpegQualityKey)
        return v <= 0 ? 0.92 : v
    }

    static var defaultBinding: BindingDirection {
        BindingDirection(rawValue: UserDefaults.standard.string(forKey: defaultBindingKey) ?? "") ?? .left
    }

    static var autoOCR: Bool {
        UserDefaults.standard.object(forKey: autoOCRKey) as? Bool ?? true
    }

    static var autoCropPhotos: Bool {
        UserDefaults.standard.object(forKey: autoCropKey) as? Bool ?? true
    }

    static var liveText: Bool {
        UserDefaults.standard.object(forKey: liveTextKey) as? Bool ?? true
    }
}
