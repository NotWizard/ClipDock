import AppKit
import SwiftUI

struct UpdatePrompt: View {
    @ObservedObject var updates: UpdateChecker
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: TroveBrand.appIcon()).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text(updates.installState == .ready ? "更新已就绪" : "\(AppIdentity.name) 有新版本")
                        .font(.system(size: 20, weight: .semibold))
                    Text("\(Bundle.main.shortVersion) → \(updates.available?.tagName ?? "")")
                        .font(.system(size: 13)).foregroundStyle(.primary.opacity(0.72))
                }
            }
            if let body = updates.available?.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    Text(String(body.prefix(4000))).font(.system(size: 13)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 130)
            }
            if updates.installState == .downloading {
                VStack(alignment: .leading, spacing: 6) {
                    if let progress = updates.downloadProgress { ProgressView(value: progress) }
                    else { ProgressView().controlSize(.small) }
                    Text(updates.transferDescription).font(.system(size: 12)).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("更新下载进度")
            }
            HStack(alignment: .top, spacing: 8) {
                if updates.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else if [.checking, .cancelling, .preparing, .installing].contains(updates.installState) {
                    ProgressView().controlSize(.small)
                } else if updates.installState == .ready {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text(updates.installState == .idle ? "直接下载并校验更新包，历史记录和偏好会保留。" : updates.status)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.primary.opacity(0.75))
            Text(updates.installState == .ready ? "现在重启即可使用新版；稍后退出 App 时也会完成安装。" : (updates.installState == .failed ? "本次更新已停止，可以重试或稍后重新检查。" : "下载期间可继续使用。准备就绪后，再选择安装并重启。"))
                .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.72))
            Spacer(minLength: 0)
            HStack {
                if updates.canCancelDownload {
                    Button("取消下载") { updates.cancelDownload() }
                }
                Spacer()
                Button(updates.installationInProgress ? "稍后查看" : "暂不更新", action: close).keyboardShortcut(.cancelAction)
                Button(updates.updateActionTitle) { updates.performUpdateAction() }
                    .disabled(!updates.canPerformUpdateAction)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 440, height: 420, alignment: .topLeading)
        .background(Theme.windowBackground)
        .onChange(of: updates.available) { _, release in if release == nil { close() } }
    }
}
