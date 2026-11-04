import AzooKeyUtils
import SwiftUI

/// UI テスト専用(起動引数 --naginata-mock-keys)。XCUITest は物理キーを送れないので、
/// 時刻つきの打鍵列を、実機と同じエンジン・同じ出力経路(HardwareIMETextView)へ流す。
enum NaginataMock {
    static let isActive = ProcessInfo.processInfo.arguments.contains("--naginata-mock-keys")

    typealias Event = (key: Character, down: Bool, t: TimeInterval)

    /// 1 キーを単独で打つ(押して 50ms で離す)
    static func tap(_ key: Character, at t: TimeInterval) -> [Event] {
        [(key, true, t), (key, false, t + 0.05)]
    }

    /// 同時押し(10ms ずつずらして押し、100ms で離す)
    static func chord(_ keys: [Character], at t: TimeInterval) -> [Event] {
        var out: [Event] = []
        for (i, k) in keys.enumerated() { out.append((k, true, t + Double(i) * 0.01)) }
        for (i, k) in keys.enumerated() { out.append((k, false, t + 0.1 + Double(i) * 0.01)) }
        return out
    }

    /// 単打 w→き, e→て, j→あ(それぞれ窓の外に離して打つ)
    static var single: [Event] { tap("w", at: 0) + tap("e", at: 0.5) + tap("j", at: 1.0) }
    /// 同時押し F+U→ざ, J+W→ぎ
    static var simultaneous: [Event] { chord(["f", "u"], at: 0) + chord(["j", "w"], at: 0.5) }
    /// J+K+D→？, J+K+F→「, J+K+V→」
    static var symbols: [Event] { chord(["j", "k", "d"], at: 0) + chord(["j", "k", "f"], at: 0.5) + chord(["j", "k", "v"], at: 1.0) }
}

struct NaginataMockKeysBar: View {
    @ObservedObject var session: HardwareIMESession
    /// 練習画面だけ: 次の 1 まとまりを打つキー列
    var nextKeys: [Character]?
    /// 練習画面だけ: 物理の Esc・Tab・Enter の代わりのボタンを出す
    var commandKeys = false

    var body: some View {
        if NaginataMock.isActive {
            VStack(alignment: .leading) {
                HStack {
                    button("単打", "naginata.mock.single", NaginataMock.single)
                    button("同時", "naginata.mock.simul", NaginataMock.simultaneous)
                    button("記号", "naginata.mock.symbols", NaginataMock.symbols)
                    if let nextKeys {
                        button("次を打つ", "naginata.mock.nexttoken", NaginataMock.chord(nextKeys, at: 0))
                    }
                }
                if commandKeys {
                    HStack {
                        command("Esc", "naginata.mock.esc", .escape)
                        command("Tab", "naginata.mock.tab", .tab)
                        command("Enter", "naginata.mock.enter", .enter)
                    }
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func command(_ title: String, _ id: String, _ key: HardwareIMEKey) -> some View {
        Button(title) { session.textView?.naginataMockCommandKey(key) }
            .accessibilityIdentifier(id)
    }

    private func button(_ title: String, _ id: String, _ events: [NaginataMock.Event]) -> some View {
        Button(title) { session.textView?.naginataMockInject(events) }
            .accessibilityIdentifier(id)
    }
}

/// UI テスト専用の入口(本番の起動では出ない)。メモ帳と練習画面を並べる。
struct NaginataMockHarness: View {
    init() {
        if ProcessInfo.processInfo.arguments.contains("--naginata-reset") {
            try? FileManager.default.removeItem(at: NaginataNoteStore.defaultDirectory)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink("薙刀式のメモ帳") { NaginataNotepadView() }
                    .accessibilityIdentifier("naginata.entry")
                NavigationLink("薙刀式の練習") { NaginataPracticeView() }
                    .accessibilityIdentifier("naginata.practice.entry")
            }
            .navigationTitle("薙刀式")
        }
    }
}
