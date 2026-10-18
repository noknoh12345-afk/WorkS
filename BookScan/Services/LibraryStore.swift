import Foundation
import SwiftUI
import UIKit
import Observation
import VisionKit

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
                      provider: (Int) async -> UIImage?) async -> UUID? {
        guard count > 0 else { return bookID }
        let targetID: UUID
        var created = false
        if let bookID, book(bookID) != nil {
            targetID = bookID
        } else {
            let b = Book(title: newBookTitle(), binding: AppSettings.defaultBinding)
            books.insert(b, at: 0)
            targetID = b.id
            created = true
        }

        importProgress = ImportProgress(done: 0, total: count)
        var insertAt = index
        var added = 0
        for i in 0..<count {
            if let image = await provider(i),
               let page = await Self.persist(image, bookID: targetID, autoCrop: autoCrop) {
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

    nonisolated static func persist(_ image: UIImage, bookID: UUID, autoCrop: Bool) async -> Page? {
        let filter = AppSettings.defaultFilter
        let quality = AppSettings.jpegQuality
        return await Task.detached(priority: .userInitiated) { () -> Page? in
            guard var cg = image.normalizedCGImage() else { return nil }
            if autoCrop, let cropped = DocumentDetector.autoCrop(cg) { cg = cropped }
            let page = Page(fileName: UUID().uuidString + ".jpg", filter: filter)
            let url = Paths.pageFile(bookID: bookID, fileName: page.fileName)
            return ImageIOHelper.writeJPEG(cg, to: url, quality: quality) ? page : nil
        }.value
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
        for p in src.pages {
            let from = Paths.pageFile(bookID: sourceID, fileName: p.fileName)
            let to = Paths.pageFile(bookID: targetID, fileName: p.fileName)
            do {
                try FileManager.default.moveItem(at: from, to: to)
                moved.append(p)
            } catch {
                if (try? FileManager.default.copyItem(at: from, to: to)) != nil { moved.append(p) }
            }
        }
        mutate(targetID) { $0.pages.append(contentsOf: moved) }
        try? FileManager.default.removeItem(at: Paths.bookDir(sourceID))
        ocrTasks[sourceID]?.cancel()
        books.removeAll { $0.id == sourceID }
        scheduleSave()
        scheduleOCR(for: targetID)
    }

    // MARK: - ページの編集

    func deletePages(bookID: UUID, ids: Set<UUID>) {
        guard let b = book(bookID) else { return }
        for p in b.pages where ids.contains(p.id) {
            try? FileManager.default.removeItem(at: Paths.pageFile(bookID: bookID, fileName: p.fileName))
            Paths.purgeCaches(pageID: p.id)
        }
        mutate(bookID) { book in
            book.pages.removeAll { ids.contains($0.id) }
            if let c = book.coverPageID, ids.contains(c) { book.coverPageID = nil }
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

    func applyFilterToAll(bookID: UUID, filter: PageFilter) {
        mutate(bookID) { b in
            for i in b.pages.indices { b.pages[i].filter = filter }
        }
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
