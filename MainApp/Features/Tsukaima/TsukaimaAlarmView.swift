import SwiftUI

struct TsukaimaAlarmView: View {
    @ObservedObject var alarm: TsukaimaAlarm
    @State private var time = TsukaimaAlarmView.defaultTime()
    @State private var input = ""
    @State private var wrong = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            switch alarm.phase {
            case .off: setup
            case .armed: armed
            case .ringing: ringing
            case .checking: checking
            }
            alarm.volumeView
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((alarm.phase == .ringing ? Color.red.opacity(0.35) : Color.black).ignoresSafeArea())
        .foregroundStyle(.white)
        .task { await loadSuggestion() }
        .overlay(alignment: .top) { batteryWarning }
    }

    private var setup: some View {
        VStack(spacing: 20) {
            Text("目覚まし").font(.title3.weight(.semibold)).padding(.top, 8)
            if let s = alarm.suggestion {
                Text(s).font(.footnote).foregroundStyle(.gray).multilineTextAlignment(.center)
            }
            DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel).labelsHidden()
            Button { alarm.arm(at: time) } label: {
                Text("セットして寝る").font(.headline).frame(maxWidth: .infinity).padding()
                    .background(Capsule().fill(.orange))
            }
            Text("イヤホンを挿したままで大丈夫です。時刻になると本体スピーカーから最大音量で鳴ります。\nアプリは閉じずに(ホームに戻るのは可)、充電しながら寝てください。")
                .font(.caption2).foregroundStyle(.gray).multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var armed: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(dayLabel).foregroundStyle(.gray)
            Text(alarm.fireAt?.formatted(date: .omitted, time: .shortened) ?? "")
                .font(.system(size: 64, weight: .light, design: .monospaced))
            if let f = alarm.fireAt {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text("あと \(hm(f.timeIntervalSince(ctx.date)))眠れます").foregroundStyle(.gray)
                }
            }
            Spacer()
            Button("解除") { alarm.disarm() }.foregroundStyle(.gray).padding(.bottom, 24)
        }
    }

    private var ringing: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("起きて！").font(.system(size: 48, weight: .bold))
            Text("\(alarm.question.a) + \(alarm.question.b) = ?")
                .font(.system(size: 40, weight: .medium, design: .monospaced))
            TextField("答え", text: $input)
                .keyboardType(.numberPad)
                .font(.system(size: 36, design: .monospaced))
                .multilineTextAlignment(.center)
                .focused($focused)
                .padding().background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.12)))
            if wrong { Text("違います(問題が変わりました)").foregroundStyle(.yellow) }
            Button {
                wrong = !alarm.answer(Int(input) ?? -1)
                input = ""
            } label: {
                Text("止める").font(.headline).frame(maxWidth: .infinity).padding()
                    .background(Capsule().fill(.white.opacity(0.25)))
            }
            Spacer()
        }
        .onAppear { focused = true; wrong = false }
    }

    private var checking: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("二度寝チェック").foregroundStyle(.gray)
            if let d = alarm.checkDeadline {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("\(max(0, Int(d.timeIntervalSince(ctx.date))) / 60):" +
                         String(format: "%02d", max(0, Int(d.timeIntervalSince(ctx.date))) % 60) + " までに押してください")
                        .font(.title3.monospacedDigit())
                }
            }
            Button { alarm.awake() } label: {
                Text("起きてる").font(.title.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 28)
                    .background(Capsule().fill(.green.opacity(0.6)))
            }
            Text("押さないとまた鳴ります").font(.caption).foregroundStyle(.gray)
            Spacer()
        }
    }

    /// 電池切れで電源が落ちると、どの仕組みでも鳴らない。充電していなければ警告する
    @ViewBuilder private var batteryWarning: some View {
        TimelineView(.periodic(from: .now, by: 10)) { _ in
            let dev = UIDevice.current
            let _ = (dev.isBatteryMonitoringEnabled = true)
            if alarm.phase != .ringing, dev.batteryState == .unplugged, dev.batteryLevel >= 0, dev.batteryLevel < 0.5 {
                Text("⚠ 充電していません(残り \(Int(dev.batteryLevel * 100))%)\n電池が切れると目覚ましは鳴りません。ケーブルを挿してください")
                    .font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
                    .padding(10).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.red.opacity(0.8)))
                    .padding(.horizontal, 12).padding(.top, 4)
            }
        }
    }

    /// 「今日 9/25(金)」「明日 9/26(土)」— どの日に鳴るかを取り違えないように
    private var dayLabel: String {
        guard let f = alarm.fireAt else { return "" }
        let d = f.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))
        return (Calendar.current.isDateInToday(f) ? "今日 " : Calendar.current.isDateInTomorrow(f) ? "明日 " : "") + d + " に鳴ります"
    }

    private func hm(_ s: TimeInterval) -> String {
        let m = max(0, Int(s) / 60)
        return "\(m / 60)時間\(m % 60)分"
    }

    /// hub が時間割から逆算した起床時刻(取れなければ前回の時刻)
    private func loadSuggestion() async {
        guard alarm.phase == .off,
              let (data, _) = try? await URLSession.shared.data(for: TsukaimaEndpoint.request(TsukaimaConfig.wakeURL)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        alarm.suggestion = obj["text"] as? String
        if let w = obj["wake"] as? String, let d = ISO8601DateFormatter().date(from: w) { time = d }
    }

    private static func defaultTime() -> Date {
        if let d = UserDefaults.standard.object(forKey: "alarm.last") as? Date { return d }
        return Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: .now)!
    }
}
