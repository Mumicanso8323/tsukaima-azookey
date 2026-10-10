import SwiftUI

/// 「Claude」タブ(docs/converse-protocol.md 2章): 時系列表示 + 入力欄 + セッション選択・モデル/エフォート/
/// プロジェクト切替・中断。既定は会話モード(Converse)と同じ常駐セッション — ここで送った文字も、声で
/// 送ったものも同じ履歴に出る。上のバーから hub の他の対話セッションも選んで見られる(複数セッション対応)。
struct ClaudeTabView: View {
    /// 観測しない: 全体を観測すると status や sessions の更新のたびにこの body(会話・入力欄を含む)が評価し直される。
    /// 変わる部分は ClaudeTopBar / ClaudeStatusBanners / ClaudeTimelineHost が自分で観測する。
    private let session = ClaudeSession.shared
    @StateObject private var router = ClaudeViewerRouter()
    @State private var showDetails = false
    /// 文字の大きさ(端末の設定に加えて、このタブだけ大きく/小さくできる)。0 = 端末の設定のまま
    @AppStorage("claude.textSizeStep") private var textSizeStep = 0

    var body: some View {
        VStack(spacing: 0) {
            ClaudeTopBar(session: session, router: router, showDetails: $showDetails, textSizeStep: $textSizeStep)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("claude.topbar")
            Divider()
            ClaudeStatusBanners(session: session)
            ClaudeTimelineHost(store: session.timeline)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dynamicTypeSize(ClaudeTabView.typeSize(textSizeStep))
            Divider()
            ClaudeComposerView(session: session, timeline: session.timeline)
        }
        .environmentObject(router)
        .environment(\.openURL, router.openURLAction)
        .claudeSheets(router)
        .onChange(of: showDetails) { _, on in session.setShowDetails(on) }
        .overlay(alignment: .topLeading) {
            if ClaudeConfig.isMock {
                VStack(alignment: .leading, spacing: 0) {
                    ClaudeFocusProbeTag()
                    ClaudeScrollProbeTag()
                }
            }
        }
        .overlay(alignment: .leading) {
            if ClaudeConfig.isMock, FocusGuard.forcedHardwareKeyboard { ClaudeFocusGuardDebugControls() }
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

    /// 段階 → Dynamic Type の大きさ(0 は端末の設定に従う)
    static func typeSize(_ step: Int) -> ClosedRange<DynamicTypeSize> {
        let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility2]
        guard step != 0 else { return DynamicTypeSize.xSmall...DynamicTypeSize.accessibility5 }
        let s = sizes[max(0, min(sizes.count - 1, 3 + step))]
        return s...s
    }
}

/// 通知と再接続の帯。session の notice / linkState だけで描き直される。
private struct ClaudeStatusBanners: View {
    @ObservedObject var session: ClaudeSession

    var body: some View {
        if let notice = session.notice {
            noticeBanner(notice)
        }
        if session.linkState == .reconnecting {
            Label("再接続しています…", systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemBackground))
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

/// 会話の表示。store(項目・作業中)だけを観測する。入力が store の参照だけなので、親の評価では描き直されない。
private struct ClaudeTimelineHost: View {
    @ObservedObject var store: ClaudeTimelineStore

    var body: some View {
        ClaudeTimelineView(items: store.items, busy: store.busy, historyLoaded: store.historyLoaded,
                           onResend: { ClaudeSession.shared.send(text: $0) })
    }
}

private struct ClaudeTopBar: View {
    @ObservedObject var session: ClaudeSession
    @ObservedObject var router: ClaudeViewerRouter
    @Binding var showDetails: Bool
    @Binding var textSizeStep: Int

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
                // ファイル一覧は、CI の画面テストがまだ通らないので、この版では出さない(docs/claude-tab-inventory.md の宿題)。
                // 本文中のパスから開く機能は別で、こちらは出している。
                if ClaudeConfig.fileBrowserEnabled {
                    Button {
                        router.browseFiles(startDir: session.status.cwd)
                    } label: {
                        Image(systemName: "folder")
                            .font(.footnote)
                    }
                    .accessibilityLabel("ファイル")
                    .accessibilityIdentifier("claude.openFiles")
                }
                moreMenu
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

    /// 詳細の表示・文字の大きさ・claude.ai で開く
    private var moreMenu: some View {
        Menu {
            Toggle(isOn: $showDetails) {
                Label("内部の行も表示", systemImage: "eye")
            }
            Menu {
                Picker("文字の大きさ", selection: $textSizeStep) {
                    Text("端末の設定").tag(0)
                    Text("小").tag(-1)
                    Text("やや大").tag(1)
                    Text("大").tag(2)
                    Text("特大").tag(4)
                }
            } label: {
                Label("文字の大きさ", systemImage: "textformat.size")
            }
            if let s = session.status.remoteURL, let url = URL(string: s) {
                Button {
                    router.open(url)
                } label: {
                    Label("claude.ai で開く", systemImage: "safari")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.footnote)
        }
        .accessibilityLabel("その他")
        .accessibilityIdentifier("claude.more")
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
            .onAppear { ClaudeHangWatchdog.start() }
    }
}

/// UI テスト用(`--claude-mock --claude-hw-keyboard` のときだけ出す): FocusGuard が戻した回数と出来事の札。
/// フォーカスを奪う動作は起動引数(-claude.hwLossInterval / -claude.hwLossMax)で FocusGuard 側のタイマが行う。
private struct ClaudeFocusGuardDebugControls: View {
    @ObservedObject private var guardState = FocusGuard.shared

    var body: some View {
        Text("restored=\(guardState.restoredCount) trace=\(guardState.trace.joined(separator: ";")) last=\(guardState.lastDecision)")
            .font(.system(size: 2))
            .opacity(0.02)
            .allowsHitTesting(false)
            .accessibilityIdentifier("claude.debug.guard")
            .accessibilityLabel("restored=\(guardState.restoredCount) trace=\(guardState.trace.joined(separator: ";")) last=\(guardState.lastDecision)")
            .onAppear { FocusGuard.shared.startDebugLossIfRequested() }
    }
}

/// UI テスト用の見えない札(一覧のスクロール位置と跳びの回数)。ClaudeConfig.isMock のときだけ出す。
private struct ClaudeScrollProbeTag: View {
    @ObservedObject private var probe = ClaudeScrollProbe.shared

    var body: some View {
        Text(probe.summary)
            .font(.system(size: 2))
            .opacity(0.02)
            .allowsHitTesting(false)
            .accessibilityIdentifier("claude.debug.scroll")
            .accessibilityLabel(probe.summary)
    }
}
