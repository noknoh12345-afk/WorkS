import SwiftUI
import UIKit
import AVFoundation
import ScanCore

// MARK: - プレビュー（紙の輪郭を重ねて表示）

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private let outline = CAShapeLayer()
    private let fill = CAShapeLayer()
    var onTap: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        fill.fillColor = UIColor.white.withAlphaComponent(0.08).cgColor
        fill.strokeColor = nil
        outline.fillColor = nil
        outline.lineWidth = 3
        outline.lineJoin = .round
        outline.strokeColor = UIColor.systemYellow.cgColor
        layer.addSublayer(fill)
        layer.addSublayer(outline)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        outline.frame = bounds
        fill.frame = bounds
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        onTap?(g.location(in: self))
    }

    func showQuad(_ quad: Quad?, status: ScanStatus) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.09)
        guard let quad else {
            outline.opacity = 0
            fill.opacity = 0
            CATransaction.commit()
            return
        }
        let pts = quad.points.map { previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: $0.x, y: $0.y)) }
        let path = UIBezierPath()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.addLine(to: p) }
        path.close()
        outline.path = path.cgPath
        fill.path = path.cgPath
        outline.opacity = 1
        fill.opacity = 1
        let color: UIColor
        switch status {
        case .holdStill, .focusing: color = .systemYellow
        case .capturing: color = .systemGreen
        case .handOverPage: color = .systemOrange
        case .turnPage, .turning: color = UIColor.white.withAlphaComponent(0.6)
        default: color = .systemYellow
        }
        outline.strokeColor = color.cgColor
        CATransaction.commit()
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: ScanSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let v = CameraPreviewUIView()
        v.onTap = { [weak session] p in session?.focus(atLayerPoint: p) }
        session.attach(v)
        return v
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}
}

// MARK: - 連続スキャン画面

struct BookScannerView: View {
    let target: ImportTarget
    var onFinish: (UUID?, Bool) -> Void

    @Environment(LibraryStore.self) private var store
    @State private var session: ScanSession?
    @State private var previewRef: PreviewRef?
    @State private var showHelp = false
    @State private var flashOpacity = 0.0

    struct PreviewRef: Identifiable { let id: UUID }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session {
                CameraPreview(session: session)
                    .ignoresSafeArea()
                Color.white
                    .opacity(flashOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                ScannerControls(session: session,
                                onDone: finish,
                                onHelp: { showHelp = true },
                                onPreview: { previewRef = PreviewRef(id: $0) })
                if let message = session.cameraError {
                    CameraErrorView(message: message, onClose: finish)
                }
                if session.isFinishing {
                    BusyOverlay(message: session.pendingCount > 0 ? "残り \(session.pendingCount) 枚を処理中…" : "保存中…")
                }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            if session == nil {
                session = ScanSession(store: store, bookID: target.bookID, insertAt: target.insertAt)
            }
            await session?.start()
        }
        .onChange(of: session?.flashTick) { _, _ in
            flashOpacity = 0.5
            withAnimation(.easeOut(duration: 0.35)) { flashOpacity = 0 }
        }
        .sheet(item: $previewRef) { ref in
            if let session {
                ScanPagePreview(session: session, pageID: ref.id)
                    .environment(store)
            }
        }
        .sheet(isPresented: $showHelp) {
            ScanHelpView()
        }
    }

    private func finish() {
        guard let session else {
            onFinish(nil, false)
            return
        }
        Task {
            let (id, isNew) = await session.finish()
            onFinish(id, isNew)
        }
    }
}

// MARK: - 操作部

struct ScannerControls: View {
    @Bindable var session: ScanSession
    var onDone: () -> Void
    var onHelp: () -> Void
    var onPreview: (UUID) -> Void

