import GameController
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct ClaudeAttachment: Identifiable {
    let id = UUID()
    let name: String
    var uploadID: String?
    var uploading = true
    var failed = false
}

/// 入力欄: 送信・写真添付(PhotosPicker・撮影)・ファイル添付(fileImporter)・スラッシュコマンド候補・
/// 音声入力(差し込むだけ)・選択肢(AskUserQuestion)への回答。
/// 添付はどちらも `/api/claude/upload` に先に上げ、送信時は id だけ渡す(converse-protocol.md 2章)。
///
/// フォーカスの約束(本人: 「カーソルが勝手に外れることはあってはならない」):
///   - `focused` は `@State`(`@FocusState` ではない)。`.focused()` で結び付けていない @FocusState は SwiftUI が
///     次の更新で false に戻し、それを見た updateUIView が resignFirstResponder していた(1 文字打つ・イベントが
///     届くたびに外れる原因)。ここでは単なる「意図」のフラグとして持つ。
///   - 入力欄(TsukaimaComposerField)は VStack の固定位置にあり、`if` で差し替えない・`.id` を付けない。
///     上に出る状態行・選択肢・添付・候補は高さを予約した枠の中で入れ替える(入力欄の位置が跳ねない)。
///   - false にするのは本人の明示的な操作だけ: Esc・閉じるボタン・タブを離れた。送信・選択肢・音声では触らない。
struct ClaudeComposerView: View {
    @ObservedObject var session: ClaudeSession
    var scroller: ClaudeTimelineScroller?
    @EnvironmentObject private var router: AppRouter
    @StateObject private var voice = ClaudeVoiceInput()
    @StateObject private var field = ComposerFieldController()
    @State private var text = ""
    @State private var attachments: [ClaudeAttachment] = []
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var focused = false
    @State private var selection: ClaudeChoiceSelection?
    @State private var hardwareKeyboard = HardwareIMETextView.hardwareKeyboardAttached

    private static let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
    /// 入力欄の上の枠(選択肢/添付/候補/ヒントのどれか 1 つ)の高さ。出入りで入力欄が動かないよう固定
    private static let topZoneHeight = ClaudeChoiceBar.height

    private var slashSuggestions: [String] {
        guard text.hasPrefix("/"), text.count <= 20 else { return [] }
        return ClaudeConfig.slashCommands.filter { $0.hasPrefix(text) && $0 != text }
    }

