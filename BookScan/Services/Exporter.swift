import Foundation
import UIKit
import CoreText
import ImageIO

enum ExportError: LocalizedError {
    case noPages
    case failed

    var errorDescription: String? {
        switch self {
        case .noPages: return "書き出せるページがありません"
        case .failed: return "書き出しに失敗しました"
        }
    }
}

enum Exporter {
    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Book" : cleaned
    }

    static func freshDir() -> URL {
        let d = Paths.exportDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        Paths.ensure(d)
        return d
    }

    static func renderedFiles(book: Book) async -> [(Page, URL)] {
        var out: [(Page, URL)] = []
        for p in book.pages {
            if let u = await PageRenderCenter.shared.renderedFile(bookID: book.id, page: p) {
                out.append((p, u))
            }
        }
        return out
    }

    /// 文字検索できるPDF（OCRテキストを透明レイヤーで埋め込み）
    static func pdf(book: Book) async throws -> URL {
        let files = await renderedFiles(book: book)
        guard !files.isEmpty else { throw ExportError.noPages }
        let dest = freshDir().appendingPathComponent(safeName(book.title) + ".pdf")
        let title = book.title
        let author = book.author
        try await Task.detached(priority: .userInitiated) {
            try PDFBuilder.write(files: files, to: dest, title: title, author: author)
        }.value
        return dest
    }

    static func images(book: Book) async throws -> [URL] {
        let files = await renderedFiles(book: book)
        guard !files.isEmpty else { throw ExportError.noPages }
        let dir = freshDir()
        let base = safeName(book.title)
        var urls: [URL] = []
        for (i, item) in files.enumerated() {
            let dest = dir.appendingPathComponent(String(format: "%@_%03d.jpg", base, i + 1))
            try FileManager.default.copyItem(at: item.1, to: dest)
            urls.append(dest)
        }
        return urls
    }

    static func text(book: Book) throws -> URL {
        guard !book.pages.isEmpty else { throw ExportError.noPages }
        var out = "\(book.title)\n"
        if !book.author.isEmpty { out += "\(book.author)\n" }
        for (i, p) in book.pages.enumerated() {
            out += "\n――― \(i + 1) ページ ―――\n"
            out += p.text
            out += "\n"
        }
        let dest = freshDir().appendingPathComponent(safeName(book.title) + ".txt")
        try out.write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }
}

enum PDFBuilder {
    static let pageWidth: CGFloat = 595.0 // A4 幅（pt）

    static func write(files: [(Page, URL)], to url: URL, title: String, author: String) throws {
        let format = UIGraphicsPDFRendererFormat()
        var info: [String: Any] = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "本スキャン"
        ]
        if !author.isEmpty { info[kCGPDFContextAuthor as String] = author }
        format.documentInfo = info
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842), format: format)
        try renderer.writePDF(to: url) { ctx in
            for (page, file) in files {
                autoreleasepool {
                    guard let image = loadImage(file) else { return }
                    let w = CGFloat(image.width)
                    let h = CGFloat(image.height)
                    guard w > 0, h > 0 else { return }
                    let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageWidth * h / w)
                    ctx.beginPage(withBounds: bounds, pageInfo: [:])
                    let cg = ctx.cgContext
                    cg.saveGState()
                    cg.translateBy(x: 0, y: bounds.height)
                    cg.scaleBy(x: 1, y: -1)
                    cg.interpolationQuality = .high
                    cg.draw(image, in: bounds)
                    cg.restoreGState()
                    if page.hasValidOCR, let lines = page.ocrLines, !lines.isEmpty {
                        drawInvisibleText(lines, in: bounds, context: cg)
                    }
                }
            }
        }
    }

    /// JPEG はそのまま埋め込む（再圧縮しないので画質劣化なし）
    static func loadImage(_ url: URL) -> CGImage? {
        if let provider = CGDataProvider(url: url as CFURL),
           let img = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            return img
        }
        return ImageIOHelper.load(url: url)
    }

    static func drawInvisibleText(_ lines: [OCRLine], in bounds: CGRect, context cg: CGContext) {
        cg.saveGState()
        cg.setTextDrawingMode(.invisible)
        for line in lines where !line.text.isEmpty {
            let r = CGRect(x: line.x * bounds.width,
                           y: line.y * bounds.height,
                           width: line.w * bounds.width,
                           height: line.h * bounds.height)
            guard r.width > 1, r.height > 1 else { continue }
            let vertical = r.height > r.width * 1.6 && line.text.count > 1
            let fontSize = max(1, (vertical ? r.width : r.height) * 0.85)
            let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attr = NSAttributedString(string: line.text,
                                          attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attr)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            guard width > 0 else { continue }
            cg.saveGState()
            if vertical {
                cg.translateBy(x: r.minX + r.width * 0.15, y: r.minY)
                cg.rotate(by: .pi / 2)
                cg.scaleBy(x: r.height / width, y: -1)
            } else {
                cg.translateBy(x: r.minX, y: r.maxY - r.height * 0.18)
                cg.scaleBy(x: r.width / width, y: -1)
            }
            cg.textPosition = .zero
            CTLineDraw(ctLine, cg)
            cg.restoreGState()
        }
        cg.restoreGState()
    }
}