    var body: some View {
        VStack(spacing: 10) {
            topBar
            statusPill
            banners
            Spacer(minLength: 0)
            toasts
            strip
            bottomBar
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // 上部

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onDone) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                    Text(session.pageCount > 0 ? "完了 \(session.pageCount)" : "閉じる")
                }
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(session.pageCount > 0 ? Color.accentColor : Color.black.opacity(0.45), in: Capsule())
                .foregroundStyle(.white)
            }
            Spacer(minLength: 4)
            Picker("", selection: $session.mode) {
                ForEach(ScanSession.Mode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 4)
            circleButton(session.torchOn ? "flashlight.on.fill" : "flashlight.off.fill") {
                session.torchOn.toggle()
            }
            Menu {
                Toggle("自動撮影（めくりを検知）", isOn: $session.autoCapture)
                Picker("撮影のタイミング", selection: $session.speed) {
                    ForEach(CaptureSpeed.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                Button {
                    onHelp()
                } label: {
                    Label("使い方", systemImage: "questionmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 12)
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.45), in: Circle())
                .foregroundStyle(.white)
        }
    }

    // 状態表示

    private var statusText: String {
        switch session.status {
        case .starting: return "準備中…"
        case .findingPage: return session.pageCount == 0 ? "ページ全体を画面に入れてください" : "ページを写してください"
        case .holdStill: return "そのまま…"
        case .focusing: return "ピントを合わせています…"
        case .capturing: return "撮影"
        case .turnPage: return "次のページをめくってください"
        case .turning: return "めくり中…"
        case .handOverPage: return "手がページにかかっています"
        case .paused: return "自動撮影オフ：シャッターで撮影"
        }
    }

    private var statusSymbol: String {
        switch session.status {
        case .starting: return "camera"
        case .findingPage: return "viewfinder"
        case .holdStill, .focusing: return "hand.raised"
        case .capturing: return "camera.shutter.button"
        case .turnPage: return "book.pages"
        case .turning: return "arrow.turn.up.right"
        case .handOverPage: return "hand.point.up.left"
        case .paused: return "camera.circle"
        }
    }

    private var statusPill: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                Text(statusText).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
            .animation(.easeInOut(duration: 0.15), value: statusText)

            HStack(spacing: 8) {
                Text("\(session.pageCount)ページ")
                if let n = session.currentNumber {
                    Text("いま p.\(n)")
                }
                if session.pendingCount > 0 {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini).tint(.white)
                        Text("処理中 \(session.pendingCount)")
                    }
                }
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.35), in: Capsule())
        }
    }

    private func label(for id: UUID) -> String {
        if let n = session.displayNumber(id) { return n.estimated ? "p.\(n.number)?" : "p.\(n.number)" }
        if let i = session.pageIDs.firstIndex(of: id) { return "\(i + 1)枚目" }
        return "ページ"
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 6) {
            if let target = session.replaceTargetID {
                banner(icon: "arrow.triangle.2.circlepath.camera", color: .orange,
                       text: "撮り直し：\(label(for: target)) を写してください",
                       button: "やめる") { session.cancelRetake() }
            }
            if session.cursorAtStart {
                banner(icon: "text.insert", color: .blue, text: "差し込み：先頭に追加中", button: "終了") {
                    session.endInsertMode()
                }
            } else if let after = session.cursorAfterID {
                banner(icon: "text.insert", color: .blue, text: "差し込み：\(label(for: after)) の後ろに追加中",
                       button: "終了") { session.endInsertMode() }
            }
            if !session.missing.isEmpty {
                let list = session.missing.prefix(5).map { "p.\($0)" }.joined(separator: "・")
                banner(icon: "exclamationmark.triangle.fill", color: .yellow,
                       text: "抜け \(list)\(session.missing.count > 5 ? " ほか" : "")",
                       button: nil, action: nil)
            }
        }
        .padding(.horizontal, 12)
    }

    private func banner(icon: String, color: Color, text: String, button: String?, action: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 4)
            if let button, let action {
                Button(button, action: action)
                    .font(.footnote.weight(.bold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(color.opacity(0.85))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    // 通知

    private var toasts: some View {
        VStack(spacing: 6) {
            ForEach(session.toasts.suffix(2)) { t in
                HStack(spacing: 10) {
                    Image(systemName: t.style == .warning ? "exclamationmark.triangle.fill"
                          : t.style == .success ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(t.style == .warning ? Color.yellow : t.style == .success ? Color.green : Color.white)
                    Text(t.message)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let action = t.action, let label = t.actionLabel {
                        Button(label) { session.perform(action, toast: t) }
                            .font(.footnote.weight(.bold))
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .onTapGesture { session.dismiss(t) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .animation(.spring(duration: 0.3), value: session.toasts)
    }

    // 撮ったページの帯

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if session.cursorAtStart { insertionMarker }
                    ForEach(session.pageIDs, id: \.self) { id in
                        stripItem(id)
                            .id(id)
                        if session.cursorAfterID == id { insertionMarker }
                    }
                    ForEach(0..<session.pendingCount, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 52, height: 70)
                            .overlay(ProgressView().tint(.white))
                    }
                    Color.clear.frame(width: 1, height: 1).id("end")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .frame(height: session.pageCount + session.pendingCount > 0 ? 92 : 0)
            .opacity(session.pageCount + session.pendingCount > 0 ? 1 : 0)
            .onChange(of: session.lastAddedID) { _, id in
                withAnimation { proxy.scrollTo(id ?? UUID(), anchor: .center) }
            }
            .onChange(of: session.pendingCount) { _, _ in
                if session.cursorAfterID == nil && !session.cursorAtStart {
                    withAnimation { proxy.scrollTo("end", anchor: .trailing) }
                }
            }
        }
    }

    private var insertionMarker: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.blue)
            .frame(width: 4, height: 70)
    }

    @ViewBuilder
    private func stripItem(_ id: UUID) -> some View {
        let page = session.page(id)
        Menu {
            Button {
                onPreview(id)
            } label: {
                Label("大きく見る", systemImage: "magnifyingglass")
            }
            Button {
                session.retake(id)
            } label: {
                Label("撮り直す（次に写したページで差し替え）", systemImage: "arrow.triangle.2.circlepath.camera")
            }
            Button {
                session.insertAfter(id)
            } label: {
                Label("この後ろに差し込む", systemImage: "text.insert")
            }
            if session.pageIDs.first == id {
                Button {
                    session.insertAtStart()
                } label: {
                    Label("先頭に差し込む", systemImage: "arrow.left.to.line")
                }
            }
            Divider()
            Button(role: .destructive) {
                session.delete(id)
            } label: {
                Label("削除", systemImage: "trash")
            }
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.15))
                    if let page, let bookID = session.bookID {
                        PageThumbnail(bookID: bookID, page: page)
                    }
                }
                .frame(width: 52, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(borderColor(id, page: page), lineWidth: session.replaceTargetID == id || page?.hasIssues == true ? 2.5 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if page?.hasIssues == true {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.yellow)
                            .shadow(radius: 1)
                            .offset(x: 3, y: -3)
                    }
                }
                Text(label(for: id))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private func borderColor(_ id: UUID, page: Page?) -> Color {
        if session.replaceTargetID == id { return .orange }
        if page?.hasIssues == true { return .yellow }
        if session.lastAddedID == id { return .white }
        return .white.opacity(0.3)
    }

    // 下部

    private var bottomBar: some View {
        HStack {
            Button {
                session.undoLast()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward").font(.title3)
                    Text("取り消し").font(.caption2)
                }
                .frame(width: 70)
                .foregroundStyle(.white)
            }
            .disabled(session.lastAddedID == nil)
            .opacity(session.lastAddedID == nil ? 0.4 : 1)

            Spacer()

            Button {
                session.shutter()
            } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                    Circle().fill(Color.white).frame(width: 62, height: 62)
                    Circle()
                        .trim(from: 0, to: holdProgress)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 84, height: 84)
                        .animation(.linear(duration: 0.1), value: holdProgress)
                }
            }
            .accessibilityLabel("シャッター")

            Spacer()

            Button {
                session.autoCapture.toggle()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: session.autoCapture ? "a.circle.fill" : "a.circle").font(.title3)
                    Text(session.autoCapture ? "自動" : "手動").font(.caption2)
                }
                .frame(width: 70)
                .foregroundStyle(session.autoCapture ? Color.yellow : Color.white)
            }
        }
        .padding(.horizontal, 24)
    }

    private var holdProgress: Double {
        if case .holdStill(let p) = session.status { return p }
        if case .capturing = session.status { return 1 }
        return 0
    }
}

