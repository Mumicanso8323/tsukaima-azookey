import SwiftUI

struct TsukaimaRecorderView: View {
    @ObservedObject var rec: TsukaimaRecorderEngine

    var body: some View {
        VStack(spacing: 18) {
            Text(rec.course ?? "使い魔キット")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .padding(.top, 8)

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsed(at: ctx.date))
                    .font(.system(size: 52, weight: .light, design: .monospaced))
                    .foregroundStyle(rec.phase == .recording ? .white : .gray)
            }

            Text(status)
                .font(.footnote)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)

            if rec.phase == .recording {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    Text("🎙 \(TsukaimaMic.inputName)")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }

            if let end = rec.endAt, rec.phase == .recording {
                Text("終了 \(end.formatted(date: .omitted, time: .shortened)) の1分後に自動停止")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }

            Button(action: rec.toggle) {
                ZStack {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 4).frame(width: 128, height: 128)
                    if rec.phase == .recording {
                        RoundedRectangle(cornerRadius: 8).fill(.red).frame(width: 52, height: 52)
                    } else {
                        Circle().fill(rec.phase == .idle ? .red : .gray).frame(width: 104, height: 104)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rec.phase == .recording ? "停止" : "録音")

            if rec.phase == .finishing {
                Text("タップで未送信分を破棄して終了").font(.caption2).foregroundStyle(.gray)
            }

            transcript
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rec.lines) { line in
                        Text(line.text)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: rec.lines.last?.id) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func elapsed(at now: Date) -> String {
        guard let s = rec.startedAt else { return "00:00:00" }
        let t = max(0, Int(now.timeIntervalSince(s)))
        return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    private var status: String {
        if rec.phase == .idle { return rec.error ?? "待機中" }
        var s: String
        switch rec.link {
        case .open: s = "接続中"
        case .connecting: s = "接続しています"
        case .reconnecting: s = "再接続中"
        case .idle: s = "切断"
        }
        if rec.pending > 1 { s += " · 送信待ち\(rec.pending)秒" }
        if rec.phase == .finishing { s = "送信を仕上げています · " + s }
        if let e = rec.error { s += "\n" + e }
        return s
    }

    private var statusColor: Color {
        switch rec.link {
        case .open: return .green
        case .reconnecting: return .orange
        default: return .gray
        }
    }
}
