import SwiftUI

/// 「Claude」タブ(docs/converse-protocol.md 2章): 時系列表示 + 入力欄 + セッション選択・モデル/エフォート/
/// プロジェクト切替・中断。既定は会話モード(Converse)と同じ常駐セッション — ここで送った文字も、声で
/// 送ったものも同じ履歴に出る。上のバーから hub の他の対話セッションも選んで見られる(複数セッション対応)。
struct ClaudeTabView: View {
    @ObservedObject private var session = ClaudeSession.shared
    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 0) {
            ClaudeTopBar(session: session, showDetails: $showDetails)
            Divider()
            if let notice = session.notice {
                noticeBanner(notice)
            }
            ClaudeTimelineView(events: session.events, showDetails: showDetails)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ClaudeComposerView(session: session)
        }
        .overlay(alignment: .topLeading) {
            if ClaudeConfig.isMock { ClaudeFocusProbeTag() }
        }
        .onAppear {
            session.connect()
            // 一覧は並行に取る(プロジェクト一覧の待ちでセッション一覧が遅れて、メニューが空のまま見えていた)
            Task { await session.refreshSessions() }
            Task { await session.refreshProjects() }
            Task { await session.refreshState() }
        }
        .task {
            // タブを開いている間はセッション一覧を取り直し続ける(起動・終了・チャンネルの付け外しを拾う)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await session.refreshSessions()
            }
        }
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(text).font(.footnote)
            Spacer()
            Button {
                session.notice = nil
            } label: {
                Image(systemName: "xmark").font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if session.notice == text { session.notice = nil }
        }
    }
}

private struct ClaudeTopBar: View {
    @ObservedObject var session: ClaudeSession
    @Binding var showDetails: Bool

    /// 緑=接続中(繋がっていて手すき)・オレンジ=作業中・灰=切断(実機の不具合対応: 従来はオレンジ止まりだった)。
    private var dotColor: Color {
        guard session.linkState == .open else { return .gray }
        return session.status.busy ? .orange : .green
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                sessionMenu
                Spacer(minLength: 4)
                Button {
                    showDetails.toggle()
                } label: {
                    Image(systemName: showDetails ? "eye.fill" : "eye")
                        .font(.footnote)
                }
                .help("詳細を表示")
                if session.status.busy {
                    Button {
                        session.interrupt()
                    } label: {
                        Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                    }
                }
            }
            HStack(spacing: 10) {
                Menu {
                    ForEach(session.projects) { p in
                        Button(p.name) { session.set(project: p.name) }
                    }
                } label: {
                    Label(session.status.project ?? "プロジェクト", systemImage: "folder")
                        .font(.footnote)
                }
                Spacer(minLength: 4)
                Menu {
                    ForEach(ClaudeConfig.models, id: \.self) { m in
                        Button(ClaudeConfig.modelLabel(m)) { session.set(model: m) }
                    }
                } label: {
                    Text(ClaudeConfig.modelLabel(session.status.model)).font(.footnote)
                }
                Menu {
                    ForEach(ClaudeConfig.efforts, id: \.self) { e in
                        Button(e) { session.set(effort: e) }
                    }
                } label: {
                    Text(session.status.effort ?? "エフォート").font(.footnote)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// hub で動いているセッションを選ぶ。名前・cwd・状態を並べ、チャンネルの無いものは閲覧のみと分かる印を付ける。
    /// 各行は「見る」で切り替え、チャンネルがあれば「声の送り先にする」も出す(会話モードの送り先の変更)。
    private var sessionMenu: some View {
        Menu {
            // メニューを開いた瞬間にも取り直す(空のまま開いたときの保険)
            Color.clear.frame(width: 0, height: 0).onAppear { Task { await session.refreshSessions() } }
            Button {
                session.selectSession(nil)
            } label: {
                Label("会話モード(常駐)", systemImage: session.selectedSession == nil ? "checkmark" : "bubble.left.and.bubble.right")
            }
            if !session.sessions.isEmpty { Divider() }
            ForEach(session.sessions.filter { !$0.isConverse }) { s in
                Menu {
                    Button("このセッションを見る") { session.selectSession(s.sessionID) }
                    if s.channel {
                        Button("声の送り先にする") { session.setConverseSession(s.sessionID) }
                    }
                } label: {
                    sessionRowLabel(s)
                }
            }
            Divider()
            Button {
                session.setConverseSession(nil)
            } label: {
                Label("声の送り先を常駐に戻す", systemImage: "arrow.uturn.backward")
            }
        } label: {
            Label(sessionMenuTitle, systemImage: "list.bullet.rectangle")
                .font(.footnote)
        }
    }

    private var sessionMenuTitle: String {
        if session.selectedSession == nil { return session.status.name ?? "会話モード" }
        return session.sessions.first { $0.sessionID == session.selectedSession }?.name ?? (session.status.name ?? "セッション")
    }

    private func sessionRowLabel(_ s: ClaudeSessionInfo) -> some View {
        let statusMark = s.status == "busy" ? "作業中" : (s.status == "idle" ? "待機" : "?")
        let cwdShort = (s.cwd as NSString?)?.lastPathComponent ?? ""
        let channelMark = s.channel ? "" : "(閲覧のみ)"
        return Label("\(s.name) — \(cwdShort) [\(statusMark)]\(channelMark)", systemImage: s.channel ? "antenna.radiowaves.left.and.right" : "eye")
    }
}

/// UI テスト用の見えない札(入力欄の編集開始・終了の回数)。ClaudeConfig.isMock のときだけ出す。
private struct ClaudeFocusProbeTag: View {
    @ObservedObject private var probe = ClaudeFocusProbe.shared

    var body: some View {
        Text(probe.summary)
            .font(.system(size: 2))
            .opacity(0.02)
            .allowsHitTesting(false)
            .accessibilityIdentifier("claude.debug.focus")
            .accessibilityLabel(probe.summary)
    }
}
