import ImageIO
import SafariServices
import SwiftUI
import UIKit

extension View {
    func claudeSheets(_ router: ClaudeViewerRouter) -> some View {
        sheet(item: $router.sheet) { sheet in
            ClaudeSheetContent(sheet: sheet)
                .environmentObject(router)
        }
    }
}

struct ClaudeSheetContent: View {
    let sheet: ClaudeSheet

    var body: some View {
        switch sheet {
        case .browser(let url): ClaudeSafariView(url: url)
        case .file(let path): ClaudeFileViewer(path: path)
        case .image(let source): ClaudeImageViewer(source: source)
        case .selectText(let text): ClaudeTextSelectView(text: text)
        case .files(let startDir): ClaudeFileBrowser(startDir: startDir)
        }
    }
}

struct ClaudeSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.view.accessibilityIdentifier = "claude.browser"
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct ClaudeTextSelectView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .accessibilityIdentifier("claude.selectText")
                .navigationTitle("テキストを選択")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("すべてコピー") { UIPasteboard.general.string = text }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完了") { dismiss() }
                            .accessibilityIdentifier("claude.sheet.done")
                    }
                }
        }
    }
}

private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) { uiView.text = text }
}

struct ClaudeImageViewer: View {
    let source: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ZoomableImageView(image: image, backgroundColor: .black)
                } else if let error {
                    ContentUnavailableView("画像を開けません", systemImage: "photo", description: Text(error))
                        .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .accessibilityIdentifier("claude.imageViewer")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完了") { dismiss() }
                        .accessibilityIdentifier("claude.sheet.done")
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let image { ShareLink(item: image) { Image(systemName: "square.and.arrow.up") }.tint(.white) }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task(id: source) { await load() }
    }

    @MainActor private func load() async {
        do {
            let data = try await ClaudeImageData.load(source: source)
            image = await Task.detached(priority: .userInitiated) {
                Self.downsample(data: data, maxPixel: 2_048)
            }.value
            if image == nil { error = "画像の形式を読めません" }
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func downsample(data: Data, maxPixel: CGFloat) -> UIImage? {
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let source, let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct ClaudeRemoteImage: View {
    let source: String
    var maxPixel: CGFloat = 600
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.16))
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .task(id: source) {
            do {
                let data = try await ClaudeImageData.load(source: source)
                image = await Task.detached(priority: .userInitiated) {
                    ClaudeImageViewer.downsample(data: data, maxPixel: maxPixel)
                }.value
                failed = image == nil
            } catch { failed = true }
        }
    }
}

private enum ClaudeImageData {
    static func load(source: String) async throws -> Data {
        if let url = URL(string: source), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw ClaudeFileError.network("画像を取得できません")
            }
            return data
        }
        return try await ClaudeFileStore.shared.data(path: source)
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let backgroundColor: UIColor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.backgroundColor = backgroundColor
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.isUserInteractionEnabled = true
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        scrollView.backgroundColor = backgroundColor
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view?.superview as? UIScrollView else { return }
            scrollView.setZoomScale(scrollView.zoomScale > 1 ? 1 : 3, animated: true)
        }
    }
}
