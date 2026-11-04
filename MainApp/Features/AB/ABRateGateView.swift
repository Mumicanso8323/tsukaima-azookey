import SwiftUI
import UIKit

/// 画像を一枚ずつ 1--10 で採点する全画面。画像は認証済みの ABRateGateModel が保持する。
@MainActor
struct ABRateGateView: View {
    @ObservedObject var model: ABRateGateModel
    @State private var zoomed: UIImage?
    @State private var noteIsExpanded = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                Text(model.progressText)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("rate.progress")

                ratingImage

                VStack(spacing: 8) {
                    if model.showRetryHint {
                        Text("もう一度押してください")
                            .font(.footnote)
                            .foregroundStyle(.yellow)
                    }
                    Button("メモ") {
                        noteIsExpanded.toggle()
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("rate.noteToggle")

                    if noteIsExpanded {
                        // 表示しただけでは focus を要求しないので、採点を急ぐ時にキーボードを奪わない。
                        TextField("メモ（任意）", text: $model.note)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1)
                            .accessibilityLabel("メモ")
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(1...10, id: \.self) { score in
                            Button {
                                model.score(score)
                            } label: {
                                Text("\(score)")
                                    .font(.title2.weight(.bold))
                                    .frame(maxWidth: .infinity, minHeight: 56)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || model.item == nil)
                            .accessibilityIdentifier("rate.score.\(score)")
                        }
                    }
                    HStack {
                        Text(model.scale?.low ?? "")
                            .accessibilityIdentifier("rate.low")
                        Spacer()
                        Text(model.scale?.high ?? "")
                            .accessibilityIdentifier("rate.high")
                    }
                    .font(.footnote)
                    .foregroundStyle(.white)
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
                    .accessibilityIdentifier("rate.zoomClose")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("rate.zoom")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rate.screen")
    }

    private var ratingImage: some View {
        Color.black
            .overlay {
                if let image = model.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { if let image = model.image { zoomed = image } }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("採点する絵")
            .accessibilityIdentifier("rate.image")
    }
}
