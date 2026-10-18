import SwiftUI
import UIKit
import ScanCore

/// 元の写真の上で四隅をドラッグして、ページの範囲を作り直す
struct CropEditorView: View {
    let bookID: UUID
    let pageID: UUID

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var raw: UIImage?
    @State private var points: [CGPoint] = []
    @State private var original: [CGPoint] = []
    @State private var dragging: Int?
    @State private var saving = false
    @State private var message: String?

    private var page: Page? { store.book(bookID)?.pages.first { $0.id == pageID } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { geo in
                    if let raw, points.count == 4 {
                        editor(raw, in: geo.size)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 10) {
                    Button {
                        autoDetect()
                    } label: {
                        Label("自動検出", systemImage: "viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
                    } label: {
                        Label("写真全体", systemImage: "arrow.up.left.and.arrow.down.right")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        points = original
                    } label: {
                        Label("元に戻す", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                .padding(.horizontal)
                .disabled(raw == nil || saving)
            }
            .padding(.bottom, 12)
            .navigationTitle("範囲を調整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .bold()
                        .disabled(raw == nil || saving)
                }
            }
            .overlay {
                if saving { BusyOverlay(message: "作り直しています…") }
            }
            .task { load() }
        }
    }

    // MARK: 編集画面

    private func fitRect(_ size: CGSize, in area: CGSize) -> CGRect {
        let inset: CGFloat = 26
        let w = max(1, area.width - inset * 2), h = max(1, area.height - inset * 2)
        let s = min(w / size.width, h / size.height)
        let fw = size.width * s, fh = size.height * s
        return CGRect(x: (area.width - fw) / 2, y: (area.height - fh) / 2, width: fw, height: fh)
    }

    private func screen(_ p: CGPoint, _ r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
    }

    @ViewBuilder
    private func editor(_ image: UIImage, in area: CGSize) -> some View {
        let r = fitRect(image.size, in: area)
        let pts = points.map { screen($0, r) }
        ZStack {
            Image(uiImage: image)
                .resizable()
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)

            Path { p in
                p.addRect(r)
                p.addLines(pts)
                p.closeSubpath()
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { p in
                p.addLines(pts)
                p.closeSubpath()
            }
            .stroke(Color.accentColor, lineWidth: 2)
            .allowsHitTesting(false)

            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
                    .shadow(radius: 2)
                    .position(pts[i])
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                dragging = i
                                let x = min(max((v.location.x - r.minX) / r.width, 0), 1)
                                let y = min(max((v.location.y - r.minY) / r.height, 0), 1)
                                points[i] = CGPoint(x: x, y: y)
                                message = nil
                            }
                            .onEnded { _ in dragging = nil }
                    )
            }

            if let d = dragging {
                loupe(image, rect: r, point: points[d])
                    .position(x: points[d].x < 0.5 ? area.width - 80 : 80, y: 80)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 指で隠れる角を拡大して見せる
    private func loupe(_ image: UIImage, rect r: CGRect, point p: CGPoint) -> some View {
        let zoom: CGFloat = 3
        let size: CGFloat = 130
        let w = r.width * zoom, h = r.height * zoom
        return Image(uiImage: image)
            .resizable()
            .frame(width: w, height: h)
            .offset(x: -p.x * w + size / 2, y: -p.y * h + size / 2)
            .frame(width: size, height: size, alignment: .topLeading)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white, lineWidth: 3))
            .overlay {
                ZStack {
                    Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 26)
                    Rectangle().fill(Color.accentColor).frame(width: 26, height: 1.5)
                }
            }
            .shadow(radius: 6)
    }

    // MARK: 処理

    private func load() {
        guard raw == nil, let page, let rawName = page.rawFileName else {
            if page?.rawFileName == nil { message = "このページには元の写真がありません" }
            return
        }
        let url = Paths.pageFile(bookID: bookID, fileName: rawName)
        let quad = Quad(flat: page.quad) ?? .full
        Task {
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let cg = ImageIOHelper.downsample(url: url, maxPixel: 2200) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            raw = image
            let p = quad.points.map { CGPoint(x: $0.x, y: $0.y) }
            points = p
            original = p
            if image == nil { message = "元の写真を読み込めませんでした" }
        }
    }

    private func currentQuad() -> Quad? {
        guard points.count == 4 else { return nil }
        let q = Quad(topLeft: Point2(Double(points[0].x), Double(points[0].y)),
                     topRight: Point2(Double(points[1].x), Double(points[1].y)),
                     bottomRight: Point2(Double(points[2].x), Double(points[2].y)),
                     bottomLeft: Point2(Double(points[3].x), Double(points[3].y)))
        return q
    }

    private func autoDetect() {
        guard let cg = raw?.cgImage else { return }
        let spread = page?.rawHalf != nil
        Task {
            let q = await Task.detached(priority: .userInitiated) {
                CaptureProcessor.detectQuad(cg, spread: spread)
            }.value
            if let q {
                points = q.points.map { CGPoint(x: $0.x, y: $0.y) }
                message = nil
            } else {
                message = "紙の輪郭を見つけられませんでした。四隅を手で合わせてください"
            }
        }
    }

    private func save() {
        guard let page, let rawName = page.rawFileName, let quad = currentQuad() else { return }
        guard quad.isConvex, quad.area > 0.02 else {
            message = "四隅の位置が正しくありません（線が交差しています）"
            return
        }
        saving = true
        let url = Paths.pageFile(bookID: bookID, fileName: rawName)
        let half = page.rawHalf
        let bookID = self.bookID
        let quality = AppSettings.jpegQuality
        Task {
            let newName: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let image = CaptureProcessor.rebuild(rawURL: url, quad: quad, half: half) else { return nil }
                let name = UUID().uuidString + ".jpg"
                return ImageIOHelper.writeJPEG(image, to: Paths.pageFile(bookID: bookID, fileName: name), quality: quality) ? name : nil
            }.value
            saving = false
            if let newName {
                store.updatePageImage(bookID: bookID, pageID: pageID, newFileName: newName, quad: quad.flatArray)
                dismiss()
            } else {
                message = "作り直しに失敗しました"
            }
        }
    }
}
