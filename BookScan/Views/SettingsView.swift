import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.defaultFilterKey) private var defaultFilter = PageFilter.enhanced.rawValue
    @AppStorage(AppSettings.jpegQualityKey) private var jpegQuality = 0.92
    @AppStorage(AppSettings.defaultBindingKey) private var defaultBinding = BindingDirection.left.rawValue
    @AppStorage(AppSettings.autoOCRKey) private var autoOCR = true
    @AppStorage(AppSettings.autoCropKey) private var autoCrop = true
    @AppStorage(AppSettings.readerModeKey) private var readerMode = ReaderMode.curl.rawValue
    @AppStorage(AppSettings.spreadModeKey) private var spreadMode = SpreadMode.auto.rawValue
    @AppStorage(AppSettings.coverAloneKey) private var coverAlone = true
    @AppStorage(AppSettings.liveTextKey) private var liveText = true

    @State private var dataSize: String = "計算中…"
    @State private var cacheSize: String = "計算中…"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("新しいページの補正", selection: $defaultFilter) {
                        ForEach(PageFilter.allCases) { f in
                            Text(f.label).tag(f.rawValue)
                        }
                    }
                    Picker("保存画質", selection: $jpegQuality) {
                        Text("標準").tag(0.85)
                        Text("高画質").tag(0.92)
                        Text("最高画質").tag(0.98)
                    }
                    Toggle("写真の書類を自動で切り抜く", isOn: $autoCrop)
                } header: {
                    Text("スキャン")
                } footer: {
                    Text("元の画像は常にそのまま保存されるので、補正はあとからいつでも変更できます。")
                }

                Section {
                    Toggle("自動で文字認識（日本語・英語）", isOn: $autoOCR)
                } header: {
                    Text("文字認識")
                } footer: {
                    Text("認識した文字は本棚の検索と、書き出したPDFの文字検索に使われます。処理はすべて端末内で行われます。")
                }

                Section {
                    Picker("ページの切り替え", selection: $readerMode) {
                        ForEach(ReaderMode.allCases) { m in
                            Text(m.label).tag(m.rawValue)
                        }
                    }
                    Picker("見開き表示", selection: $spreadMode) {
                        ForEach(SpreadMode.allCases) { m in
                            Text(m.label).tag(m.rawValue)
                        }
                    }
                    Toggle("見開きで表紙を単独表示", isOn: $coverAlone)
                    Toggle("ページ上の文字を長押しで選択（テキスト認識表示）", isOn: $liveText)
                    Picker("新しい本の綴じ方向", selection: $defaultBinding) {
                        ForEach(BindingDirection.allCases) { b in
                            Text(b.label).tag(b.rawValue)
                        }
                    }
                } header: {
                    Text("読書")
                } footer: {
                    Text("見開きで撮影したページは、本の「…」メニューの「横長ページをすべて見開き分割」で1ページずつに分けられます。")
                }

                Section {
                    LabeledContent("スキャンデータ", value: dataSize)
                    LabeledContent("キャッシュ", value: cacheSize)
                    Button("キャッシュを削除") {
                        Paths.clearCaches()
                        PageImages.cache.removeAllObjects()
                        refreshSizes()
                    }
                } header: {
                    Text("ストレージ")
                } footer: {
                    Text("元画像は「ファイル」アプリ →「このiPhone内」→「本スキャン」→ Books からも見られます。")
                }

                Section {
                    LabeledContent("バージョン", value: appVersion)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }.bold()
                }
            }
            .onAppear { refreshSizes() }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func refreshSizes() {
        Task {
            let sizes = await Task.detached(priority: .utility) { () -> (Int64, Int64) in
                let data = Paths.directorySize(Paths.booksDir)
                let cache = Paths.directorySize(Paths.renderedDir) + Paths.directorySize(Paths.thumbsDir)
                return (data, cache)
            }.value
            dataSize = ByteCountFormatter.string(fromByteCount: sizes.0, countStyle: .file)
            cacheSize = ByteCountFormatter.string(fromByteCount: sizes.1, countStyle: .file)
        }
    }
}
