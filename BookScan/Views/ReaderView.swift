import SwiftUI
import UIKit
import VisionKit

struct ReaderView: View {
    let bookID: UUID

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.readerModeKey) private var modeRaw = ReaderMode.curl.rawValue
    @AppStorage(AppSettings.spreadModeKey) private var spreadRaw = SpreadMode.auto.rawValue
    @AppStorage(AppSettings.coverAloneKey) private var coverAlone = true

    @State private var index: Int
    @State private var showChrome = true
    @State private var sliderValue: Double
    @State private var highlight: String?
    @State private var showSearch = false
    @State private var showPages = false

    init(bookID: UUID, startIndex: Int, highlight: String? = nil) {
        self.bookID = bookID
        _index = State(initialValue: max(startIndex, 0))
        _sliderValue = State(initialValue: Double(max(startIndex, 0)))
        _highlight = State(initialValue: highlight)
    }

    private var mode: ReaderMode { ReaderMode(rawValue: modeRaw) ?? .curl }
    private var spreadMode: SpreadMode { SpreadMode(rawValue: spreadRaw) ?? .auto }

    var body: some View {
        Group {
            if let book = store.book(bookID), !book.pages.isEmpty {
                GeometryReader { geo in
                    reader(book, twoUp: twoUp(for: geo.size))
                }
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView("ページがありません", systemImage: "book")
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            BookSearchSheet(bookID: bookID) { page, query in
                highlight = query
                index = page
            }
            .environment(store)
        }
        .sheet(isPresented: $showPages) {
            PageListSheet(bookID: bookID, current: index) { page in
                index = page
            }
            .environment(store)
        }
    }

    private func twoUp(for size: CGSize) -> Bool {
        switch spreadMode {
        case .single: return false
        case .double: return true
        case .auto: return size.width > size.height * 1.05
        }
    }

    @ViewBuilder
    private func reader(_ book: Book, twoUp: Bool) -> some View {
        let count = book.pages.count
        let current = min(index, count - 1)
        ZStack {
            (mode == .curl ? Color(white: 0.16) : Color.black)
                .ignoresSafeArea()

            PageReader(book: book, mode: mode, twoUp: twoUp, coverAlone: coverAlone,
                       highlight: highlight, index: $index) {
                withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
            }
            .id("\(mode.rawValue)-\(book.binding.rawValue)-\(twoUp)-\(coverAlone)")
            .ignoresSafeArea()

            if showChrome {
                VStack(spacing: 0) {
                    topBar(book, current: current, count: count)
                    if let highlight {
                        highlightBar(book, query: highlight, current: current)
                    }
                    Spacer()
                    if count > 1 {
                        bottomBar(book, count: count)
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
            store.markOpened(bookID)
        }
    }

    // MARK: - 上部バー

    private func topBar(_ book: Book, current: Int, count: Int) -> some View {
        let bookmarked = book.isBookmarked(book.pages[current].id)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                barButton("xmark") { dismiss() }
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(current + 1) / \(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                barButton("magnifyingglass") { showSearch = true }
                barButton("square.grid.2x2") { showPages = true }
                barButton(bookmarked ? "bookmark.fill" : "bookmark", tint: bookmarked ? .red : nil) {
                    store.toggleBookmark(bookID, pageID: book.pages[current].id)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                settingsMenu(book)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }

    private func barButton(_ symbol: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint ?? Color.primary)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
    }

    private func settingsMenu(_ book: Book) -> some View {
        Menu {
            Picker("ページの切り替え", selection: $modeRaw) {
                ForEach(ReaderMode.allCases) { m in
                    Text(m.label).tag(m.rawValue)
                }
            }
            Picker("見開き", selection: $spreadRaw) {
                ForEach(SpreadMode.allCases) { m in
                    Text(m.label).tag(m.rawValue)
                }
            }
            Toggle("見開きで表紙を単独表示", isOn: $coverAlone)
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
                .foregroundStyle(Color.primary)
                .frame(width: 38, height: 38)
        }
    }

    // MARK: - 検索ハイライト

    private func matchingPages(_ book: Book, query: String) -> [Int] {
        book.pages.indices.filter {
            book.pages[$0].text.range(of: query, options: [.caseInsensitive, .widthInsensitive]) != nil
        }
    }

    private func highlightBar(_ book: Book, query: String, current: Int) -> some View {
        let matches = matchingPages(book, query: query)
        let prev = matches.last { $0 < current }
        let next = matches.first { $0 > current }
        return HStack(spacing: 10) {
            Image(systemName: "highlighter").foregroundStyle(.yellow)
            Text("「\(query)」 \(matches.count)ページ")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            Spacer()
            Button {
                if let prev { index = prev }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(prev == nil)
            Button {
                if let next { index = next }
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(next == nil)
            Button {
                highlight = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    // MARK: - 下部バー

    private func bottomBar(_ book: Book, count: Int) -> some View {
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

// MARK: - 本の中を検索

struct BookSearchSheet: View {
    let bookID: UUID
    var onSelect: (Int, String) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Hit: Identifiable {
        let id: UUID
        let index: Int
        let snippet: String
    }

    private func hits(_ book: Book, _ q: String) -> [Hit] {
        guard !q.isEmpty else { return [] }
        var out: [Hit] = []
        for (i, page) in book.pages.enumerated() {
            let text = page.text
            guard let r = text.range(of: q, options: [.caseInsensitive, .widthInsensitive]) else { continue }
            let start = text.index(r.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(r.upperBound, offsetBy: 36, limitedBy: text.endIndex) ?? text.endIndex
            let snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
            out.append(Hit(id: page.id, index: i, snippet: snippet))
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Group {
                if let book = store.book(bookID) {
                    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    let results = hits(book, q)
                    List {
                        if !q.isEmpty && results.isEmpty {
                            Text(book.ocrDoneCount < book.pages.count
                                 ? "見つかりません（文字認識が終わっていないページがあります）"
                                 : "見つかりません")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(results) { hit in
                            Button {
                                onSelect(hit.index, q)
                                dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    PageThumbnail(bookID: bookID, page: book.pages[hit.index])
                                        .frame(width: 40, height: 54)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(hit.index + 1) ページ")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Text(highlighted(hit.snippet, q))
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(3)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "この本の中を検索")
            .navigationTitle("本文を検索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func highlighted(_ s: String, _ q: String) -> AttributedString {
        var attr = AttributedString(s)
        if let r = attr.range(of: q, options: [.caseInsensitive, .widthInsensitive]) {
            attr[r].backgroundColor = .yellow.opacity(0.4)
            attr[r].font = .subheadline.bold()
        }
        return attr
    }
}

// MARK: - ページ一覧・しおり

struct PageListSheet: View {
    let bookID: UUID
    let current: Int
    var onSelect: (Int) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var onlyBookmarks = false

    var body: some View {
        NavigationStack {
            Group {
                if let book = store.book(bookID) {
                    let indices = book.pages.indices.filter { !onlyBookmarks || book.isBookmarked(book.pages[$0].id) }
                    ScrollViewReader { proxy in
                        ScrollView {
                            if indices.isEmpty {
                                ContentUnavailableView("しおりはありません",
                                                       systemImage: "bookmark",
                                                       description: Text("読書中に右上のしおりボタンで挟めます。"))
                                    .padding(.top, 40)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 12)], spacing: 16) {
                                ForEach(indices, id: \.self) { i in
                                    let page = book.pages[i]
                                    Button {
                                        onSelect(i)
                                        dismiss()
                                    } label: {
                                        VStack(spacing: 5) {
                                            Color(.secondarySystemBackground)
                                                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                                .overlay { PageThumbnail(bookID: bookID, page: page) }
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .strokeBorder(i == current ? Color.accentColor : Color.clear, lineWidth: 3)
                                                )
                                                .overlay(alignment: .topLeading) {
                                                    if book.isBookmarked(page.id) {
                                                        Image(systemName: "bookmark.fill")
                                                            .foregroundStyle(.red)
                                                            .offset(x: 5, y: -2)
                                                    }
                                                }
                                            Text("\(i + 1)")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(i == current ? Color.accentColor : Color.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .id(i)
                                }
                            }
                            .padding()
                        }
                        .onAppear { proxy.scrollTo(current, anchor: .center) }
                    }
                }
            }
            .navigationTitle("ページ一覧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $onlyBookmarks) {
                        Text("すべて").tag(false)
                        Text("しおり").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

// MARK: - UIPageViewController（めくり / スライド、見開き対応）

enum SpreadLayout {
    static func spreads(count: Int, twoUp: Bool, coverAlone: Bool) -> [[Int]] {
        guard count > 0 else { return [] }
        guard twoUp else { return (0..<count).map { [$0] } }
        var result: [[Int]] = []
        var i = 0
        if coverAlone {
            result.append([0])
            i = 1
        }
        while i < count {
            if i + 1 < count {
                result.append([i, i + 1])
            } else {
                result.append([i])
            }
            i += 2
        }
        return result
    }
}

struct PageReader: UIViewControllerRepresentable {
    let book: Book
    let mode: ReaderMode
    let twoUp: Bool
    let coverAlone: Bool
    let highlight: String?
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

        let c = context.coordinator
        c.pvc = pvc
        c.rebuildSpreads()
        c.currentSpread = c.spreadIndex(forPage: index)
        c.appliedHighlight = highlight
        pvc.setViewControllers([c.makeSpread(c.currentSpread)], direction: .forward, animated: false)

        // タップでのページ送りは自前で処理する
        for g in pvc.gestureRecognizers where g is UITapGestureRecognizer {
            g.isEnabled = false
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.spreads.flatMap({ $0 }).count != book.pages.count {
            c.rebuildSpreads()
        }
        if c.appliedHighlight != highlight {
            c.appliedHighlight = highlight
            for vc in pvc.viewControllers ?? [] {
                (vc as? SpreadController)?.setHighlight(highlight)
            }
        }
        if !c.isAnimating, c.spreads.indices.contains(c.currentSpread), !c.spreads[c.currentSpread].contains(index) {
            c.go(toSpread: c.spreadIndex(forPage: index), animated: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageReader
        weak var pvc: UIPageViewController?
        var spreads: [[Int]] = []
        var currentSpread = 0
        var isAnimating = false
        var appliedHighlight: String?

        init(_ parent: PageReader) {
            self.parent = parent
        }

        private var rtl: Bool { parent.book.binding == .right }
        /// スライドモードの右綴じはデータソースの前後を入れ替えて右→左に進める
        private var swapNeighbors: Bool { rtl && parent.mode == .slide }

        func rebuildSpreads() {
            spreads = SpreadLayout.spreads(count: parent.book.pages.count, twoUp: parent.twoUp, coverAlone: parent.coverAlone)
        }

        func spreadIndex(forPage page: Int) -> Int {
            spreads.firstIndex { $0.contains(page) } ?? max(0, min(spreads.count - 1, page))
        }

        func makeSpread(_ s: Int) -> SpreadController {
            let indices = spreads[s]
            let pages = indices.map { parent.book.pages[$0] }
            let vc = SpreadController(bookID: parent.book.id,
                                      pages: pages,
                                      pageNumbers: indices.map { $0 + 1 },
                                      spreadIndex: s,
                                      rtl: rtl,
                                      twoUp: parent.twoUp,
                                      paper: parent.mode == .curl,
                                      highlight: parent.highlight)
            vc.onTap = { [weak self] region in self?.handleTap(region) }
            vc.onZoomChanged = { [weak self] zoomed in self?.setPagingEnabled(!zoomed) }
            return vc
        }

        private func neighbor(of vc: UIViewController, step: Int) -> UIViewController? {
            guard let sc = vc as? SpreadController else { return nil }
            let n = sc.spreadIndex + step
            guard n >= 0, n < spreads.count else { return nil }
            return makeSpread(n)
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
            if completed, let sc = pageViewController.viewControllers?.first as? SpreadController {
                currentSpread = sc.spreadIndex
                setPagingEnabled(true)
                let first = spreads[sc.spreadIndex][0]
                if parent.index != first {
                    parent.index = first
                }
            }
        }

        func go(toSpread target: Int, animated: Bool) {
            guard let pvc, target >= 0, target < spreads.count, target != currentSpread else { return }
            let logicalForward = target > currentSpread
            var direction: UIPageViewController.NavigationDirection = logicalForward ? .forward : .reverse
            if swapNeighbors { direction = logicalForward ? .reverse : .forward }
            currentSpread = target
            isAnimating = animated
            pvc.setViewControllers([makeSpread(target)], direction: direction, animated: animated) { [weak self] _ in
                self?.isAnimating = false
            }
            if !spreads[target].contains(parent.index) {
                parent.index = spreads[target][0]
            }
        }

        func handleTap(_ region: TapRegion) {
            switch region {
            case .center:
                parent.onTapCenter()
            case .left:
                go(toSpread: currentSpread + (rtl ? 1 : -1), animated: true)
            case .right:
                go(toSpread: currentSpread + (rtl ? -1 : 1), animated: true)
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

// MARK: - 見開き（1〜2ページ）をまとめて表示するコンテナ

final class SpreadController: UIViewController {
    let bookID: UUID
    let pages: [Page]
    let pageNumbers: [Int]
    let spreadIndex: Int
    let rtl: Bool
    let twoUp: Bool
    let paper: Bool

    var onTap: ((TapRegion) -> Void)?
    var onZoomChanged: ((Bool) -> Void)?

    private var children_: [PageContentController] = []
    private var labels: [UILabel] = []
    private var aspects: [CGFloat] = []
    private let gutterShadow = CAGradientLayer()
    private var highlight: String?

    init(bookID: UUID, pages: [Page], pageNumbers: [Int], spreadIndex: Int,
         rtl: Bool, twoUp: Bool, paper: Bool, highlight: String?) {
        self.bookID = bookID
        self.pages = pages
        self.pageNumbers = pageNumbers
        self.spreadIndex = spreadIndex
        self.rtl = rtl
        self.twoUp = twoUp
        self.paper = paper
        self.highlight = highlight
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 画面上の左→右の順
    private var displayOrder: [Int] {
        let idx = Array(pages.indices)
        return rtl ? idx.reversed() : idx
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = paper ? UIColor(white: 0.98, alpha: 1) : .black

        for (i, page) in pages.enumerated() {
            let size = ImageIOHelper.displaySize(bookID: bookID, page: page) ?? CGSize(width: 3, height: 4)
            aspects.append(size.height > 0 ? size.width / size.height : 0.75)

            let child = PageContentController(bookID: bookID, page: page, highlight: highlight)
            addChild(child)
            view.addSubview(child.view)
            child.didMove(toParent: self)
            child.onSingleTap = { [weak self] g, zoomed in
                guard let self else { return }
                if zoomed { self.onTap?(.center); return }
                let x = g.location(in: self.view).x
                let w = self.view.bounds.width
                if x < w * 0.28 {
                    self.onTap?(.left)
                } else if x > w * 0.72 {
                    self.onTap?(.right)
                } else {
                    self.onTap?(.center)
                }
            }
            child.onZoomChanged = { [weak self] zoomed in self?.onZoomChanged?(zoomed) }
            children_.append(child)

            let label = UILabel()
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = paper ? UIColor(white: 0.55, alpha: 1) : UIColor(white: 0.6, alpha: 1)
            label.textAlignment = .center
            label.text = "\(pageNumbers[i])"
            view.addSubview(label)
            labels.append(label)
        }

        if pages.count == 2 {
            gutterShadow.colors = [UIColor.black.withAlphaComponent(0).cgColor,
                                   UIColor.black.withAlphaComponent(paper ? 0.16 : 0.3).cgColor,
                                   UIColor.black.withAlphaComponent(0).cgColor]
            gutterShadow.startPoint = CGPoint(x: 0, y: 0.5)
            gutterShadow.endPoint = CGPoint(x: 1, y: 0.5)
            view.layer.addSublayer(gutterShadow)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let area = view.bounds.inset(by: UIEdgeInsets(top: safe.top + 8, left: safe.left + 6,
                                                      bottom: safe.bottom + 20, right: safe.right + 6))
        guard area.width > 0, area.height > 0 else { return }

        if pages.count == 2 {
            let halfW = area.width / 2
            var frames: [CGRect] = []
            for (slot, i) in displayOrder.enumerated() {
                let a = aspects[i]
                var w = halfW
                var h = w / a
                if h > area.height {
                    h = area.height
                    w = h * a
                }
                let x = slot == 0 ? area.midX - w : area.midX
                frames.append(CGRect(x: x, y: area.midY - h / 2, width: w, height: h))
                setFrame(children_[i].view, frames.last!)
                labels[i].frame = CGRect(x: x, y: view.bounds.height - safe.bottom - 18, width: w, height: 16)
            }
            let top = frames.map(\.minY).min() ?? area.minY
            let bottom = frames.map(\.maxY).max() ?? area.maxY
            gutterShadow.frame = CGRect(x: area.midX - 14, y: top, width: 28, height: bottom - top)
        } else if let child = children_.first {
            setFrame(child.view, area)
            labels.first?.frame = CGRect(x: 0, y: view.bounds.height - safe.bottom - 18, width: view.bounds.width, height: 16)
        }
    }

    private func setFrame(_ v: UIView, _ frame: CGRect) {
        if v.frame != frame { v.frame = frame }
    }

    func setHighlight(_ query: String?) {
        highlight = query
        for c in children_ { c.setHighlight(query) }
    }
}

// MARK: - 1ページ分の表示（拡大・Live Text・検索ハイライト）

final class PageContentController: UIViewController, UIScrollViewDelegate {
    let bookID: UUID
    let page: Page

    var onSingleTap: ((UITapGestureRecognizer, Bool) -> Void)?
    var onZoomChanged: ((Bool) -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let highlightLayer = CALayer()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var loadTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var wasZoomed = false
    private var highlight: String?
    private var liveTextAttached = false

    private static let analyzer = ImageAnalyzer()
    private lazy var interaction = ImageAnalysisInteraction()

    init(bookID: UUID, page: Page, highlight: String?) {
        self.bookID = bookID
        self.page = page
        self.highlight = highlight
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.clipsToBounds = false
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.layer.addSublayer(highlightLayer)
        scrollView.addSubview(imageView)

        spinner.color = .gray
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

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
        if scrollView.frame != view.bounds {
            scrollView.zoomScale = 1
            scrollView.frame = view.bounds
        }
        if scrollView.zoomScale == 1 {
            imageView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
            scrollView.contentSize = scrollView.bounds.size
        }
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        layoutHighlights()
    }

    private func load() {
        if let cached = PageImages.cachedDisplay(page) {
            imageView.image = cached
            attachLiveText(cached)
            return
        }
        if let thumb = PageImages.cachedThumbnail(page) {
            imageView.image = thumb
        } else {
            spinner.startAnimating()
        }
        loadTask?.cancel()
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
                self.layoutHighlights()
                self.attachLiveText(image)
            }
        }
    }

    // MARK: Live Text（長押しで文字を選択・コピー・翻訳）

    private func attachLiveText(_ image: UIImage) {
        guard AppSettings.liveText, ImageAnalyzer.isSupported, !liveTextAttached else { return }
        liveTextAttached = true
        imageView.addInteraction(interaction)
        interaction.preferredInteractionTypes = []
        analysisTask = Task { [weak self] in
            let configuration = ImageAnalyzer.Configuration([.text])
            let analysis = try? await PageContentController.analyzer.analyze(image, configuration: configuration)
            guard let self, !Task.isCancelled, let analysis else { return }
            self.interaction.analysis = analysis
            self.interaction.preferredInteractionTypes = .textSelection
        }
    }

    // MARK: 検索ハイライト

    func setHighlight(_ query: String?) {
        highlight = query
        layoutHighlights()
    }

    private func layoutHighlights() {
        highlightLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let q = highlight, !q.isEmpty,
              page.hasValidOCR, let lines = page.ocrLines,
              let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        let bounds = imageView.bounds
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        let rect = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        highlightLayer.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for line in lines where line.text.range(of: q, options: [.caseInsensitive, .widthInsensitive]) != nil {
            let box = CALayer()
            box.frame = CGRect(x: rect.minX + line.x * rect.width,
                               y: rect.minY + line.y * rect.height,
                               width: line.w * rect.width,
                               height: line.h * rect.height).insetBy(dx: -2, dy: -2)
            box.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.38).cgColor
            box.borderColor = UIColor.systemOrange.withAlphaComponent(0.7).cgColor
            box.borderWidth = 1
            box.cornerRadius = 3
            highlightLayer.addSublayer(box)
        }
        CATransaction.commit()
    }

    // MARK: 拡大

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
        if interaction.hasActiveTextSelection {
            interaction.resetSelection()
            return
        }
        onSingleTap?(g, scrollView.zoomScale > 1.01)
    }
}
