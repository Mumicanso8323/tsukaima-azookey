import SwiftUI

/// 「Claude」タブ(docs/converse-protocol.md 2章): 時系列表示 + 入力欄 + モデル/エフォート/プロジェクト切替・中断。
/// 会話モード(Converse)と同じ常駐セッションを共有する — ここで送った文字も、声で送ったものも同じ履歴に出る。
struct ClaudeTabView: View {
    @ObservedObject private var session = ClaudeSession.shared

    var body: some View {
        VStack(spacing: 0) {
            ClaudeTopBar(session: session)
            Divider()
            ClaudeTimelineView(events: session.events)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ClaudeComposerView(session: session)
        }
        .onAppear {
            session.connect()
            Task {
                await session.refreshProjects()
                await session.refreshState()
            }
        }
    }
}

private struct ClaudeTopBar: View {
    @ObservedObject var session: ClaudeSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.linkState == .open ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
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
                    Button(m) { session.set(model: m) }
                }
            } label: {
                Text(session.status.model ?? "モデル").font(.footnote)
            }
            Menu {
                ForEach(ClaudeConfig.efforts, id: \.self) { e in
                    Button(e) { session.set(effort: e) }
                }
            } label: {
                Text(session.status.effort ?? "エフォート").font(.footnote)
            }
            if session.status.busy {
                Button {
                    session.interrupt()
                } label: {
                    Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