// MARK: - ページの拡大表示

struct ScanPagePreview: View {
    let session: ScanSession
    let pageID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let page = session.page(pageID), let bookID = session.bookID {
                    PageThumbnail(bookID: bookID, page: page)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal)
                    if page.hasIssues {
                        Label(page.issueLabels.joined(separator: "・"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline.weight(.semibold))
                    }
                    HStack(spacing: 12) {
                        Button {
                            session.retake(pageID)
                            dismiss()
                        } label: {
                            Label("撮り直す", systemImage: "arrow.triangle.2.circlepath.camera")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(role: .destructive) {
                            session.delete(pageID)
                            dismiss()
                        } label: {
                            Label("削除", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)
                    Text("範囲がずれているときは、スキャン後にページの「範囲を調整」で直せます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                } else {
                    ContentUnavailableView("ページがありません", systemImage: "doc")
                }
            }
            .padding(.vertical)
            .navigationTitle(session.displayNumber(pageID).map { "p.\($0.number)" } ?? "ページ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

// MARK: - カメラが使えないとき

struct CameraErrorView: View {
    let message: String
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 44))
                .foregroundStyle(.white)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Button("「設定」を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Button("閉じる", action: onClose)
                .foregroundStyle(.white)
        }
        .padding(30)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
        .padding(24)
    }
}

// MARK: - 使い方

struct ScanHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("基本") {
                    tip("book.pages", "ページを写して手を止めると自動で1回だけ撮影します。シャッター音のあとにめくってください。")
                    tip("arrow.turn.up.right", "めくる動きを検知して、次のページが落ち着いたらまた撮ります。同じページを二度撮ることはありません。")
                    tip("number", "余白のページ番号を読み取って「いま何ページか」を表示します。")
                }
                Section("ミスしたとき") {
                    tip("exclamationmark.triangle", "抜けたページは上に「抜け p.13」と出ます。そのページまで戻して写せば、正しい位置に自動で入ります。戻ったあと撮影済みのページは自動でスキップされます。")
                    tip("arrow.triangle.2.circlepath.camera", "ブレ・手写りは自動で撮り直します。めくった後なら、そのページに戻して写すと差し替わります。")
                    tip("hand.tap", "下の帯のページをタップすると「撮り直す」「この後ろに差し込む」「削除」ができます。番号のない本の撮り逃しは「この後ろに差し込む」で。")
                    tip("arrow.uturn.backward", "「取り消し」で最後に追加したページを消せます。")
                }
                Section("きれいに撮るコツ") {
                    tip("light.max", "明るい場所で、影が入らないように。暗いときはライトを点けます。")
                    tip("rectangle.split.2x1", "開いた本を1枚で撮るときは「見開き」にすると左右のページに分けて保存します。")
                    tip("viewfinder", "範囲がずれたページは、あとでページの「範囲を調整」から直せます（元の写真を保存しています）。")
                }
            }
            .navigationTitle("連続スキャンの使い方")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
        }
    }
}
