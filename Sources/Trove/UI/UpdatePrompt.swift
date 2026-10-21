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
                    Text("\(AppIdentity.name) 有新版本").font(.system(size: 20, weight: .semibold))
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
            Text("在 GitHub Release 页面下载新版，安装时会保留现有资料库。")
                .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.72))
            HStack {
                Spacer()
                Button("暂不更新", action: close).keyboardShortcut(.cancelAction)
                Button("前往下载") { updates.openDownload(); close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 440)
        .background(Theme.windowBackground)
        .onChange(of: updates.available) { _, release in if release == nil { close() } }
    }
}