    private var activity: ClaudeToolActivity { ClaudeToolActivity.reduce(session.events) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ClaudeToolStatusLine(activity: activity, busy: session.status.busy)
            topZone
                .frame(height: Self.topZoneHeight)
                .clipped()
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("写真を選ぶ", systemImage: "photo.on.rectangle")
                    }
                    if Self.cameraAvailable {
                        Button {
                            showCamera = true
                        } label: {
                            Label("撮影する", systemImage: "camera")
                        }
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("ファイルを選ぶ", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .frame(width: 36, height: 36)
                }
                // 物理キーボード用の変換つき入力欄(設定オフなら普通の TextField)。固定位置・差し替えなし
                TsukaimaComposerField(placeholder: "Claude に送る…", text: $text,
                                      focused: Binding(get: { focused }, set: { focused = $0 }), maxLines: 5,
                                      keepsFocus: true, accessibilityID: "claude.composer",
                                      onSubmit: { handleEnter() }, onPlainKey: { handlePlainKey($0) },
                                      onBinding: { handleBinding($0) }, controller: field)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                Button {
                    voice.toggle(insert: { field.insertAtCursor($0) })
                } label: {
                    Image(systemName: voice.phase == .recording ? "stop.circle.fill" : "mic.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(voice.phase == .recording ? Color.red : Color.accentColor)
                        .opacity(voice.phase == .transcribing ? 0.4 : 1)
                        .frame(width: 32, height: 36)
                }
                .disabled(voice.phase == .transcribing)
                .accessibilityIdentifier("claude.mic")
                if focused && !hardwareKeyboard {
                    Button {
                        focused = false  // 本人が明示的に閉じる
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 18))
                            .frame(width: 28, height: 36)
                    }
                    .accessibilityIdentifier("claude.dismiss")
                }
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(!canSend)
                .accessibilityIdentifier("claude.send")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await uploadPhoto(item) }
        }
        .onChange(of: session.choice, initial: true) { _, c in
            selection = c.map(ClaudeChoiceSelection.init)
        }
        .onChange(of: router.selectedTab) { _, tab in
            // タブを離れるのは「明示的に閉じた」扱い(戻ってきたときに勝手にキーボードを出さない)
            if tab != .claude { focused = false }
        }
        .onChange(of: voice.errorText) { _, e in
            guard let e else { return }
            session.notice = e
            voice.errorText = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in hardwareKeyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            hardwareKeyboard = HardwareIMETextView.hardwareKeyboardAttached
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(isPresented: $showCamera) { image in
                Task { await uploadCameraImage(image) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await uploadFile(url) }
        }
    }

    /// 入力欄の上の枠。優先順: 選択肢 > 添付 > スラッシュ候補 > ヒント(録音中の印もここ)
    @ViewBuilder private var topZone: some View {
        if let selection {
            ClaudeChoiceBar(selection: selection, onPick: { pick(number: $0) }, onConfirm: { confirmChoice() })
        } else if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { a in
                        attachmentChip(a)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        } else if !slashSuggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(slashSuggestions, id: \.self) { cmd in
                        Button(cmd) { text = cmd + " " }
                            .font(.footnote.monospaced())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.thinMaterial, in: Capsule())
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        } else {
            HStack(spacing: 6) {
                if voice.phase == .recording {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("録音中… もう一度押すと文字にします").font(.caption2).foregroundStyle(.secondary)
                } else if voice.phase == .transcribing {
                    ProgressView().controlSize(.mini)
                    Text("文字にしています…").font(.caption2).foregroundStyle(.secondary)
                } else if hardwareKeyboard {
                    Text("Enter 送信 · Shift+Enter 改行 · Esc 閉じる · ⌥↑↓ 履歴 · ⌘⇧M 音声")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                } else if session.linkState != .open {
                    Text("hub に接続中…(入力はできます。送信は接続後)").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// 送れない状態(未接続・添付の途中)は送信だけ無効にする。入力は続けられる
    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let attachmentsReady = attachments.allSatisfy { !$0.uploading }
        return (hasText || !attachments.isEmpty) && attachmentsReady && session.linkState == .open
    }

    private func attachmentChip(_ a: ClaudeAttachment) -> some View {
        HStack(spacing: 4) {
            if a.uploading {
                ProgressView().controlSize(.mini)
            } else if a.failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                Image(systemName: "paperclip")
            }
            Text(a.name).font(.caption).lineLimit(1)
            Button {
                attachments.removeAll { $0.id == a.id }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
    }

    // MARK: 送信・キー操作

    /// 送信。カーソルは外さない(focused を触らない。欄を空にするだけ)
    private func send() {
        guard canSend else { return }
        let ids = attachments.compactMap(\.uploadID)
        session.send(text: text.trimmingCharacters(in: .whitespacesAndNewlines), attachmentIDs: ids)
        text = ""
        attachments = []
    }

    /// 物理キーボードの素の Enter(欄に文字があるとき。空のときは handlePlainKey(.enter) が先に受ける)。
    /// 選択肢が出ていれば「その他(自由入力)」としてその文字を回答にする
    private func handleEnter() {
        if selection != nil {
            _ = handlePlainKey(.enter)
            return
        }
        send()
    }

    private func handlePlainKey(_ key: ComposerPlainKey) -> Bool {
        if key == .escape {
            focused = false  // 本人が明示的に閉じる(BT キーボードの Esc。変換中の Esc は IME が先に受ける)
            return true
        }
        guard var sel = selection, let outcome = sel.handle(key, composerText: text) else { return false }
        apply(outcome, from: sel)
        return true
    }

    private func handleBinding(_ b: ComposerKeyBinding) -> Bool {
        if let n = b.chooseNumber {
            pick(number: n)
            return true
        }
        if b == .toggleMic {
            voice.toggle(insert: { field.insertAtCursor($0) })
            return true
        }
        return scroller?.handle(b) ?? false
    }

    private func pick(number n: Int) {
        guard var sel = selection else { return }
        let outcome = sel.pick(number: n)
        apply(outcome, from: sel)
    }

    private func confirmChoice() {
        guard var sel = selection else { return }
        let outcome = sel.confirmMulti()
        apply(outcome, from: sel)
    }

    private func apply(_ outcome: ClaudeChoiceSelection.Outcome, from sel: ClaudeChoiceSelection) {
        switch outcome {
        case .ignored:
            break
        case .changed:
            selection = sel
        case .submit(let answers):
            session.answerChoice(answers)
            if answers.contains(where: { $0.otherText != nil }) { text = "" }
            selection = nil
        }
    }

    // MARK: 添付

    private func uploadPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        await uploadData(data, name: "photo.jpg", mime: "image/jpeg")
    }

    private func uploadCameraImage(_ image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        await uploadData(data, name: "camera.jpg", mime: "image/jpeg")
    }

    private func uploadFile(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        await uploadData(data, name: url.lastPathComponent, mime: mime)
    }

    private func uploadData(_ data: Data, name: String, mime: String) async {
        var attachment = ClaudeAttachment(name: name)
        attachments.append(attachment)
        do {
            let id = try await session.upload(data: data, filename: name, mime: mime)
            attachment.uploadID = id
            attachment.uploading = false
            if let idx = attachments.firstIndex(where: { $0.id == attachment.id }) { attachments[idx] = attachment }
        } catch {
            attachment.uploading = false
            attachment.failed = true
            if let idx = attachments.firstIndex(where: { $0.id == attachment.id }) { attachments[idx] = attachment }
        }
    }
}
