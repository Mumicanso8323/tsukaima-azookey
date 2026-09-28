import SwiftUI

// 画面担当(native-today / native-studylife / native-chatsettings)の本物が merge-kit に入るまでの仮置き。
// 本物の Screens/<Area>/*.swift が入ったら、その struct をここから消すこと(二重定義になるため)。

private struct TsukaimaScreenPlaceholder: View {
    let title: String

    var body: some View {
        ContentUnavailableView(title, systemImage: "hammer", description: Text("この画面は準備中です"))
    }
}

struct StudyScreen: View {
    var body: some View { TsukaimaScreenPlaceholder(title: "勉強") }
}

struct LifeScreen: View {
    var body: some View { TsukaimaScreenPlaceholder(title: "生活") }
}

struct ChatScreen: View {
    var body: some View { TsukaimaScreenPlaceholder(title: "使い魔") }
}

struct SettingsScreen: View {
    var body: some View { TsukaimaScreenPlaceholder(title: "設定") }
}
