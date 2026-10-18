import Foundation
import SwiftUI
import UIKit
import Observation
import VisionKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class LibraryStore {
    struct ImportProgress: Equatable {
        var done: Int
        var total: Int
    }

    private struct LibraryFile: Codable {
        var version: Int
        var books: [Book]
    }

    private(set) var books: [Book] = []
    private(set) var ocrRunning: Set<UUID> = []
    var importProgress: ImportProgress?
    var pendingInfoEdit: UUID?

    @ObservationIgnored private var saveWork: Task<Void, Never>?
    @ObservationIgnored private var ocrTasks: [UUID: Task<Void, Never>] = [:]
    /// 連続スキャン中は端末の処理を撮影に回すため、その本の文字認識を止める
    @ObservationIgnored private var ocrSuspended: Set<UUID> = []

    init() {
        Paths.ensure(Paths.booksDir)
        load()
        for b in books where b.pages.contains(where: { $0.needsOCR }) {
            scheduleOCR(for: b.id)
        }
    }

    // MARK: - 永続化

    private func load() {
        guard let data = try? Data(contentsOf: Paths.libraryFile) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let lib = try? dec.decode(LibraryFile.self, from: data) {
            books = lib.books
        }
    }

    func scheduleSave() {
        saveWork?.cancel()
        saveWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(LibraryFile(version: 1, books: books)) else { return }
        try? data.write(to: Paths.libraryFile, options: .atomic)
    }

    // MARK: - 参照

    func book(_ id: UUID) -> Book? { books.first { $0.id == id } }

    private func index(of id: UUID) -> Int? { books.firstIndex { $0.id == id } }

    private func mutate(_ id: UUID, touch: Bool = true, _ body: (inout Book) -> Void) {
        guard let i = index(of: id) else { return }
        body(&books[i])
        if touch { books[i].updatedAt = Date() }
        scheduleSave()
    }

    var shelves: [String] {
        Array(Set(books.map(\.shelf).filter { !$0.isEmpty })).sorted()
    }

    func newBookTitle() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 H:mm"
        return "スキャン \(f.string(from: Date()))"
    }

    // MARK: - 取り込み

    func importScan(_ scan: VNDocumentCameraScan, target: ImportTarget) async -> UUID? {
        let id = await importImages(count: scan.pageCount, into: target.bookID, at: target.insertAt, autoCrop: false) { i in
            scan.imageOfPage(at: i)
        }
        if let id, let replacing = target.replacing {
            deletePages(bookID: id, ids: [replacing])
        }
        return id
    }

    /// 画像を1枚ずつ保存しながら取り込む（大量ページでもメモリを圧迫しない）
    func importImages(count: Int,
                      into bookID: UUID?,
                      at index: Int?,
                      autoCrop: Bool,
                      title: String? = nil,
                      filter: PageFilter? = nil,
                      provider: (Int) async -> UIImage?) async -> UUID? {
        guard count > 0 else { return bookID }
        let targetID: UUID
        var created = false
        if let bookID, book(bookID) != nil {
            targetID = bookID
        } else {
            let b = Book(title: title ?? newBookTitle(), binding: AppSettings.defaultBinding)
            books.insert(b, at: 0)
            targetID = b.id
            created = true
        }

        importProgress = ImportProgress(done: 0, total: count)
        var insertAt = index
        var added = 0
        for i in 0..<count {
            if let image = await provider(i),
               let page = await Self.persist(image, bookID: targetID, autoCrop: autoCrop, filter: filter) {
                mutate(targetID) { b in
                    let at = min(max(insertAt ?? b.pages.count, 0), b.pages.count)
                    b.pages.insert(page, at: at)
                }
                if let current = insertAt { insertAt = current + 1 }
                added += 1
            }
            importProgress?.done = i + 1
        }
        importProgress = nil

        if created && added == 0 {
            deleteBook(targetID)
            return nil
        }
        scheduleSave()
        scheduleOCR(for: targetID)
        return targetID
    }

    nonisolated static func persist(_ image: UIImage, bookID: UUID, autoCrop: Bool, filter: PageFilter? = nil) async -> Page? {
        let filter = filter ?? AppSettings.defaultFilter
        let quality = AppSettings.jpegQuality
        return await Task.detached(priority: .userInitiated) { () -> Page? in
            guard var cg = image.normalizedCGImage() else { return nil }
            if autoCrop, let cropped = DocumentDetector.autoCrop(cg) { cg = cropped }
            let page = Page(fileName: UUID().uuidString + ".jpg", filter: filter)
            let url = Paths.pageFile(bookID: bookID, fileName: page.fileName)
            return ImageIOHelper.writeJPEG(cg, to: url, quality: quality) ? page : nil
        }.value
    }

    /// 「ファイル」から PDF・画像を取り込む（PDF は1ページずつ画像化）
    func importFiles(_ urls: [URL], target: ImportTarget) async -> UUID? {
        enum Item { case pdf(PDFPage), image(URL) }
        var items: [Item] = []
        var documents: [PDFDocument] = []
        var accessed: [URL] = []
        for url in urls {
            if url.startAccessingSecurityScopedResource() { accessed.append(url) }
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            if type?.conforms(to: .pdf) == true, let doc = PDFDocument(url: url) {
                documents.append(doc)
                for i in 0..<doc.pageCount {
                    if let p = doc.page(at: i) { items.append(.pdf(p)) }
                }
            } else {
                items.append(.image(url))
            }
        }
        defer { for u in accessed { u.stopAccessingSecurityScopedResource() } }

        let allPDF = !items.isEmpty && items.allSatisfy { if case .pdf = $0 { return true } else { return false } }
        let title: String? = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : nil
        let captured = items
        let id = await importImages(count: captured.count,
                                    into: target.bookID,
                                    at: target.insertAt,
                                    autoCrop: allPDF ? false : AppSettings.autoCropPhotos,
                                    title: title,
                                    filter: allPDF ? .original : nil) { i in
            switch captured[i] {
            case .pdf(let page):
                return PDFPageRenderer.render(page)
            case .image(let url):
                guard let data = try? Data(contentsOf: url) else { return nil }
                return UIImage(data: data)
            }
        }
        _ = documents
        return id
    }

    // MARK: - 本の編集

    func updateInfo(_ id: UUID, title: String, author: String, shelf: String, binding: BindingDirection) {
        mutate(id) { b in
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            b.title = t.isEmpty ? "無題" : t
            b.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
            b.shelf = shelf.trimmingCharacters(in: .whitespacesAndNewlines)
            b.binding = binding
        }
    }

    func setBinding(_ id: UUID, _ binding: BindingDirection) {
        mutate(id) { $0.binding = binding }
    }

    func setCover(_ id: UUID, pageID: UUID) {
        mutate(id) { $0.coverPageID = pageID }
    }

    func setLastRead(_ id: UUID, _ index: Int) {
        mutate(id, touch: false) { $0.lastReadIndex = index }
    }

    func markOpened(_ id: UUID) {
        mutate(id, touch: false) { $0.lastOpenedAt = Date() }
    }

    func toggleBookmark(_ id: UUID, pageID: UUID) {
        mutate(id, touch: false) { b in
            if let i = b.bookmarks.firstIndex(of: pageID) {
                b.bookmarks.remove(at: i)
            } else {
                b.bookmarks.append(pageID)
            }
        }
    }

    func deleteBook(_ id: UUID) {
        guard let b = book(id) else { return }
        ocrTasks[id]?.cancel()
        for p in b.pages { Paths.purgeCaches(pageID: p.id) }
        try? FileManager.default.removeItem(at: Paths.bookDir(id))
        books.removeAll { $0.id == id }
        scheduleSave()
    }

    /// source の全ページを target の末尾に移し、source を削除
    func merge(_ sourceID: UUID, into targetID: UUID) {
        guard sourceID != targetID, let src = book(sourceID), book(targetID) != nil else { return }
        Paths.ensure(Paths.bookDir(targetID))
        var moved: [Page] = []
        var movedRaw = Set<String>()
        for p in src.pages {
            let from = Paths.pageFile(bookID: sourceID, fileName: p.fileName)
            let to = Paths.pageFile(bookID: targetID, fileName: p.fileName)
            var page = p
            do {
                try FileManager.default.moveItem(at: from, to: to)
            } catch {
                guard (try? FileManager.default.copyItem(at: from, to: to)) != nil else { continue }
            }
            if let raw = p.rawFileName, !movedRaw.contains(raw) {
                let rFrom = Paths.pageFile(bookID: sourceID, fileName: raw)
                let rTo = Paths.pageFile(bookID: targetID, fileName: raw)
                Paths.ensure(rTo.deletingLastPathComponent())
                if (try? FileManager.default.moveItem(at: rFrom, to: rTo)) != nil {
                    movedRaw.insert(raw)
                } else if !FileManager.default.fileExists(atPath: rTo.path) {
                    page.rawFileName = nil
                    page.quad = nil
                    page.rawHalf = nil
                }
            }
            moved.append(page)
        }
        mutate(targetID) { $0.pages.append(contentsOf: moved) }
        try? FileManager.default.removeItem(at: Paths.bookDir(sourceID))
        ocrTasks[sourceID]?.cancel()
        books.removeAll { $0.id == sourceID }
        scheduleSave()
        scheduleOCR(for: targetID)
    }

    // MARK: - ページの編集

    /// ページのファイルを消す。元写真はほかのページ（見開きの片側など）が使っていなければ消す
    private func removeFiles(of page: Page, bookID: UUID, remaining: [Page]) {
        try? FileManager.default.removeItem(at: Paths.pageFile(bookID: bookID, fileName: page.fileName))
        if let raw = page.rawFileName, !remaining.contains(where: { $0.rawFileName == raw }) {
            try? FileManager.default.removeItem(at: Paths.pageFile(bookID: bookID, fileName: raw))
        }
        Paths.purgeCaches(pageID: page.id)
    }

    func deletePages(bookID: UUID, ids: Set<UUID>) {
        guard let b = book(bookID) else { return }
        let remaining = b.pages.filter { !ids.contains($0.id) }
        for p in b.pages where ids.contains(p.id) {
            removeFiles(of: p, bookID: bookID, remaining: remaining)
        }
        mutate(bookID) { book in
            book.pages.removeAll { ids.contains($0.id) }
            if let c = book.coverPageID, ids.contains(c) { book.coverPageID = nil }
            book.bookmarks.removeAll { ids.contains($0) }
            book.lastReadIndex = min(book.lastReadIndex, max(book.pages.count - 1, 0))
        }
    }

    func movePages(bookID: UUID, from: IndexSet, to: Int) {
        mutate(bookID) { $0.pages.move(fromOffsets: from, toOffset: to) }
    }

    func reversePages(bookID: UUID) {
        mutate(bookID) { $0.pages.reverse() }
    }

    func updatePage(bookID: UUID, pageID: UUID, _ body: (inout Page) -> Void) {
        mutate(bookID) { b in
            guard let i = b.pages.firstIndex(where: { $0.id == pageID }) else { return }
            body(&b.pages[i])
            b.pages[i].rotation = b.pages[i].normalizedRotation
        }
        scheduleOCR(for: bookID)
    }

    func rotate(bookID: UUID, pageID: UUID, by quarter: Int) {
        updatePage(bookID: bookID, pageID: pageID) { $0.rotation += quarter }
    }

    /// 見開きで撮ったページを左右2ページに分割（綴じ方向に合わせて並べる）
    @discardableResult
    func splitPage(bookID: UUID, pageID: UUID) async -> Bool {
        guard let b = book(bookID), let page = b.pages.first(where: { $0.id == pageID }) else { return false }
        let src = Paths.pageFile(bookID: bookID, fileName: page.fileName)
        let rotation = page.normalizedRotation
        let filter = page.filter
        let quality = AppSettings.jpegQuality
        let rtl = b.binding == .right
        // 回転していない1ページなら、分けたあとも元写真から範囲を調整できるようにする
        let keepRaw = rotation == 0 && page.rawHalf == nil ? page.rawFileName : nil
        let quad = page.quad
        let made = await Task.detached(priority: .userInitiated) { () -> [Page]? in
            guard let cg = ImageProcessor.render(url: src, filter: .original, rotation: rotation, maxPixel: nil),
                  let halves = SpreadSplitter.split(cg) else { return nil }
            var out: [Page] = []
            for (half, side) in [(halves.0, "left"), (halves.1, "right")] {
                var p = Page(fileName: UUID().uuidString + ".jpg", filter: filter)
                if let keepRaw {
                    p.rawFileName = keepRaw
                    p.quad = quad
                    p.rawHalf = side
                }
                guard ImageIOHelper.writeJPEG(half, to: Paths.pageFile(bookID: bookID, fileName: p.fileName), quality: quality) else { return nil }
                out.append(p)
            }
            return rtl ? Array(out.reversed()) : out
        }.value
        guard let made, made.count == 2 else { return false }
        var replaced = false
        mutate(bookID) { book in
            guard let i = book.pages.firstIndex(where: { $0.id == pageID }) else { return }
            book.pages.replaceSubrange(i...i, with: made)
            if book.coverPageID == pageID { book.coverPageID = made[0].id }
            if let bi = book.bookmarks.firstIndex(of: pageID) { book.bookmarks[bi] = made[0].id }
            replaced = true
        }
        if replaced {
            removeFiles(of: page, bookID: bookID, remaining: book(bookID)?.pages ?? [])
            scheduleOCR(for: bookID)
        } else {
            for p in made { try? FileManager.default.removeItem(at: Paths.pageFile(bookID: bookID, fileName: p.fileName)) }
        }
        return replaced
    }

    /// 横長のページだけをまとめて分割。分割したページ数を返す
    func splitAllLandscapePages(bookID: UUID, progress: (Int, Int) -> Void) async -> Int {
        guard let b = book(bookID) else { return 0 }
        let targets = b.pages.filter { p in
            guard let size = ImageIOHelper.displaySize(bookID: bookID, page: p) else { return false }
            return size.width > size.height * 1.15
        }.map(\.id)
        var count = 0
        for (i, id) in targets.enumerated() {
            progress(i, targets.count)
            if await splitPage(bookID: bookID, pageID: id) { count += 1 }
        }
        return count
    }

    func applyFilterToAll(bookID: UUID, filter: PageFilter) {
        mutate(bookID) { b in
            for i in b.pages.indices { b.pages[i].filter = filter }
        }
    }

    // MARK: - 連続スキャン

    func createEmptyBook() -> UUID {
        let b = Book(title: newBookTitle(), binding: AppSettings.defaultBinding)
        books.insert(b, at: 0)
        scheduleSave()
        return b.id
    }

    func suspendOCR(_ bookID: UUID) {
        ocrSuspended.insert(bookID)
        ocrTasks[bookID]?.cancel()
    }

    func resumeOCR(_ bookID: UUID) {
        ocrSuspended.remove(bookID)
        scheduleOCR(for: bookID)
    }

    /// 撮ったページを本の指定位置に入れる
    func insertScannedPage(_ page: Page, into bookID: UUID, at index: Int) {
        mutate(bookID) { b in
            b.pages.insert(page, at: min(max(index, 0), b.pages.count))
        }
    }

    /// 撮り直したページで置き換える（位置・しおり・表紙を引き継ぐ）
    func replaceScannedPage(bookID: UUID, oldID: UUID, with page: Page) {
        guard let b = book(bookID), let old = b.pages.first(where: { $0.id == oldID }) else {
            insertScannedPage(page, into: bookID, at: Int.max)
            return
        }
        var replacement = page
        replacement.filter = old.filter == page.filter ? page.filter : old.filter
        mutate(bookID) { book in
            guard let i = book.pages.firstIndex(where: { $0.id == oldID }) else { return }
            book.pages[i] = replacement
            if book.coverPageID == oldID { book.coverPageID = replacement.id }
            if let bi = book.bookmarks.firstIndex(of: oldID) { book.bookmarks[bi] = replacement.id }
        }
        removeFiles(of: old, bookID: bookID, remaining: book(bookID)?.pages ?? [])
    }

    /// 本に入れなかった撮影結果のファイルを消す
    func discardFiles(of page: Page, bookID: UUID) {
        removeFiles(of: page, bookID: bookID, remaining: book(bookID)?.pages ?? [])
    }

    func setPrintedNumber(bookID: UUID, pageID: UUID, _ number: Int?) {
        mutate(bookID, touch: false) { b in
            guard let i = b.pages.firstIndex(where: { $0.id == pageID }) else { return }
            b.pages[i].printedNumber = number
        }
    }

    func clearFlags(bookID: UUID, pageID: UUID) {
        mutate(bookID, touch: false) { b in
            guard let i = b.pages.firstIndex(where: { $0.id == pageID }) else { return }
            b.pages[i].flags = nil
        }
    }

    /// 範囲を調整して作り直した画像に差し替える
    func updatePageImage(bookID: UUID, pageID: UUID, newFileName: String, quad: [Double]) {
        guard let b = book(bookID), let old = b.pages.first(where: { $0.id == pageID }) else { return }
        mutate(bookID) { book in
            guard let i = book.pages.firstIndex(where: { $0.id == pageID }) else { return }
            book.pages[i].fileName = newFileName
            book.pages[i].quad = quad
            book.pages[i].contentVersion += 1
            book.pages[i].ocrLines = nil
            book.pages[i].ocrRotation = nil
            book.pages[i].flags = (book.pages[i].flags ?? []).filter { $0 != "noCrop" }
        }
        try? FileManager.default.removeItem(at: Paths.pageFile(bookID: bookID, fileName: old.fileName))
        Paths.purgeCaches(pageID: pageID)
        scheduleOCR(for: bookID, force: true)
    }

    // MARK: - 文字認識

    func redoOCR(bookID: UUID, pageID: UUID? = nil) {
        mutate(bookID, touch: false) { b in
            for i in b.pages.indices where pageID == nil || b.pages[i].id == pageID {
                b.pages[i].ocrLines = nil
                b.pages[i].ocrRotation = nil
            }
        }
        scheduleOCR(for: bookID, force: true)
    }

    func scheduleOCR(for bookID: UUID, force: Bool = false) {
        guard force || AppSettings.autoOCR else { return }
        guard !ocrSuspended.contains(bookID) else { return }
        guard ocrTasks[bookID] == nil else { return }
        ocrRunning.insert(bookID)
        ocrTasks[bookID] = Task { [weak self] in
            await self?.runOCRLoop(bookID)
            self?.ocrTasks[bookID] = nil
            self?.ocrRunning.remove(bookID)
        }
    }

    private func runOCRLoop(_ bookID: UUID) async {
        while !Task.isCancelled,
              !ocrSuspended.contains(bookID),
              let b = book(bookID),
              let page = b.pages.first(where: { $0.needsOCR }) {
            let url = Paths.pageFile(bookID: bookID, fileName: page.fileName)
            let rotation = page.normalizedRotation
            let lines = await Task.detached(priority: .utility) {
                OCRService.recognize(url: url, rotation: rotation)
            }.value
            guard let bi = index(of: bookID),
                  let pi = books[bi].pages.firstIndex(where: { $0.id == page.id }) else { continue }
            if books[bi].pages[pi].normalizedRotation == rotation {
                books[bi].pages[pi].ocrLines = lines
                books[bi].pages[pi].ocrRotation = rotation
                scheduleSave()
            }
        }
    }
}
