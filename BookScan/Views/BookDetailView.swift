import SwiftUI

struct BookDetailView: View {
    let bookID: UUID

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var scanTarget: ImportTarget?
    @State private var photoTarget: ImportTarget?
    @State private var reading: ReadTarget?
    @State private var editingPage: PageRef?
    @State private var infoBook: Book?
    @State private var showReorder = false
    @State private var showMerge = false
    @State private var confirmDeleteBook = false
    @State private var pageToDelete: Page?
    @State private var share: ShareItem?
    @State private var busyMessage: String?
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 14, alignment: .top)]

    var body: some View {
        Group {
            if let book = store.book(bookID) {
                content(book)
            } else {
                ContentUnavailableView("本が見つかりません", systemImage: "book")
            }
        }
        .pageImporter(scanTarget: $scanTarget, photoTarget: $photoTarget)
        .fullScreenCover(item: $reading) { target in
            ReaderView(bookID: target.bookID, startIndex: target.index).environment(store)
        }
        .sheet(item: $editingPage) { ref in
            PageEditorView(bookID: ref.bookID, pageID: ref.pageID).environment(store)
        }
        .sheet(item: $infoBook) { book in
            BookInfoSheet(book: book).environment(store)
        }
        .sheet(isPresented: $showReorder) {
            ReorderPagesView(bookID: bookID).environment(store)
        }
        .sheet(isPresented: $showMerge) {
            MergeBooksSheet(targetID: bookID).environment(store)
        }
        .sheet(item: $share) { item in
            ActivityView(items: item.urls)
        }
        .overlay {
            if let busyMessage { BusyOverlay(message: busyMessage) }
        }
        .confirmationDialog("この本を削除しますか？", isPresented: $confirmDeleteBook, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                dismiss()
                let id = bookID
                let library = store
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    library.deleteBook(id)
                }
            }
        } message: {
            Text("スキャン画像もすべて削除されます。この操作は取り消せません。")
        }
        .confirmationDialog("このページを削除しますか？",
                            isPresented: Binding(get: { pageToDelete != nil }, set: { if !$0 { pageToDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pageToDelete) { page in
            Button("ページを削除", role: .destructive) {
                store.deletePages(bookID: bookID, ids: [page.id])
            }
        }
        .alert("エラー", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            if store.pendingInfoEdit == bookID {
                store.pendingInfoEdit = nil
                infoBook = store.book(bookID)
            }
        }
    }

    @ViewBuilder
    private func content(_ book: Book) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(book)
                if book.pages.isEmpty {
                    ContentUnavailableView {
                        Label("ページがありません", systemImage: "doc")
                    } description: {
                        Text("スキャンしてページを追加してください。")
                    } actions: {
                        Button("スキャン") { scanTarget = ImportTarget(bookID: bookID) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    pagesGrid(book)
                }
            }
            .padding(.vertical)
            .padding(.bottom, 70)
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                moreMenu(book)
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar(book)
        }
    }

    // MARK: - ヘッダー

    private func header(_ book: Book) -> some View {
        HStack(alignment: .top, spacing: 18) {
            BookCoverView(book: book)
                .frame(width: 112)
                .onTapGesture {
                    if !book.pages.isEmpty { reading = ReadTarget(bookID: book.id, index: 0) }
                }

            VStack(alignment: .leading, spacing: 8) {
                Text(book.title)
                    .font(.title3.bold())
                    .lineLimit(3)
                if !book.author.isEmpty {
                    Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if !book.shelf.isEmpty {
                        Text(book.shelf)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                    Text("\(book.pages.count)ページ・\(book.binding.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if store.ocrRunning.contains(book.id) {
                    Label("文字認識中 \(book.ocrDoneCount)/\(book.pages.count)", systemImage: "text.viewfinder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse)
                }
                Spacer(minLength: 0)
                Button {
                    infoBook = book
                } label: {
                    Label("情報を編集", systemImage: "pencil")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - ページ一覧

    private func pagesGrid(_ book: Book) -> some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(Array(book.pages.enumerated()), id: \.element.id) { i, page in
                Button {
                    reading = ReadTarget(bookID: book.id, index: i)
                } label: {
                    PageCell(bookID: book.id, page: page, number: i + 1, isCover: book.coverPage?.id == page.id)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    pageMenu(book: book, page: page, index: i)
                } preview: {
                    PageThumbnail(bookID: book.id, page: page)
                        .frame(width: 300, height: 400)
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func pageMenu(book: Book, page: Page, index i: Int) -> some View {
        Button {
            editingPage = PageRef(bookID: book.id, pageID: page.id)
        } label: {
            Label("補正・回転・テキスト", systemImage: "slider.horizontal.3")
        }
        Button {
            store.rotate(bookID: book.id, pageID: page.id, by: -1)
        } label: {
            Label("左に回転", systemImage: "rotate.left")
        }
        Button {
            store.rotate(bookID: book.id, pageID: page.id, by: 1)
        } label: {
            Label("右に回転", systemImage: "rotate.right")
        }
        Divider()
        Button {
            scanTarget = ImportTarget(bookID: book.id, insertAt: i + 1)
        } label: {
            Label("この後ろにスキャンを挿入", systemImage: "doc.viewfinder")
        }
        Button {
            scanTarget = ImportTarget(bookID: book.id, insertAt: i, replacing: page.id)
        } label: {
            Label("撮り直して差し替え", systemImage: "arrow.triangle.2.circlepath.camera")
        }
        Button {
            photoTarget = ImportTarget(bookID: book.id, insertAt: i + 1)
        } label: {
            Label("この後ろに写真を挿入", systemImage: "photo")
        }
        Button {
            store.setCover(book.id, pageID: page.id)
        } label: {
            Label("表紙に設定", systemImage: "star")
        }
        Divider()
        Button(role: .destructive) {
            pageToDelete = page
        } label: {
            Label("ページを削除", systemImage: "trash")
        }
    }

    // MARK: - メニュー

    private func moreMenu(_ book: Book) -> some View {
        Menu {
            Section {
                Button {
                    scanTarget = ImportTarget(bookID: book.id)
                } label: {
                    Label("スキャンして追加", systemImage: "doc.viewfinder")
                }
                Button {
                    photoTarget = ImportTarget(bookID: book.id)
                } label: {
                    Label("写真から追加", systemImage: "photo.on.rectangle")
                }
            }
            Section {
                Button {
                    infoBook = book
                } label: {
                    Label("情報を編集", systemImage: "pencil")
                }
                Button {
                    showReorder = true
                } label: {
                    Label("並べ替え・まとめて削除", systemImage: "arrow.up.arrow.down")
                }
                .disabled(book.pages.isEmpty)
                Menu {
                    ForEach(PageFilter.allCases) { f in
                        Button {
                            store.applyFilterToAll(bookID: book.id, filter: f)
                        } label: {
                            Label(f.label, systemImage: f.symbol)
                        }
                    }
                } label: {
                    Label("全ページの補正を変更", systemImage: "wand.and.stars")
                }
                .disabled(book.pages.isEmpty)
                Button {
                    showMerge = true
                } label: {
                    Label("ほかの本をこの本に結合", systemImage: "rectangle.stack.badge.plus")
                }
                .disabled(store.books.count < 2)
            }
            Section {
                Menu {
                    Button {
                        export(.pdf, book: book)
                    } label: {
                        Label("PDF（文字検索可能）", systemImage: "doc.richtext")
                    }
                    Button {
                        export(.images, book: book)
                    } label: {
                        Label("画像（JPEG）", systemImage: "photo.stack")
                    }
                    Button {
                        export(.text, book: book)
                    } label: {
                        Label("テキスト", systemImage: "doc.text")
                    }
                } label: {
                    Label("書き出し・共有", systemImage: "square.and.arrow.up")
                }
                .disabled(book.pages.isEmpty)
            }
            Section {
                Button {
                    store.redoOCR(bookID: book.id)
                } label: {
                    Label("文字認識をやり直す", systemImage: "text.viewfinder")
                }
                .disabled(book.pages.isEmpty)
                Button(role: .destructive) {
                    confirmDeleteBook = true
                } label: {
                    Label("本を削除", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func bottomBar(_ book: Book) -> some View {
        HStack(spacing: 12) {
            Button {
                scanTarget = ImportTarget(bookID: book.id)
            } label: {
                Label("スキャン追加", systemImage: "doc.viewfinder")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)

            Button {
                let start = min(book.lastReadIndex, max(book.pages.count - 1, 0))
                reading = ReadTarget(bookID: book.id, index: start)
            } label: {
                Label(book.lastReadIndex > 0 ? "続きから読む" : "読む", systemImage: "book")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(book.pages.isEmpty)
        }
        .font(.headline)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 書き出し

    private enum ExportKind { case pdf, images, text }

    private func export(_ kind: ExportKind, book: Book) {
        busyMessage = kind == .pdf ? "PDFを作成中…" : "書き出し中…"
        Task {
            do {
                let urls: [URL]
                switch kind {
                case .pdf: urls = [try await Exporter.pdf(book: book)]
                case .images: urls = try await Exporter.images(book: book)
                case .text: urls = [try Exporter.text(book: book)]
                }
                busyMessage = nil
                share = ShareItem(urls: urls)
            } catch {
                busyMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct PageCell: View {
    let bookID: UUID
    let page: Page
    let number: Int
    let isCover: Bool

    var body: some View {
        VStack(spacing: 6) {
            Color(.secondarySystemBackground)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    PageThumbnail(bookID: bookID, page: page)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                .overlay(alignment: .topTrailing) {
                    if isCover {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Color.accentColor, in: Circle())
                            .padding(4)
                    }
                }
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 本の情報

struct BookInfoSheet: View {
    let book: Book
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var author: String
    @State private var shelf: String
    @State private var binding: BindingDirection

    init(book: Book) {
        self.book = book
        _title = State(initialValue: book.title)
        _author = State(initialValue: book.author)
        _shelf = State(initialValue: book.shelf)
        _binding = State(initialValue: book.binding)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("タイトル") {
                    TextField("タイトル", text: $title)
                }
                Section("著者・メモ") {
                    TextField("任意", text: $author)
                }
                Section {
                    TextField("例：漫画、教科書、取扱説明書", text: $shelf)
                    if !store.shelves.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(store.shelves, id: \.self) { s in
                                    Button(s) { shelf = s }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .tint(shelf == s ? .accentColor : .secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("本棚（分類）")
                }
                Section {
                    Picker("綴じ方向", selection: $binding) {
                        ForEach(BindingDirection.allCases) { b in
                            Text(b.label).tag(b)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("綴じ方向")
                } footer: {
                    Text(binding.detail)
                }
            }
            .navigationTitle("本の情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.updateInfo(book.id, title: title, author: author, shelf: shelf, binding: binding)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 並べ替え

struct ReorderPagesView: View {
    let bookID: UUID
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<UUID>()
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Group {
                if let book = store.book(bookID) {
                    List(selection: $selection) {
                        ForEach(Array(book.pages.enumerated()), id: \.element.id) { i, page in
                            HStack(spacing: 14) {
                                PageThumbnail(bookID: bookID, page: page)
                                    .frame(width: 44, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                Text("\(i + 1) ページ")
                                    .font(.body.monospacedDigit())
                                Spacer()
                                if book.coverPage?.id == page.id {
                                    Image(systemName: "star.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                            .tag(page.id)
                        }
                        .onMove { from, to in
                            store.movePages(bookID: bookID, from: from, to: to)
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.map { book.pages[$0].id })
                            store.deletePages(bookID: bookID, ids: ids)
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("並べ替え")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }.bold()
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        store.reversePages(bookID: bookID)
                    } label: {
                        Label("順番を反転", systemImage: "arrow.uturn.backward")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Text(selection.isEmpty ? "削除" : "\(selection.count)ページを削除")
                    }
                    .disabled(selection.isEmpty)
                }
            }
            .confirmationDialog("選択した \(selection.count) ページを削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    store.deletePages(bookID: bookID, ids: selection)
                    selection.removeAll()
                }
            }
        }
    }
}

// MARK: - 結合

struct MergeBooksSheet: View {
    let targetID: UUID
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pending: Book?

    var body: some View {
        NavigationStack {
            List(store.books.filter { $0.id != targetID }) { book in
                Button {
                    pending = book
                } label: {
                    HStack(spacing: 14) {
                        BookCoverView(book: book).frame(width: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(book.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                            Text("\(book.pages.count)ページ").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("結合する本を選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .confirmationDialog("結合しますか？",
                                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible,
                                presenting: pending) { book in
                Button("「\(book.title)」を末尾に結合") {
                    store.merge(book.id, into: targetID)
                    dismiss()
                }
            } message: { book in
                Text("「\(book.title)」の \(book.pages.count) ページをこの本の末尾に移し、元の本は本棚から消えます。")
            }
        }
    }
}
