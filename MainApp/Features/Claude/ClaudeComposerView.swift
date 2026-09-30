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
    @ObservedObject var session: ClaudeSession
    @State private var text = ""
    @State private var attachments: [ClaudeAttachment] = []
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showFileImporter = false
    @FocusState private var focused: Bool

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
                TextField("Claude に送る…", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .focused($focused)
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
        guard canSend else { return }
        let ids = attachments.compactMap(\.uploadID)
        session.send(text: text.trimmingCharacters(in: .whitespacesAndNewlines), attachmentIDs: ids)
        text = ""
        attachments = []
        focused = false
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
