import Foundation
import SwiftUI
import UIKit
import Observation
import ScanCore

/// 連続スキャン1回分：カメラ → めくり検知 → 撮影 → 処理 → 本への追加・差し込み・差し替え
@MainActor
@Observable
final class ScanSession {
    enum Mode: String, CaseIterable, Identifiable {
        case single, spread
        var id: String { rawValue }
        var label: String { self == .single ? "1ページ" : "見開き" }
    }

    struct Toast: Identifiable, Equatable {
        enum Style { case info, success, warning }
        enum Action: Equatable {
            case addSkipped(UUID)
            case showMissingHelp
        }
        let id = UUID()
        var message: String
        var style: Style
        var action: Action?
        var actionLabel: String?
    }

    // MARK: 画面に出す状態

    private(set) var status: ScanStatus = .starting
    private(set) var stableProgress: Double = 0
    private(set) var pageIDs: [UUID] = []
    private(set) var pendingCount = 0
    private(set) var missing: [Int] = []
    private(set) var currentNumber: Int?
    private(set) var cursorAfterID: UUID?
    private(set) var cursorAtStart = false
    private(set) var replaceTargetID: UUID?
    private(set) var flashTick = 0
    private(set) var lastAddedID: UUID?
    private(set) var cameraError: String?
    private(set) var isRunning = false
    private(set) var isFinishing = false
    private(set) var bookID: UUID?
    private(set) var isNewBook = false
    var toasts: [Toast] = []

