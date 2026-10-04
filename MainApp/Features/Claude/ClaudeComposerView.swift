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

/// 入力欄: 送信・写真添付(PhotosPicker・撮影)・ファイル添付(fileImporter)・スラッシュコマンド候補。
/// 添付はどちらも `/api/claude/upload` に先に上げ、送信時は id だけ渡す(converse-protocol.md 2章)。
struct ClaudeComposerView: View {
    /// 観測しない(items などの更新で入力欄が評価し直されないように)。作業中かどうかだけ timeline を観測する。
    let session: ClaudeSession
    @ObservedObject var timeline: ClaudeTimelineStore
    /// 打ちかけの文は覚えておく(タブを離れても・アプリを閉じても残る)
    @State private var text = ClaudeConfig.isMock ? "" : (UserDefaults.standard.string(forKey: ClaudeComposerView.draftKey) ?? "")
    @State private var attachments: [ClaudeAttachment] = []
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showFileImporter = false
    /// 入力欄のフォーカスの要求。@FocusState は .focused() で部品に結び付けないと書いても false に戻るので、
    /// UITextView 版の入力欄(TsukaimaComposerField)とは普通の @State でやり取りする。
    @State private var focused = false

    private static let draftKey = "claude.draft"
    private static let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)

    private var slashSuggestions: [String] {
        guard text.hasPrefix("/"), text.count <= 20 else { return [] }
        let matches = ClaudeConfig.slashCommands.filter { $0.hasPrefix(text) && $0 != text }
        return matches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !slashSuggestions.isEmpty {
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
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { a in
                            attachmentChip(a)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
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
                // 物理キーボード用の変換つき入力欄(設定オフなら普通の TextField)
                TsukaimaComposerField(placeholder: "Claude に送る…", text: $text,
                                      focused: $focused, pinsFocus: true, maxLines: 8,
                                      accessibilityID: "claude.composer")
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                if showStop {
                    // 作業中で、送るものが無いときは「止める」(公式アプリと同じ位置)
                    Button {
                        session.interrupt()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("止める")
                    .accessibilityIdentifier("claude.stop")
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("送信")
                    .accessibilityIdentifier("claude.send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onChange(of: text) { _, t in
            if !ClaudeConfig.isMock { UserDefaults.standard.set(t, forKey: Self.draftKey) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await uploadPhoto(item) }
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

    /// 作業中で、打った文字も添付も無いときは送信の代わりに止めるボタン
    private var showStop: Bool {
        timeline.busy && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let attachmentsReady = attachments.allSatisfy { !$0.uploading }
        return (hasText || !attachments.isEmpty) && attachmentsReady
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

    private func send() {
        // かな入力の途中(未確定)で送っても、その分が落ちないよう先に確定させる
        TsukaimaComposerField.commitMarkedText()
        guard canSend else { return }
        let ids = attachments.compactMap(\.uploadID)
        session.send(text: text.trimmingCharacters(in: .whitespacesAndNewlines), attachmentIDs: ids)
        text = ""
        attachments = []
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // キーボードは出したまま(公式アプリと同じ。続けて打てる)
    }

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
