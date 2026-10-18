import SwiftUI

struct LibraryView: View {
    @Environment(LibraryStore.self) private var store

    @State private var path: [UUID] = []
    @State private var query = ""
    @State private var scanTarget: ImportTarget?
    @State private var photoTarget: ImportTarget?
    @State private var showSettings = false
    @State private var editingBook: Book?
    @State private var deletingBook: Book?
    @State private var reading: ReadTarget?
    @State private var share: ShareItem?
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @AppStorage(AppSettings.librarySortKey) private var sortRaw = LibrarySort.updated.rawValue

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .updated }

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 18, alignment: .top)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if trimmedQuery.isEmpty {
                    shelvesView
                } else {
                    SearchResultsView(query: trimmedQuery,
                                      openBook: { path.append($0) },
                                      openPage: { reading = ReadTarget(bookID: $0, index: $1) })
                }
            }
            .navigationTitle("本棚")
            .searchable(text: $query, prompt: "タイトル・本文を検索")
            .toolbar { toolbarContent }
            .navigationDestination(for: UUID.self) { id in
                BookDetailView(bookID: id)
            }
            .overlay {
                if store.books.isEmpty && trimmedQuery.isEmpty {
                    emptyState
                }
            }
            .safeAreaInset(edge: .bottom) {
                if path.isEmpty && trimmedQuery.isEmpty {
                    scanButton
                }
            }
        }
        .overlay(alignment: .top) {
            if let p = store.importProgress {
                ImportProgressBanner(progress: p)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if let busyMessage { BusyOverlay(message: busyMessage) }
        }
        .animation(.spring(duration: 0.3), value: store.importProgress)
        .pageImporter(scanTarget: $scanTarget, photoTarget: $photoTarget) { id, isNew in
            if isNew {
                store.pendingInfoEdit = id
                path = [id]
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(store)
        }
        .sheet(item: $editingBook) { book in
            BookInfoSheet(book: book).environment(store)
        }
        .sheet(item: $share) { item in
            ActivityView(items: item.urls)
        }
        .fullScreenCover(item: $reading) { target in
            ReaderView(bookID: target.bookID, startIndex: target.index).environment(store)
        }
        .confirmationDialog("この本を削除しますか？",
                            isPresented: Binding(get: { deletingBook != nil }, set: { if !$0 { deletingBook = nil } }),
                            titleVisibility: .visible,
                            presenting: deletingBook) { book in
            Button("「\(book.title)」を削除", role: .destructive) { store.deleteBook(book.id) }
        } message: { book in
            Text("\(book.pages.count) ページのスキャン画像も削除されます。この操作は取り消せません。")
        }
        .alert("エラー", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - 本棚

    private struct ShelfGroup: Identifiable {
        let name: String
        let books: [Book]
        var id: String { name }
    }

    private var sortedBooks: [Book] {
        switch sort {
        case .updated: return store.books.sorted { $0.updatedAt > $1.updatedAt }
        case .created: return store.books.sorted { $0.createdAt > $1.createdAt }
        case .title: return store.books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    private var groups: [ShelfGroup] {
        let books = sortedBooks
        let named = store.shelves
        if named.isEmpty { return [ShelfGroup(name: "", books: books)] }
        var result = named.map { name in ShelfGroup(name: name, books: books.filter { $0.shelf == name }) }
        let unfiled = books.filter { $0.shelf.isEmpty }
        if !unfiled.isEmpty { result.append(ShelfGroup(name: "未分類", books: unfiled)) }
        return result.filter { !$0.books.isEmpty }
    }

    private var shelvesView: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 14) {
                    if !group.name.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.name).font(.title3.bold())
                            Text("\(group.books.count)冊").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(group.books) { book in
                            NavigationLink(value: book.id) {
                                BookCell(book: book)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { bookMenu(book) }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.bottom, 80)
    }

    @ViewBuilder
    private func bookMenu(_ book: Book) -> some View {
        Button {
            reading = ReadTarget(bookID: book.id, index: min(book.lastReadIndex, max(book.pages.count - 1, 0)))
        } label: {
            Label("読む", systemImage: "book")
        }
        .disabled(book.pages.isEmpty)
        Button {
            scanTarget = ImportTarget(bookID: book.id, insertAt: nil)
        } label: {
            Label("スキャンして追加", systemImage: "doc.viewfinder")
        }
        Button {
            editingBook = book
        } label: {
            Label("情報を編集", systemImage: "pencil")
        }
        Button {
            exportPDF(book)
        } label: {
            Label("PDFで共有", systemImage: "square.and.arrow.up")
        }
        .disabled(book.pages.isEmpty)
        Divider()
        Button(role: .destructive) {
            deletingBook = book
        } label: {
            Label("削除", systemImage: "trash")
        }
    }

    private func exportPDF(_ book: Book) {
        busyMessage = "PDFを作成中…"
        Task {
            do {
                let url = try await Exporter.pdf(book: book)
                busyMessage = nil
                share = ShareItem(urls: [url])
            } catch {
                busyMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - ツールバーなど

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("並び順", selection: $sortRaw) {
                    ForEach(LibrarySort.allCases) { s in
                        Text(s.label).tag(s.rawValue)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            Menu {
                Button {
                    scanTarget = ImportTarget()
                } label: {
                    Label("カメラでスキャン", systemImage: "doc.viewfinder")
                }
                Button {
                    photoTarget = ImportTarget()
                } label: {
                    Label("写真から取り込み", systemImage: "photo.on.rectangle")
                }
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    private var scanButton: some View {
        HStack(spacing: 12) {
            Button {
                scanTarget = ImportTarget()
            } label: {
                Label("新しくスキャン", systemImage: "doc.viewfinder")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .shadow(color: .accentColor.opacity(0.35), radius: 10, y: 4)

            Button {
                photoTarget = ImportTarget()
            } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.headline)
                    .padding(14)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .background(.regularMaterial, in: Circle())
        }
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("本棚は空です", systemImage: "books.vertical")
        } description: {
            Text("「新しくスキャン」でページを連続撮影すると、1冊の本としてまとまります。")
        }
    }
}

struct BookCell: View {
    let book: Book
    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            BookCoverView(book: book)
            Text(book.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 4) {
                Text("\(book.pages.count)ページ")
                if store.ocrRunning.contains(book.id) {
                    Image(systemName: "text.viewfinder")
                        .symbolEffect(.pulse)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 検索

struct SearchResultsView: View {
    let query: String
    var openBook: (UUID) -> Void
    var openPage: (UUID, Int) -> Void

    @Environment(LibraryStore.self) private var store

    private struct Hit: Identifiable {
        let id: String
        let book: Book
        let pageIndex: Int?
        let snippet: String
    }

    private var hits: [Hit] {
        var out: [Hit] = []
        for book in store.books {
            let meta = [book.title, book.author, book.shelf].joined(separator: " ")
            if meta.range(of: query, options: [.caseInsensitive, .widthInsensitive]) != nil {
                out.append(Hit(id: book.id.uuidString, book: book, pageIndex: nil, snippet: book.author))
            }
            for (i, page) in book.pages.enumerated() {
                let text = page.text
                guard let r = text.range(of: query, options: [.caseInsensitive, .widthInsensitive]) else { continue }
                let start = text.index(r.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(r.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
                var snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
                if start != text.startIndex { snippet = "…" + snippet }
                if end != text.endIndex { snippet += "…" }
                out.append(Hit(id: "\(page.id.uuidString)", book: book, pageIndex: i, snippet: snippet))
                if out.count > 300 { return out }
            }
        }
        return out
    }

    var body: some View {
        let results = hits
        LazyVStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .padding(.top, 40)
            } else {
                Text("\(results.count) 件").font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.vertical, 8)
                ForEach(results) { hit in
                    Button {
                        if let i = hit.pageIndex { openPage(hit.book.id, i) } else { openBook(hit.book.id) }
                    } label: {
                        row(hit)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 76)
                }
            }
        }
    }

    private func row(_ hit: Hit) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let i = hit.pageIndex {
                    PageThumbnail(bookID: hit.book.id, page: hit.book.pages[i])
                } else {
                    BookCoverView(book: hit.book)
                }
            }
            .frame(width: 48, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(hit.book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if let i = hit.pageIndex {
                        Text("\(i + 1)ページ").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !hit.snippet.isEmpty {
                    Text(highlighted(hit.snippet))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func highlighted(_ s: String) -> AttributedString {
        var attr = AttributedString(s)
        if let r = attr.range(of: query, options: [.caseInsensitive, .widthInsensitive]) {
            attr[r].foregroundColor = .primary
            attr[r].backgroundColor = .yellow.opacity(0.35)
            attr[r].font = .footnote.bold()
        }
        return attr
    }
}
