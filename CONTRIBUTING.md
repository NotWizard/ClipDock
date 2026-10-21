# 参与 ClipDock

欢迎提交可复现的问题、交互建议和 Pull Request。开始较大的功能前，请先在 [Issues](https://github.com/NotWizard/ClipDock/issues) 描述使用场景，便于确认范围。

## 本地构建

需要 macOS 14 或更新版本、Apple Command Line Tools，以及 Swift 5.9 或更新版本。项目仅使用 Apple 框架，无第三方包依赖。

```bash
git clone https://github.com/NotWizard/ClipDock.git
cd ClipDock
./Scripts/build.sh
open build/ClipDock.app
```

应用显示名为 ClipDock。Swift Package 目标、可执行文件、Bundle ID 和资料库目录沿用旧名 Trove，以兼容已有数据；不要仅为统一名称修改这些身份标识。

## 验证

在仓库根目录运行。前三组检查使用独立的临时资料库、偏好与私有 pasteboard：

```bash
./build/ClipDock.app/Contents/MacOS/Trove --selftest
./build/ClipDock.app/Contents/MacOS/Trove --check-updates
./build/ClipDock.app/Contents/MacOS/Trove --check-panel /tmp/clipdock-panel-check
```

快捷键注册检查需要先退出其他 ClipDock 实例及占用相同组合键的应用：

```bash
./build/ClipDock.app/Contents/MacOS/Trove --check-hotkeys
```

要对实际 GitHub 正式 Release 执行隔离验证：

```bash
./build/ClipDock.app/Contents/MacOS/Trove --check-updates --live
```

这个命令使用旧版本测试值验证发现、校验、缓存与通知流程，需要联网；它不会把个人安装的版本改成测试版本。

### 1.2.0 的验证记录

2026-10-21：核心检查 34 项、更新检查 33 项、原生面板检查 22 项通过；快捷键启用与禁用状态的注册检查通过。已回验正式 Release 的 ZIP 与 SHA-256，安装版 1.2.0（3）在“关于”中手动检查后显示“已是最新版本”，检查时间刷新。另以隔离旧版本测试值验证了线上新版本发现流程。

这些检查不等于所有实机组合均已验收。物理全局快捷键到跨应用直接回贴、中文输入候选、外部拖放、多屏、全屏与 Spaces 的完整矩阵仍需人工验证。当前预编译包仅验证 Apple Silicon，采用 ad-hoc 签名，尚无 Developer ID 签名与 Apple 公证。

### 1.2.1 的取色回归

核心检查 40 项、更新检查 33 项、原生面板检查 22 项通过。新增用例覆盖全图色块与中心色的竞争、红色色相边界、黑白图标、微小彩色角标、透明边缘，以及覆盖整圈色相的卡头文字对比度。另用 14 个本机来源图标（含 Xnip Helper）对比取色，并检查原生浮层的深浅色外观。

## 演示与截图

公开图片使用合成演示内容，不使用个人剪贴板历史。演示模式会建立独立的临时资料库；`--demo-update` 中的未来版本仅用于展示提醒。

```bash
./build/ClipDock.app/Contents/MacOS/Trove --demo
./build/ClipDock.app/Contents/MacOS/Trove --demo-update
./build/ClipDock.app/Contents/MacOS/Trove --snapshot quick /tmp/clipdock-light.png --appearance light --demo
./build/ClipDock.app/Contents/MacOS/Trove --snapshot quick /tmp/clipdock-dark.png --appearance dark --demo
./build/ClipDock.app/Contents/MacOS/Trove --snapshot main /tmp/clipdock-manager.png --appearance light --demo-update
./build/ClipDock.app/Contents/MacOS/Trove --snapshot about /tmp/clipdock-about.png --appearance light --demo-update
./build/ClipDock.app/Contents/MacOS/Trove --snapshot update /tmp/clipdock-update.png --appearance light --demo-update
```

`--snapshot` 通过真实 AppKit / SwiftUI 视图渲染，不代替物理输入或跨应用行为验证。提交展示图前检查内容与版本标注。公开图片统一放在 `docs/public/`；本机取证资料及其他 `docs/` 内容不纳入发布。

## 提交修改

- 说明问题发生的条件、修改后的行为与验证方式；涉及界面时附合成数据截图。
- 保留 macOS 原生输入、辅助功能标签、深浅色外观与“减少动态效果”行为。
- 涉及资料库的修改必须保留已有条目、Pinboard 与原始剪贴板格式。
- 报告问题时不要附带密码、Token、个人剪贴板历史或含隐私的截图。

## 发布新版

1. 更新 `Resources/Info.plist` 中的版本号与 build。Fork 后作为独立发行时，修改 `GitHubRepository` 为自己的 `owner/repository`。
2. 构建并运行相关检查，补齐本次修改涉及的人工验收。执行 `./Scripts/package-release.sh` 生成 ZIP 与 SHA-256 文件。
3. 创建与版本一致的 tag，例如 `v1.3.0`，发布正式 GitHub Release，附上 `build/` 中生成的 ZIP 与校验文件。打包脚本使用当前主机架构，不执行通用二进制交叉构建。
4. 下载已发布的文件，核对 SHA-256、解压与版本信息，再验证旧版本客户端的更新发现流程。

客户端读取 [GitHub Latest Release API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)，校验版本与仓库地址。更新是检查、提醒并打开下载页面，不包含应用内自动替换。Developer ID 签名与公证须在正式分发流程中另行完成。
