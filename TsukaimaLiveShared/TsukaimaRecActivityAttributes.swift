import ActivityKit
import Foundation

/// 録音中の Live Activity(ロック画面・Dynamic Island)。本体(開始・終了)と TsukaimaLive 拡張(表示)で共有する。
/// iOS 18 の AudioRecordingIntent は、録音中に Live Activity が出ていることを求める。
struct TsukaimaRecActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        var stopAt: Date?   // 自動停止の予定(時間割に紐付かない録音は nil)
    }

    var course: String
}
