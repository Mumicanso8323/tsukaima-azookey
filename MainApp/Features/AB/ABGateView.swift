import SwiftUI
import UIKit

/// A/B の全画面。縦長の絵を左右に並べ(タップで全画面ズーム)、下に「A」「B」「どっちもダメ」。
struct ABGateView: View {
    @ObservedObject var model: ABGateModel
    @State private var zoomed: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                Text(model.progressText)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("ab.progress")
                HStack(spacing: 4) {
                    cell(model.imageA, id: "ab.imageA")
                    cell(model.imageB, id: "ab.imageB")
                }
                VStack(spacing: 8) {
                    if model.showRetryHint {
                        Text("もう一度押してください")
                            .font(.footnote)
                            .foregroundStyle(.yellow)
                    }
                    HStack(spacing: 8) {
                        choiceButton("A", .a, id: "ab.choiceA")
                        choiceButton("B", .b, id: "ab.choiceB")
                    }
                    choiceButton("どっちもダメ", .none, id: "ab.choiceNone")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .accessibilityHidden(zoomed != nil)
            if let zoomed {
                ZStack(alignment: .topTrailing) {
                    ABZoomImageView(image: zoomed)
                        .ignoresSafeArea()
                    Button {
                        self.zoomed = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white, .black.opacity(0.5))
                            .padding(16)
                    }
                    .accessibilityLabel("閉じる")
                    .accessibilityIdentifier("ab.zoomClose")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ab.zoom")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ab.screen")
    }

    private func cell(_ image: UIImage?, id: String) -> some View {
        Color.black
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { if let image { zoomed = image } }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(id == "ab.imageA" ? "絵 A" : "絵 B")
            .accessibilityIdentifier(id)
    }

    private func choiceButton(_ title: String, _ choice: ABChoice, id: String) -> some View {
        Button {
            model.vote(choice)
        } label: {
            Text(title)
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.busy || model.pair == nil)
        .accessibilityIdentifier(id)
    }
}

/// ピンチ・ダブルタップで拡大できる画像ビュー
struct ABZoomImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.backgroundColor = .black
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
