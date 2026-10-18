import SwiftUI
import UIKit

struct PageEditorView: View {
    let bookID: UUID
    let pageID: UUID

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var preview: UIImage?
    @State private var tab = 0
    @State private var copied = false
    @State private var showCrop = false

    var body: some View {
        NavigationStack {
            Group {
                if let book = store.book(bookID),
                   let index = book.pages.firstIndex(where: { $0.id == pageID }) {
                    let page = book.pages[index]
                    VStack(spacing: 14) {
                        Picker("", selection: $tab) {
                            Text("画像補正").tag(0)
                            Text("テキスト").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)

                        if tab == 0 {
                            imageEditor(book: book, page: page)
                        } else {
                            textView(page: page)
                        }
                    }
                    .padding(.top, 8)
                    .navigationTitle(page.printedNumber.map { "\(index + 1) ページ（p.\($0)）" } ?? "\(index + 1) ページ")
                } else {
                    ContentUnavailableView("ページが見つかりません", systemImage: "doc")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }.bold()
                }
            }
        }
    }

    // MARK: - 画像

    @ViewBuilder
    private func imageEditor(book: Book, page: Page) -> some View {
        ZStack {
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            }
            if preview == nil {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
        .overlay(alignment: .top) {
            if page.hasIssues {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("撮影時の注意：\(page.issueLabels.joined(separator: "・"))")
                        .font(.footnote.weight(.semibold))
                    Button("問題なし") { store.clearFlags(bookID: bookID, pageID: pageID) }
                        .font(.footnote.weight(.bold))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
            }
        }
        .sheet(isPresented: $showCrop) {
            CropEditorView(bookID: bookID, pageID: pageID).environment(store)
        }
        .task(id: page.renderKey) {
            if let cached = PageImages.cachedDisplay(page) {
                preview = cached
                return
            }
            if let thumb = PageImages.cachedThumbnail(page) { preview = thumb }
            if let full = await PageImages.display(bookID: bookID, page: page) {
                preview = full
            }
        }

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(PageFilter.allCases) { f in
                    Button {
                        store.updatePage(bookID: bookID, pageID: pageID) { $0.filter = f }
                    } label: {
                        VStack(spacing: 6) {
                            PageThumbnail(bookID: bookID, page: variant(of: page, filter: f), contentMode: .fill)
                                .frame(width: 62, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(page.filter == f ? Color.accentColor : Color.clear, lineWidth: 3)
                                )
                            Text(f.label)
                                .font(.caption2.weight(page.filter == f ? .bold : .regular))
                                .foregroundStyle(page.filter == f ? Color.accentColor : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 104)

        HStack(spacing: 14) {
            Button {
                store.rotate(bookID: bookID, pageID: pageID, by: -1)
            } label: {
                Image(systemName: "rotate.left").font(.title3).frame(width: 44, height: 36)
            }
            .buttonStyle(.bordered)
            Button {
                store.rotate(bookID: bookID, pageID: pageID, by: 1)
            } label: {
                Image(systemName: "rotate.right").font(.title3).frame(width: 44, height: 36)
            }
            .buttonStyle(.bordered)
            if page.canAdjustCrop {
                Button {
                    showCrop = true
                } label: {
                    Label("範囲", systemImage: "crop")
                        .font(.subheadline)
                        .frame(height: 36)
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Menu {
                Button("「\(page.filter.label)」を全ページに適用") {
                    store.applyFilterToAll(bookID: bookID, filter: page.filter)
                }
                Button("このページを表紙に設定") {
                    store.setCover(bookID, pageID: pageID)
                }
            } label: {
                Label("その他", systemImage: "ellipsis.circle")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    private func variant(of page: Page, filter: PageFilter) -> Page {
        var p = page
        p.filter = filter
        return p
    }

    // MARK: - テキスト

    @ViewBuilder
    private func textView(page: Page) -> some View {
        ScrollView {
            Group {
                if page.needsOCR {
                    if store.ocrRunning.contains(bookID) {
                        Label("文字認識中…", systemImage: "text.viewfinder")
                            .foregroundStyle(.secondary)
                            .symbolEffect(.pulse)
                    } else {
                        Text("まだ文字認識されていません。")
                            .foregroundStyle(.secondary)
                    }
                } else if page.text.isEmpty {
                    Text("文字が見つかりませんでした。")
                        .foregroundStyle(.secondary)
                } else {
                    Text(page.text)
                        .textSelection(.enabled)
                        .font(.body)
                        .lineSpacing(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)

        HStack {
            Button {
                UIPasteboard.general.string = page.text
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "コピーしました" : "すべてコピー", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(page.text.isEmpty)
            Spacer()
            Button {
                store.redoOCR(bookID: bookID, pageID: pageID)
            } label: {
                Label("再認識", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }
}
