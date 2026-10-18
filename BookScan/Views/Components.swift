import SwiftUI
import UIKit
import VisionKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - サムネイル

struct PageThumbnail: View {
    let bookID: UUID
    let page: Page
    var contentMode: ContentMode = .fit

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color(.secondarySystemBackground))
                ProgressView().controlSize(.small)
            }
        }
        .task(id: page.renderKey) {
            if let cached = PageImages.cachedThumbnail(page) {
                image = cached
            } else {
                image = await PageImages.thumbnail(bookID: bookID, page: page)
            }
        }
    }
}

struct BookCoverView: View {
    let book: Book
    var showsProgress: Bool = false

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                if let p = book.coverPage {
                    PageThumbnail(bookID: book.id, page: p, contentMode: .fill)
                } else {
                    Image(systemName: "book.closed")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: book.binding == .right ? .trailing : .leading) {
                LinearGradient(colors: [.black.opacity(0.22), .black.opacity(0.0)],
                               startPoint: book.binding == .right ? .trailing : .leading,
                               endPoint: book.binding == .right ? .leading : .trailing)
                    .frame(width: 12)
            }
            .overlay(alignment: .bottom) {
                if showsProgress && book.lastReadIndex > 0 && book.pages.count > 1 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.35))
                            Rectangle().fill(Color.accentColor)
                                .frame(width: geo.size.width * book.progress)
                        }
                    }
                    .frame(height: 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(0.08)))
            .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 4)
    }
}

// MARK: - スキャナー（メモアプリと同じ VisionKit の書類スキャナー）

struct DocumentScannerView: UIViewControllerRepresentable {
    var onFinish: (VNDocumentCameraScan) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(_ parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.onFinish(scan)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}

// MARK: - 共有シート

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - スキャン・写真取り込みの共通処理

struct PageImporterModifier: ViewModifier {
    @Environment(LibraryStore.self) private var store
    @Binding var scanTarget: ImportTarget?
    @Binding var photoTarget: ImportTarget?
    @Binding var fileTarget: ImportTarget?
    var onImported: (UUID, Bool) -> Void

    @State private var items: [PhotosPickerItem] = []
    @State private var activePhotoTarget: ImportTarget?
    @State private var fileError: String?
    @State private var activeFileTarget: ImportTarget?

    private var scannerSupported: Bool { VNDocumentCameraViewController.isSupported }

    /// 1枚の撮り直し（差し替え）や明示指定はメモ方式、それ以外は連続スキャン
    private func useClassic(_ t: ImportTarget) -> Bool { t.classic || t.replacing != nil }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: Binding(
                get: { scanTarget.flatMap { useClassic($0) && !scannerSupported ? nil : $0 } },
                set: { scanTarget = $0 }
            )) { target in
                if useClassic(target) {
                    DocumentScannerView(onFinish: { scan in
                        scanTarget = nil
                        Task {
                            if let id = await store.importScan(scan, target: target) {
                                onImported(id, target.bookID == nil)
                            }
                        }
                    }, onCancel: {
                        scanTarget = nil
                    })
                    .ignoresSafeArea()
                } else {
                    BookScannerView(target: target) { id, isNew in
                        scanTarget = nil
                        if let id { onImported(id, isNew) }
                    }
                    .environment(store)
                }
            }
            .alert("この端末ではスキャナーを使えません", isPresented: Binding(
                get: { scanTarget.map { useClassic($0) } == true && !scannerSupported },
                set: { if !$0 { scanTarget = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("カメラ付きの iPhone / iPad の実機で利用してください。写真からの取り込みは使えます。")
            }
            .photosPicker(isPresented: Binding(
                get: { photoTarget != nil },
                set: { if !$0 { photoTarget = nil } }
            ), selection: $items, maxSelectionCount: nil, selectionBehavior: .ordered, matching: .images)
            .fileImporter(isPresented: Binding(
                get: { fileTarget != nil },
                set: { if !$0 { fileTarget = nil } }
            ), allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                let target = activeFileTarget ?? fileTarget ?? ImportTarget()
                fileTarget = nil
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty else { return }
                    Task {
                        if let id = await store.importFiles(urls, target: target) {
                            onImported(id, target.bookID == nil)
                        }
                    }
                case .failure(let error):
                    fileError = error.localizedDescription
                }
            }
            .alert("取り込めませんでした", isPresented: Binding(
                get: { fileError != nil },
                set: { if !$0 { fileError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(fileError ?? "")
            }
            .onChange(of: fileTarget) { _, newValue in
                if let newValue { activeFileTarget = newValue }
            }
            .onChange(of: photoTarget) { _, newValue in
                if let newValue { activePhotoTarget = newValue }
            }
            .onChange(of: items) { _, newItems in
                guard !newItems.isEmpty else { return }
                let picked = newItems
                let target = activePhotoTarget ?? ImportTarget()
                items = []
                Task {
                    let id = await store.importImages(count: picked.count,
                                                      into: target.bookID,
                                                      at: target.insertAt,
                                                      autoCrop: AppSettings.autoCropPhotos) { i in
                        guard let data = try? await picked[i].loadTransferable(type: Data.self) else { return nil }
                        return UIImage(data: data)
                    }
                    if let id { onImported(id, target.bookID == nil) }
                }
            }
    }
}

extension View {
    func pageImporter(scanTarget: Binding<ImportTarget?>,
                      photoTarget: Binding<ImportTarget?>,
                      fileTarget: Binding<ImportTarget?>,
                      onImported: @escaping (UUID, Bool) -> Void = { _, _ in }) -> some View {
        modifier(PageImporterModifier(scanTarget: scanTarget, photoTarget: photoTarget, fileTarget: fileTarget, onImported: onImported))
    }
}

// MARK: - 取り込み中の表示

struct ImportProgressBanner: View {
    let progress: LibraryStore.ImportProgress

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 4) {
                Text("取り込み中 \(progress.done) / \(progress.total)")
                    .font(.subheadline.weight(.semibold))
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 160)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

struct BusyOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(message).font(.subheadline)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