    var autoCapture: Bool = UserDefaults.standard.object(forKey: "scanAutoCapture") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoCapture, forKey: "scanAutoCapture")
            let enabled = autoCapture
            let engine = self.engine
            camera.videoQueue.async { engine.autoEnabled = enabled }
        }
    }

    var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "scanMode") ?? "") ?? .single {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "scanMode") }
    }

    var speed: CaptureSpeed = CaptureSpeed(rawValue: UserDefaults.standard.string(forKey: "scanSpeed") ?? "") ?? .normal {
        didSet {
            UserDefaults.standard.set(speed.rawValue, forKey: "scanSpeed")
            let tuning = CaptureTuning.preset(speed)
            let engine = self.engine
            camera.videoQueue.async { engine.tuning = tuning }
        }
    }

    var torchOn = false {
        didSet { camera.setTorch(torchOn) }
    }

    // MARK: 内部

    private let store: LibraryStore
    private let requestedBookID: UUID?
    private let requestedInsertAt: Int?
    private var baseIndex = 0

    @ObservationIgnored let camera = CameraController()
    @ObservationIgnored private let analyzer = FrameAnalyzer()
    @ObservationIgnored private let engine: AutoCaptureEngine
    @ObservationIgnored private var model = ScanSessionModel()
    @ObservationIgnored private var jobContinuation: AsyncStream<ScanJob>.Continuation?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var skipped: [UUID: (ProcessedPage, UUID?)] = [:]
    @ObservationIgnored private var autoRetakeAttempts: [UUID: Int] = [:]
    @ObservationIgnored private var lastMissedCount = 0
    @ObservationIgnored private var lastMissingSet = Set<Int>()
    @ObservationIgnored weak var previewView: CameraPreviewUIView?
    @ObservationIgnored private var previewAttached = false
    /// シャッターを切ったがまだ写真が届いていない数
    @ObservationIgnored private var inFlightCaptures = 0

    init(store: LibraryStore, bookID: UUID?, insertAt: Int?) {
        self.store = store
        self.requestedBookID = bookID
        self.requestedInsertAt = insertAt
        self.engine = AutoCaptureEngine(tuning: CaptureTuning.preset(
            CaptureSpeed(rawValue: UserDefaults.standard.string(forKey: "scanSpeed") ?? "") ?? .normal))
        self.engine.autoEnabled = UserDefaults.standard.object(forKey: "scanAutoCapture") as? Bool ?? true
    }

    var book: Book? { bookID.flatMap { store.book($0) } }

    func page(_ id: UUID) -> Page? { book?.pages.first { $0.id == id } }

    func displayNumber(_ id: UUID) -> (number: Int, estimated: Bool)? { model.displayNumber(id) }

    var pageCount: Int { pageIDs.count }

    // MARK: 開始・終了

    func start() async {
        guard !isRunning, !isFinishing else { return }
        // 本を決める（新しい本はここで作る）
        if bookID == nil {
            if let id = requestedBookID, let b = store.book(id) {
                bookID = id
                isNewBook = false
                baseIndex = min(max(requestedInsertAt ?? b.pages.count, 0), b.pages.count)
                // 直前のページは重複確認とページ番号の基準に使う
                let before = b.pages.prefix(baseIndex).suffix(3)
                let ctx = before.map { p in
                    PageRecord(id: p.id, number: p.printedNumber, confidence: p.printedNumber == nil ? .none : .medium,
                               text: p.text, hash: nil)
                }
                model = ScanSessionModel(context: Array(ctx))
            } else {
                bookID = store.createEmptyBook()
                isNewBook = true
                baseIndex = 0
                model = ScanSessionModel()
            }
        }
        guard let bookID else { return }
        store.suspendOCR(bookID)
        currentNumber = model.lastNumber

        guard await CameraController.requestAccess() else {
            cameraError = "カメラへのアクセスが許可されていません。「設定」アプリで本スキャンのカメラをオンにしてください。"
            return
        }
        do {
            try await camera.configure(highestResolution: UserDefaults.standard.bool(forKey: "scanHighestResolution"))
        } catch {
            cameraError = error.localizedDescription
            return
        }
        attachPreviewIfReady()
        startProcessingLoop()
        installFrameHandler()
        camera.start()
        isRunning = true
    }

    /// 撮影済みのページは常に保存済み。処理中の撮影を待ってから閉じる
    func finish() async -> (UUID?, Bool) {
        guard !isFinishing else { return (bookID, isNewBook) }
        isFinishing = true
        camera.setFrameHandler(nil)
        // シャッター直後なら写真が届くまで待つ（撮ったページを落とさない）
        var waited = 0
        while inFlightCaptures > 0 && waited < 40 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        camera.stop()
        if torchOn { camera.setTorch(false) }
        jobContinuation?.finish()
        jobContinuation = nil
        await processingTask?.value
        for (id, entry) in skipped {
            discard(entry.0.page)
            skipped[id] = nil
        }
        guard let bookID else { return (nil, false) }
        store.resumeOCR(bookID)
        if isNewBook, let b = store.book(bookID), b.pages.isEmpty {
            store.deleteBook(bookID)
            return (nil, false)
        }
        return (bookID, isNewBook)
    }

    // MARK: プレビュー

    func attach(_ view: CameraPreviewUIView) {
        previewView = view
        attachPreviewIfReady()
    }

    private func attachPreviewIfReady() {
        guard !previewAttached, let view = previewView, cameraError == nil else { return }
        guard camera.session.inputs.isEmpty == false else { return }
        camera.attachPreview(view.previewLayer)
        previewAttached = true
    }

    func focus(atLayerPoint p: CGPoint) {
        guard let layer = previewView?.previewLayer else { return }
        camera.focus(at: layer.captureDevicePointConverted(fromLayerPoint: p))
    }

    // MARK: フレーム処理（videoQueue）

    private func installFrameHandler() {
        let engine = self.engine
        let analyzer = self.analyzer
        let camera = self.camera
        var frame = 0
        camera.setFrameHandler { [weak self] pb, t in
            frame += 1
            // 30fps のうち 15fps を解析
            guard frame % 2 == 0 else { return }
            let sample = analyzer.analyze(pb, time: t, adjustingFocus: camera.isAdjustingFocus)
            let fire = engine.process(sample)
            let status = engine.status
            let progress = engine.stableProgress
            let missed = engine.missedPageCount
            let quad = sample.quad
            if fire {
                let angle = camera.currentCaptureAngle
                camera.capture(fast: true) { result in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.handleCapture(result, previewQuad: quad, angle: angle)
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.updateFromFrame(status: status, progress: progress, quad: quad, missed: missed, fired: fire)
                }
            }
        }
    }

    private func updateFromFrame(status: ScanStatus, progress: Double, quad: Quad?, missed: Int, fired: Bool) {
        if self.status != status { self.status = status }
        if abs(stableProgress - progress) > 0.02 || progress == 0 || progress == 1 { stableProgress = progress }
        previewView?.showQuad(quad, status: status)
        if fired { didFireShutter() }
        if missed > lastMissedCount {
            lastMissedCount = missed
            notify(.warning)
            show(Toast(message: "撮る前にめくられたページがあります。前のページに戻してください（戻せば自動で正しい位置に入ります）",
                       style: .warning, action: .showMissingHelp, actionLabel: nil), duration: 6)
        }
    }

    private func didFireShutter() {
        inFlightCaptures += 1
        flashTick += 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: 手動撮影

    func shutter() {
        guard isRunning, !isFinishing else { return }
        let engine = self.engine
        let analyzer = self.analyzer
        let camera = self.camera
        camera.videoQueue.async { [weak self] in
            guard !engine.isCapturing else { return }
            engine.notifyCaptureStarted(thumb: nil)
            let quad = analyzer.recentQuad
            let angle = camera.currentCaptureAngle
            camera.capture(fast: false) { result in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.handleCapture(result, previewQuad: quad, angle: angle)
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.didFireShutter() }
            }
        }
    }

    // MARK: 撮影結果 → 処理待ち行列

    private func handleCapture(_ result: Result<Data, Error>, previewQuad: Quad?, angle: Double) {
        let engine = self.engine
        inFlightCaptures = max(0, inFlightCaptures - 1)
        switch result {
        case .success(let data):
            camera.videoQueue.async { engine.notifyCaptureFinished(success: true) }
            guard let bookID, let jobContinuation else { return }
            let job = ScanJob(data: data,
                              spread: mode == .spread,
                              rtl: book?.binding == .right,
                              bookID: bookID,
                              filter: AppSettings.defaultFilter,
                              quality: AppSettings.jpegQuality,
                              keepRaw: UserDefaults.standard.object(forKey: "scanKeepRaw") as? Bool ?? true,
                              previewQuad: previewQuad,
                              captureAngle: angle)
            pendingCount += 1
            jobContinuation.yield(job)
        case .failure:
            camera.videoQueue.async { engine.notifyCaptureFinished(success: false) }
            notify(.error)
            show(Toast(message: "撮影に失敗しました。もう一度撮ります", style: .warning))
        }
    }

    private func startProcessingLoop() {
        let (stream, continuation) = AsyncStream.makeStream(of: ScanJob.self)
        jobContinuation = continuation
        processingTask = Task { [weak self] in
            for await job in stream {
                let processed = await Task.detached(priority: .userInitiated) {
                    CaptureProcessor.process(job)
                }.value
                self?.apply(processed)
            }
        }
    }

    // MARK: 処理結果を本に反映

    private func apply(_ processed: [ProcessedPage]) {
        pendingCount = max(0, pendingCount - 1)
        guard let bookID else { return }
        guard !processed.isEmpty else {
            show(Toast(message: "画像を処理できませんでした。もう一度撮ってください", style: .warning))
            return
        }
        for item in processed {
            let (outcome, plan) = model.apply(item.candidate, newID: item.page.id)
            var page = item.page
            page.printedNumber = plan.confidence >= .medium ? plan.number : nil
            switch outcome {
            case .inserted(_, let at):
                store.insertScannedPage(page, into: bookID, at: baseIndex + at)
                lastAddedID = page.id
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                handleQuality(of: page, recordID: page.id)

            case .replaced(let old, _, let at):
                store.replaceScannedPage(bookID: bookID, oldID: old, with: page)
                lastAddedID = page.id
                notify(.success)
                let label = model.displayNumber(page.id).map { "p.\($0.number)" } ?? "\(at + 1)枚目"
                show(Toast(message: "\(label) を撮り直しました", style: .success))
                if replaceTargetID == old { replaceTargetID = nil }
                handleQuality(of: page, recordID: page.id)

            case .skipped(let dup):
                let dupRecord = model.record(dup)
                // ブレたページの自動撮り直しが、まだブレていた
                if let r = dupRecord, r.flags.contains(where: \.isRetakeable),
                   item.candidate.flags.contains(where: \.isRetakeable) {
                    discard(page)
                    retryAutoRetake(for: dup, reason: "まだブレています。スマホを止めてもう一度")
                    continue
                }
                skipped[page.id] = (item, dup)
                let label = model.displayNumber(dup).map { "p.\($0.number)" } ?? "撮影済み"
                show(Toast(message: "\(label) と同じページなので追加しませんでした", style: .info,
                           action: .addSkipped(page.id), actionLabel: "追加する"), duration: 5)
                let pid = page.id
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    self?.expireSkipped(pid)
                }
            }
        }
        refreshDerivedState()
    }

    private func handleQuality(of page: Page, recordID: UUID) {
        let flags = Set((page.flags ?? []).compactMap(PageFlag.init(rawValue:)))
        guard flags.contains(where: \.isRetakeable) else { return }
        let what = flags.contains(.hand) ? "手が写っていた" : "ブレていた"
        retryAutoRetake(for: recordID, reason: "\(what)ので、そのまま撮り直します")
    }

    /// めくる前ならそのページを自動で撮り直す（同じページで最大2回）
    private func retryAutoRetake(for recordID: UUID, reason: String) {
        let attempts = autoRetakeAttempts[recordID] ?? 0
        guard attempts < 2, model.canAutoRetake(recordID) else {
            let label = model.displayNumber(recordID).map { "p.\($0.number)" } ?? "このページ"
            show(Toast(message: "\(label) は確認が必要です（帯の ⚠︎ から撮り直せます）", style: .warning), duration: 5)
            return
        }
        autoRetakeAttempts[recordID] = attempts + 1
        let engine = self.engine
        camera.videoQueue.async { [weak self] in
            let ok = engine.requestRetakeIfNotTurned()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if ok {
                        self.show(Toast(message: reason, style: .info))
                    } else {
                        let label = self.model.displayNumber(recordID).map { "p.\($0.number)" } ?? "前のページ"
                        self.notify(.warning)
                        self.show(Toast(message: "\(label) がブレています。戻して写すと自動で差し替えます", style: .warning), duration: 6)
                    }
                }
            }
        }
    }

    private func refreshDerivedState() {
        pageIDs = model.ids
        currentNumber = model.lastNumber
        let newMissing = model.missingNumbers
        let appeared = Set(newMissing).subtracting(lastMissingSet)
        missing = newMissing
        lastMissingSet = Set(newMissing)
        if !appeared.isEmpty {
            notify(.warning)
            let list = appeared.sorted().prefix(4).map { "p.\($0)" }.joined(separator: "・")
            show(Toast(message: "\(list) が抜けています。戻して写せば正しい位置に自動で入ります", style: .warning), duration: 6)
        }
        if cursorAtStart || cursorAfterID != nil {
            // 差し込み位置は model が管理。表示用の基準ページを更新
            if let cur = model.cursor, cur > 0, cur <= model.records.count {
                cursorAfterID = model.records[cur - 1].id
                cursorAtStart = false
            }
        }
        replaceTargetID = model.replaceTarget
    }

    // MARK: スキップしたページ

    func perform(_ action: Toast.Action, toast: Toast) {
        dismiss(toast)
        switch action {
        case .addSkipped(let pid):
            guard let bookID, let entry = skipped.removeValue(forKey: pid) else { return }
            let (item, dup) = entry
            let at = model.insertForced(item.candidate, newID: item.page.id, after: dup)
            store.insertScannedPage(item.page, into: bookID, at: baseIndex + at)
            lastAddedID = item.page.id
            refreshDerivedState()
        case .showMissingHelp:
            break
        }
    }

    private func expireSkipped(_ pid: UUID) {
        guard let entry = skipped.removeValue(forKey: pid) else { return }
        discard(entry.0.page)
    }

    private func discard(_ page: Page) {
        guard let bookID else { return }
        store.discardFiles(of: page, bookID: bookID)
    }

    // MARK: 帯のページ操作

    /// 撮り直し：次に写したページで差し替える
    func retake(_ id: UUID) {
        model.setReplaceTarget(id)
        replaceTargetID = model.replaceTarget
        // いま写っているのが直前に撮ったそのページなら、すぐ撮れるようにする
        if id == lastAddedID {
            let engine = self.engine
            camera.videoQueue.async { engine.arm() }
        }
    }

    func cancelRetake() {
        model.setReplaceTarget(nil)
        replaceTargetID = nil
    }

    func insertAfter(_ id: UUID) {
        model.setCursor(after: id)
        cursorAfterID = id
        cursorAtStart = false
        currentNumber = model.lastNumber
    }

    func insertAtStart() {
        model.setCursorAtStart()
        cursorAfterID = nil
        cursorAtStart = true
    }

    func endInsertMode() {
        model.setCursor(after: nil)
        cursorAfterID = nil
        cursorAtStart = false
    }

    func delete(_ id: UUID) {
        guard let bookID else { return }
        model.remove(id)
        store.deletePages(bookID: bookID, ids: [id])
        if lastAddedID == id { lastAddedID = model.ids.last }
        if cursorAfterID == id { endInsertMode() }
        refreshDerivedState()
    }

    func undoLast() {
        guard let id = lastAddedID else { return }
        delete(id)
        show(Toast(message: "最後に追加したページを取り消しました", style: .info))
    }

    // MARK: 通知

    func show(_ toast: Toast, duration: Double = 3.5) {
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        let id = toast.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self?.toasts.removeAll { $0.id == id }
        }
    }

    func dismiss(_ toast: Toast) {
        toasts.removeAll { $0.id == toast.id }
    }

    private func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}
