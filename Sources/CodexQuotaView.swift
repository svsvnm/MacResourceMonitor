import SwiftUI
import AppKit

struct CodexQuotaView: View {
    @ObservedObject var model: CodexQuotaMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(InterfacePalette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex 订阅")
                        .font(.system(size: 20, weight: .semibold))
                    Text(model.state.snapshot?.plan ?? "读取当前 Codex 登录账号")
                        .font(InterfaceTypography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.state.isRefreshing { ProgressView().controlSize(.small) }
                Button("刷新额度") { model.refresh(force: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.state.isRefreshing)
            }
            .padding(18)
            .stableDashboardCard()

            if let error = model.state.error {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(InterfaceTypography.caption)
                    .foregroundStyle(.orange)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .stableDashboardCard()
            }

            HStack(alignment: .top, spacing: 14) {
                quotaCard(model.state.snapshot?.primary, fallbackTitle: "会话额度")
                quotaCard(model.state.snapshot?.secondary, fallbackTitle: "每周额度")
            }

            VStack(alignment: .leading, spacing: 12) {
                Label(statusText, systemImage: "clock")
                Label("页面或菜单打开时每分钟更新；低电量模式或温度压力较高时每 5 分钟更新。", systemImage: "leaf")
                Label("关闭页面和菜单后停止查询。手动刷新可立即检查最新额度。", systemImage: "pause.circle")
                Label("读取订阅额度，不发送对话，不扫描历史记录，不兑换额度重置次数。", systemImage: "lock.shield")
                Text("需要已登录的 Codex。若提示授权失效，请在 Codex 中重新登录后刷新。API Key 账号不一定提供订阅额度。")
                    .foregroundStyle(.secondary)
                Link("打开 Codex 用量页面", destination: URL(string: "https://chatgpt.com/codex/settings/usage")!)
            }
            .font(InterfaceTypography.caption)
            .foregroundStyle(.secondary)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stableDashboardCard()
        }
        .onAppear { model.setActive(true, for: .dashboard) }
        .onDisappear { model.setActive(false, for: .dashboard) }
    }

    private var statusText: String {
        guard let date = model.state.snapshot?.updatedAt else {
            return model.state.isRefreshing ? "正在查询订阅额度…" : "尚未获取额度"
        }
        let prefix = model.state.error == nil ? "最近更新" : "显示上次成功结果"
        return "\(prefix)：\(date.formatted(date: .abbreviated, time: .standard))"
    }

    private func quotaCard(_ window: CodexQuotaWindow?, fallbackTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(window?.periodTitle ?? fallbackTitle)
                .font(InterfaceTypography.bodyEmphasized)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(quotaPercent(window))
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("剩余")
                    .font(InterfaceTypography.caption)
                    .foregroundStyle(.secondary)
            }
            if let remaining = window?.remainingPercent {
                ProgressView(value: remaining, total: 100)
                    .tint(remaining < 10 ? .orange : InterfacePalette.accent)
                Text(String(format: "已使用 %.0f%%", 100 - remaining))
                    .foregroundStyle(.secondary)
            } else {
                Text(model.state.isRefreshing ? "正在查询…" : "暂未提供此窗口的额度")
                    .foregroundStyle(.secondary)
            }
            Divider()
            if let reset = window?.resetsAt {
                Text("重置时间 \(reset.formatted(date: .abbreviated, time: .shortened))")
                Text(reset > Date() ? "约 \(reset.formatted(.relative(presentation: .numeric)))重置" : "已到重置时间，等待下次查询确认")
                    .foregroundStyle(.secondary)
            } else {
                Text("重置时间暂不可用").foregroundStyle(.secondary)
            }
        }
        .font(InterfaceTypography.caption)
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .stableDashboardCard()
        .transaction { $0.animation = nil }
    }
}

/// Observes only the low-frequency quota store; quota updates do not invalidate the whole menu.
struct CodexQuotaMenuSummary: View {
    @ObservedObject var model: CodexQuotaMonitor
    let openUsage: () -> Void

    var body: some View {
        Button(action: openUsage) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Codex 额度", systemImage: "terminal")
                        .font(InterfaceTypography.captionEmphasized)
                    Spacer()
                    if model.state.isRefreshing { ProgressView().controlSize(.mini) }
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                if let error = model.state.error {
                    Text(error.localizedDescription)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let snapshot = model.state.snapshot {
                    HStack {
                        Text("\(snapshot.primary?.periodTitle ?? "会话") 剩余 \(quotaPercent(snapshot.primary))")
                        Spacer(minLength: 4)
                        Text("\(snapshot.secondary?.periodTitle ?? "每周") 剩余 \(quotaPercent(snapshot.secondary))")
                    }
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                } else {
                    Text(model.state.isRefreshing ? "正在查询…" : "打开查看订阅额度")
                        .foregroundStyle(.secondary)
                }
            }
            .font(InterfaceTypography.microMetadata)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { model.setActive(true, for: .menuBar) }
        .onDisappear { model.setActive(false, for: .menuBar) }
    }
}

private func quotaPercent(_ window: CodexQuotaWindow?) -> String {
    guard let remaining = window?.remainingPercent else { return "--" }
    return String(format: "%.0f%%", remaining)
}
