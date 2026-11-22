import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TsukaimaLiveBundle: WidgetBundle {
    var body: some Widget {
        TsukaimaRecLiveActivity()
    }
}

/// 授業の録音中表示。録音は本体アプリが続けているので、ここは表示だけ。
struct TsukaimaRecLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TsukaimaRecActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "mic.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.course).font(.headline).lineLimit(1)
                    Text("録音中").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(maxWidth: 90, alignment: .trailing)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "mic.fill").foregroundStyle(.red) }
                DynamicIslandExpandedRegion(.center) { Text(context.attributes.course).lineLimit(1) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit().frame(maxWidth: 70)
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit().frame(maxWidth: 48)
            } minimal: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            }
        }
    }
}
