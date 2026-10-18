import SwiftUI
import UIKit

struct ReaderView: View {
    let bookID: UUID

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.readerModeKey) private var modeRaw = ReaderMode.curl.rawValue

    @State private var index: Int
    @State private var showChrome = true
    @State private var sliderValue: Double

    init(bookID: UUID, startIndex: Int) {
        self.bookID = bookID
        _index = State(initialValue: max(startIndex, 0))
        _sliderValue = State(initialValue: Double(max(startIndex, 0)))
    }

    private var mode: ReaderMode { ReaderMode(rawValue: modeRaw) ?? .curl }

    var body: some View {
        Group {
            if let book = store.book(bookID), !book.pages.isEmpty {
                reader(book)
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView("ページがありません", systemImage: "book")
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func reader(_ book: Book) -> some View {
        let count = book.pages.count
        let current = min(index, count - 1)
        ZStack {
            (mode == .curl ? Color(white: 0.16) : Color.black)
                .ignoresSafeArea()

            PageReader(book: book, mode: mode, index: $index) {
                withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
            }
            .id("\(mode.rawValue)-\(book.binding.rawValue)")
            .ignoresSafeArea()

            if showChrome {
                VStack(spacing: 0) {
                    topBar(book, current: current, count: count)
                    Spacer()
                    if count > 1 {
                        bottomBar(book, current: current, count: count)
                    }
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!showChrome)
        .persistentSystemOverlays(showChrome ? .automatic : .hidden)
        .onChange(of: index) { _, newValue in
            sliderValue = Double(newValue)
            store.setLastRead(bookID, newValue)
        }
        .onAppear {
            if index >= count { index = count - 1 }
        }
    }

    private func topBar(_ book: Book, current: Int, count: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(current + 1) / \(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("ページの切り替え", selection: $modeRaw) {
                    ForEach(ReaderMode.allCases) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                Picker("綴じ方向", selection: Binding(
                    get: { book.binding },
                    set: { store.setBinding(bookID, $0) }
                )) {
                    ForEach(BindingDirection.allCases) { b in
                        Text(b.label).tag(b)
                    }
                }
            } label: {
                Image(systemName: "textformat.size")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private func bottomBar(_ book: Book, current: Int, count: Int) -> some View {
        VStack(spacing: 6) {
            Slider(value: $sliderValue, in: 0...Double(count - 1), step: 1, onEditingChanged: { editing in
                if !editing {
                    index = Int(sliderValue.rounded())
                }
            })
            .environment(\.layoutDirection, book.binding == .right ? .rightToLeft : .leftToRight)
            Text("\(Int(sliderValue.rounded()) + 1) ページ")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }
}

// MARK: - UIPageViewController（めくり / スライド）

struct PageReader: UIViewControllerRepresentable {
    let book: Book
    let mode: ReaderMode
    @Binding var index: Int
    var onTapCenter: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let rtl = book.binding == .right
        var options: [UIPageViewController.OptionsKey: Any] = [:]
        let style: UIPageViewController.TransitionStyle
        if mode == .curl {
            style = .pageCurl
            let spine: UIPageViewController.SpineLocation = rtl ? .max : .min
            options[.spineLocation] = NSNumber(value: spine.rawValue)
        } else {
            style = .scroll
            options[.interPageSpacing] = NSNumber(value: 14)
        }
        let pvc = UIPageViewController(transitionStyle: style, navigationOrientation: .horizontal, options: options)
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear
        context.coordinator.pvc = pvc

        let start = min(max(index, 0), max(book.pages.count - 1, 0))
        context.coordinator.currentIndex = start
        pvc.setViewControllers([context.coordinator.makePage(start)], direction: .forward, animated: false)

        // タップでのページ送りは自前で処理する
        for g in pvc.gestureRecognizers where g is UITapGestureRecognizer {
            g.isEnabled = false
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.currentIndex != index && !c.isAnimating {
            c.go(to: index, animated: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageReader
        weak var pvc: UIPageViewController?
        var currentIndex: Int = 0
        var isAnimating = false

        init(_ parent: PageReader) {
            self.parent = parent
        }

        private var count: Int { parent.book.pages.count }
        private var rtl: Bool { parent.book.binding == .right }
        /// スライドモードの右綴じはデータソースの前後を入れ替えて右→左に進める
        private var swapNeighbors: Bool { rtl && parent.mode == .slide }

        func makePage(_ i: Int) -> PageContentController {
            let vc = PageContentController(bookID: parent.book.id,
                                           page: parent.book.pages[i],
                                           index: i,
                                           paper: parent.mode == .curl)
            vc.onTap = { [weak self] region in self?.handleTap(region) }
            vc.onZoomChanged = { [weak self] zoomed in self?.setPagingEnabled(!zoomed) }
            return vc
        }

        private func neighbor(of vc: UIViewController, step: Int) -> UIViewController? {
            guard let pc = vc as? PageContentController else { return nil }
            let n = pc.index + step
            guard n >= 0, n < count else { return nil }
            return makePage(n)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            neighbor(of: viewController, step: swapNeighbors ? 1 : -1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            neighbor(of: viewController, step: swapNeighbors ? -1 : 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            isAnimating = true
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            isAnimating = false
            if completed, let pc = pageViewController.viewControllers?.first as? PageContentController {
                currentIndex = pc.index
                setPagingEnabled(true)
                if parent.index != pc.index {
                    parent.index = pc.index
                }
            }
        }

        func go(to target: Int, animated: Bool) {
            guard let pvc, target >= 0, target < count, target != currentIndex else { return }
            let logicalForward = target > currentIndex
            var direction: UIPageViewController.NavigationDirection = logicalForward ? .forward : .reverse
            if swapNeighbors { direction = logicalForward ? .reverse : .forward }
            currentIndex = target
            isAnimating = animated
            pvc.setViewControllers([makePage(target)], direction: direction, animated: animated) { [weak self] _ in
                self?.isAnimating = false
            }
            if parent.index != target {
                parent.index = target
            }
        }

        func handleTap(_ region: TapRegion) {
            switch region {
            case .center:
                parent.onTapCenter()
            case .left:
                go(to: currentIndex + (rtl ? 1 : -1), animated: true)
            case .right:
                go(to: currentIndex + (rtl ? -1 : 1), animated: true)
            }
        }

        /// 拡大中はページ送りのジェスチャーを止める
        func setPagingEnabled(_ enabled: Bool) {
            guard let pvc else { return }
            for g in pvc.gestureRecognizers where g is UIPanGestureRecognizer {
                g.isEnabled = enabled
            }
            for v in pvc.view.subviews {
                if let sv = v as? UIScrollView { sv.isScrollEnabled = enabled }
            }
        }
    }
}

enum TapRegion {
    case left, center, right
}

/// 1ページ分の表示（ピンチ・ダブルタップで拡大）
final class PageContentController: UIViewController, UIScrollViewDelegate {
    let bookID: UUID
    let page: Page
    let index: Int
    let paper: Bool

    var onTap: ((TapRegion) -> Void)?
    var onZoomChanged: ((Bool) -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let pageLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var wasZoomed = false

    init(bookID: UUID, page: Page, index: Int, paper: Bool) {
        self.bookID = bookID
        self.page = page
        self.index = index
        self.paper = paper
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = paper ? UIColor(white: 0.98, alpha: 1) : .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        scrollView.addSubview(imageView)

        spinner.color = paper ? .darkGray : .lightGray
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        pageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pageLabel.textColor = paper ? UIColor(white: 0.55, alpha: 1) : UIColor(white: 0.6, alpha: 1)
        pageLabel.text = "\(index + 1)"
        pageLabel.textAlignment = .center
        view.addSubview(pageLabel)

        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        single.require(toFail: double)
        view.addGestureRecognizer(double)
        view.addGestureRecognizer(single)

        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let frame = view.bounds.inset(by: UIEdgeInsets(top: safe.top + 8, left: 6, bottom: safe.bottom + 18, right: 6))
        if scrollView.frame != frame {
            scrollView.zoomScale = 1
            scrollView.frame = frame
        }
        if scrollView.zoomScale == 1 {
            imageView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
            scrollView.contentSize = scrollView.bounds.size
        }
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        pageLabel.frame = CGRect(x: 0, y: view.bounds.height - safe.bottom - 18, width: view.bounds.width, height: 16)
    }

    private func load() {
        if let cached = PageImages.cachedDisplay(page) {
            imageView.image = cached
            return
        }
        loadTask?.cancel()
        if let thumb = PageImages.cachedThumbnail(page) {
            imageView.image = thumb
        } else {
            spinner.startAnimating()
        }
        let bookID = self.bookID
        let page = self.page
        loadTask = Task { [weak self] in
            let image = await PageImages.display(bookID: bookID, page: page)
            guard let self, !Task.isCancelled else { return }
            self.spinner.stopAnimating()
            if let image {
                UIView.transition(with: self.imageView, duration: 0.15, options: .transitionCrossDissolve) {
                    self.imageView.image = image
                }
            }
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let zoomed = scrollView.zoomScale > 1.01
        if zoomed != wasZoomed {
            wasZoomed = zoomed
            onZoomChanged?(zoomed)
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let scale: CGFloat = 2.6
            let p = g.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            scrollView.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            onTap?(.center)
            return
        }
        let x = g.location(in: view).x
        let w = view.bounds.width
        if x < w * 0.28 {
            onTap?(.left)
        } else if x > w * 0.72 {
            onTap?(.right)
        } else {
            onTap?(.center)
        }
    }
}
