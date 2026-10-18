import Foundation
import ImageIO
import UIKit

enum Paths {
    static let fm = FileManager.default

    static var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var caches: URL { fm.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    static var libraryFile: URL { documents.appendingPathComponent("library.json") }
    static var booksDir: URL { documents.appendingPathComponent("Books", isDirectory: true) }
    static var renderedDir: URL { caches.appendingPathComponent("Rendered", isDirectory: true) }
    static var thumbsDir: URL { caches.appendingPathComponent("Thumbs", isDirectory: true) }
    static var exportDir: URL { fm.temporaryDirectory.appendingPathComponent("Export", isDirectory: true) }

    static func bookDir(_ id: UUID) -> URL {
        booksDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func pageFile(bookID: UUID, fileName: String) -> URL {
        bookDir(bookID).appendingPathComponent(fileName)
    }

    static func renderedFile(_ page: Page) -> URL {
        renderedDir.appendingPathComponent(page.renderKey + ".jpg")
    }

    static func thumbFile(_ page: Page) -> URL {
        thumbsDir.appendingPathComponent(page.renderKey + ".jpg")
    }

    static func ensure(_ dir: URL) {
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func purgeCaches(pageID: UUID) {
        let prefix = pageID.uuidString
        for dir in [renderedDir, thumbsDir] {
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in items where name.hasPrefix(prefix) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    static func clearCaches() {
        try? fm.removeItem(at: renderedDir)
        try? fm.removeItem(at: thumbsDir)
        try? fm.removeItem(at: exportDir)
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0)
        }
        return total
    }
}

enum ImageIOHelper {
    /// 大きな画像を省メモリで縮小読み込み
    static func downsample(url: URL, maxPixel: CGFloat) -> CGImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as [CFString: Any] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as [CFString: Any] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
    }

    static func load(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    @discardableResult
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) -> Bool {
        Paths.ensure(url.deletingLastPathComponent())
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        let props = [kCGImageDestinationLossyCompressionQuality: quality] as [CFString: Any] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        return CGImageDestinationFinalize(dest)
    }
}

extension UIImage {
    /// 向き情報を焼き込んだ CGImage を返す
    func normalizedCGImage() -> CGImage? {
        if imageOrientation == .up, let cg = cgImage { return cg }
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: pixelSize))
        }.cgImage
    }
}

/// レンダリング済み画像（フィルター・回転適用後）のディスクキャッシュを管理
actor PageRenderCenter {
    static let shared = PageRenderCenter()

    private var inflight: [String: Task<URL?, Never>] = [:]

    /// フル解像度のレンダリング結果ファイル
    func renderedFile(bookID: UUID, page: Page) async -> URL? {
        let original = Paths.pageFile(bookID: bookID, fileName: page.fileName)
        if page.filter == .original && page.normalizedRotation == 0 { return original }
        let dest = Paths.renderedFile(page)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let key = "full-" + page.renderKey
        if let t = inflight[key] { return await t.value }
        let filter = page.filter
        let rotation = page.normalizedRotation
        let task = Task.detached(priority: .userInitiated) { () -> URL? in
            guard let cg = ImageProcessor.render(url: original, filter: filter, rotation: rotation, maxPixel: nil) else { return nil }
            return ImageIOHelper.writeJPEG(cg, to: dest, quality: 0.93) ? dest : nil
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }

    /// サムネイル（長辺 480px）
    func thumbnailFile(bookID: UUID, page: Page) async -> URL? {
        let dest = Paths.thumbFile(page)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let key = "thumb-" + page.renderKey
        if let t = inflight[key] { return await t.value }
        let original = Paths.pageFile(bookID: bookID, fileName: page.fileName)
        let filter = page.filter
        let rotation = page.normalizedRotation
        let task = Task.detached(priority: .userInitiated) { () -> URL? in
            guard let cg = ImageProcessor.render(url: original, filter: filter, rotation: rotation, maxPixel: 480) else { return nil }
            return ImageIOHelper.writeJPEG(cg, to: dest, quality: 0.8) ? dest : nil
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }
}

/// メモリキャッシュ付きの画像取得
enum PageImages {
    static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 220 * 1024 * 1024
        return c
    }()

    private static func cost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }

    static func cachedThumbnail(_ page: Page) -> UIImage? {
        cache.object(forKey: ("t-" + page.renderKey) as NSString)
    }

    static func cachedDisplay(_ page: Page) -> UIImage? {
        cache.object(forKey: ("d-" + page.renderKey) as NSString)
    }

    static func thumbnail(bookID: UUID, page: Page) async -> UIImage? {
        let key = ("t-" + page.renderKey) as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let url = await PageRenderCenter.shared.thumbnailFile(bookID: bookID, page: page) else { return nil }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let cg = ImageIOHelper.load(url: url) else { return nil }
            return UIImage(cgImage: cg).preparingForDisplay()
        }.value
        if let image { cache.setObject(image, forKey: key, cost: cost(image)) }
        return image
    }

    /// 表示用（長辺 3000px まで）
    static func display(bookID: UUID, page: Page) async -> UIImage? {
        let key = ("d-" + page.renderKey) as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let url = await PageRenderCenter.shared.renderedFile(bookID: bookID, page: page) else { return nil }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let cg = ImageIOHelper.downsample(url: url, maxPixel: 3000) else { return nil }
            return UIImage(cgImage: cg).preparingForDisplay()
        }.value
        if let image { cache.setObject(image, forKey: key, cost: cost(image)) }
        return image
    }
}
