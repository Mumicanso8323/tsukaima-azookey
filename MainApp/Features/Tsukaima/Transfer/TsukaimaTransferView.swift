import SwiftUI
import UniformTypeIdentifiers

/// 引き継ぎの画面遷移の状態。シート類は Form の外側(TsukaimaTransferPresenter)に付ける
/// (List の行に付けると、行の更新でシートが勝手に閉じることがある)。
@MainActor
final class TsukaimaTransferFlow: ObservableObject {
    @Published var showExport = false
    @Published var showImporter = false
    @Published var imported: ImportedFile?
    @Published var message: String?

    struct ImportedFile: Identifiable {
        let id = UUID()
        let data: Data
    }
}

/// 設定の「引き継ぎ」: TestFlight 版へ移す前に、この端末のデータを合言葉つきの1ファイルに書き出す/読み込む。
struct TsukaimaTransferSection: View {
    @ObservedObject var flow: TsukaimaTransferFlow

    var body: some View {
        Section {
            Button("引き継ぎ用に書き出す") { flow.showExport = true }
                .accessibilityIdentifier("transfer.export")
            Button("引き継ぎファイルを読み込む") { flow.showImporter = true }
                .accessibilityIdentifier("transfer.import")
            if let message = flow.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("transfer.message")
            }
        } header: {
            Text("引き継ぎ")
        } footer: {
            Text("設定・キーボードの設定とカスタムキー・薙刀式のメモを、合言葉つきの1ファイルにします。合鍵(端末の登録)は運ばないので、移した先で登録し直します。")
        }
    }
}

struct TsukaimaTransferPresenter: ViewModifier {
    @ObservedObject var flow: TsukaimaTransferFlow

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $flow.showExport) { TsukaimaTransferExportSheet() }
            .sheet(item: $flow.imported) { f in
                TsukaimaTransferImportSheet(file: f.data) { result in
                    flow.imported = nil
                    flow.message = result
                }
            }
            .fileImporter(isPresented: $flow.showImporter, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
                if size > TsukaimaTransferFile.maxFileSize {
                    flow.message = "ファイルが大きすぎます(引き継ぎファイルではない可能性があります)。"
                } else if let data = try? Data(contentsOf: url) {
                        flow.imported = .init(data: data)
                    } else {
                        flow.message = "ファイルを読めませんでした。"
                    }
                case .failure:
                    flow.message = "ファイルを選べませんでした。"
                }
            }
    }
}

private struct TsukaimaTransferExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var working = false
    @State private var error: String?
    @State private var fileURL: URL?
    @State private var summary: TsukaimaTransfer.Summary?

    var body: some View {
        NavigationView {
            Form {
                if let fileURL, let summary {
                    Section {
                        Text("設定 \(summary.defaultsCount) 件・ファイル \(summary.fileCount) 個を書き出しました。")
                        if !summary.skipped.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("入らなかった物が \(summary.skipped.count) 件あります").font(.footnote.bold())
                                ForEach(Array(summary.skipped.enumerated()), id: \.offset) { _, item in
                                    Text("\(item.path)(\(item.reason.rawValue))").font(.caption)
                                }
                            }
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("transfer.skipped")
                        }
                        ShareLink(item: fileURL) { Label("ファイルに保存・AirDrop", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("transfer.share")
                    } footer: {
                        Text("合言葉は書き留めておいてください(忘れると開けません)。ファイルと合言葉は別々に保管してください。")
                    }
                    Section("合言葉") { Text(passphrase).font(.body.monospaced()).textSelection(.enabled) }
                } else {
                    Section {
                        TextField("合言葉(12文字以上)", text: $passphrase)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("transfer.export.passphrase")
                        Button {
                            run()
                        } label: {
                            HStack { Text("書き出す"); if working { Spacer(); ProgressView() } }
                        }
                        .disabled(working || TsukaimaTransferFile.trimmed(passphrase).count < TsukaimaTransferFile.minPassphrase)
                        .accessibilityIdentifier("transfer.export.run")
                        if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    } footer: {
                        Text("読み込むときに同じ合言葉を入力します。")
                    }
                }
            }
            .onDisappear { if let fileURL { try? FileManager.default.removeItem(at: fileURL) } }
            .navigationTitle("書き出し")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    private func run() {
        working = true
        error = nil
        let pass = TsukaimaTransferFile.trimmed(passphrase)
        Task.detached {
            do {
                // UI テスト専用: 空の端末でも書き出しまで通せるよう、薙刀式のメモを1枚置く
                if ProcessInfo.processInfo.arguments.contains("--transfer-mock") {
                    try? NaginataNoteStore().save("transfer-mock")
                }
                let (data, sum) = try TsukaimaTransfer.export(passphrase: pass)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tsukaima-\(stamp).\(TsukaimaTransferFile.fileExtension)")
                try data.write(to: url, options: .atomic)
                await MainActor.run { fileURL = url; summary = sum; working = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; working = false }
            }
        }
    }
}

private struct TsukaimaTransferImportSheet: View {
    let file: Data
    let finish: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var working = false
    @State private var error: String?
    @State private var opened: TsukaimaTransfer.Payload?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("合言葉", text: $passphrase)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("transfer.import.passphrase")
                    Button {
                        open()
                    } label: {
                        HStack { Text("開く"); if working { Spacer(); ProgressView() } }
                    }
                    .disabled(working || passphrase.isEmpty)
                    .accessibilityIdentifier("transfer.import.open")
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("読み込み")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .confirmationDialog(
                "この端末の設定を上書きします",
                isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } }),
                titleVisibility: .visible,
                presenting: opened
            ) { payload in
                Button("上書きして読み込む", role: .destructive) { apply(payload) }
                Button("やめる", role: .cancel) {}
            } message: { payload in
                Text("設定 \(payload.summary.defaultsCount) 件・ファイル \(payload.summary.fileCount) 個を読み込みます。同じ名前の設定・ファイルは上書きされます。")
            }
        }
    }

    private func open() {
        working = true
        error = nil
        let pass = TsukaimaTransferFile.trimmed(passphrase)
        let data = file
        Task.detached {
            do {
                let payload = try TsukaimaTransfer.open(data, passphrase: pass)
                await MainActor.run { opened = payload; working = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; working = false }
            }
        }
    }

    private func apply(_ payload: TsukaimaTransfer.Payload) {
        let failed = TsukaimaTransfer.apply(payload)
        dismiss()
        if failed.isEmpty {
            finish("読み込みました。アプリを一度終了して開き直してください。")
        } else {
            finish("読み込みましたが、\(failed.count) 個のファイルを書けませんでした(\(failed.prefix(3).joined(separator: "、"))など)。アプリを一度終了して開き直してください。")
        }
    }
}
