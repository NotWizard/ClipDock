# ClipDock

A native macOS clipboard manager that keeps copied content within reach.

原生 macOS 剪贴板工具：从桌面底部唤起，横向浏览、直接搜索、随时取回。

![ClipDock](docs/public/panel-live.jpg)

*合成演示数据。浅色卡头由来源 App 图标生成；正文和面板随 macOS 外观切换。*

## 下载

从 [Releases](https://github.com/NotWizard/ClipDock/releases/latest) 下载 `ClipDock-<version>-macos-arm64.zip`，解压后将 **ClipDock.app** 放入“应用程序”。

- macOS 14 或更新版本。当前安装包为 Apple Silicon；Intel 构建尚未实测。
- 当前发布使用本地 ad-hoc 签名，尚无 Developer ID 签名与 Apple 公证。macOS 可能拦截首次打开；发行包的签名与公证仍是后续发布工作。
- 直接回贴需要在 macOS 隐私与安全性设置中授予辅助功能权限；未授权时会明确提示“已复制”，可手动粘贴。
- 与其他剪贴板工具共用快捷键时会提示冲突，可在设置中重新录制。

## 使用

| 操作 | 快捷键 / 行为 |
|---|---|
| 显示剪贴板 | ⇧⌘V；备用 ⌃⌘V |
| 横向选择 | ← / →；单击选择，双击提交 |
| 搜索 | 直接输入，或 ⌘F |
| 切换 Pinboard | 浏览时 ⌘← / ⌘→ |
| 附属预览 | Space；Esc 先关预览 |
| 提交 / 复制 | Return / ⌘C |
| 快速提交 | ⌘1–9 |
| 纯文本模式 | 提交时按住 Shift |
| 退出搜索 / 面板 | Esc 依次清空查询、收起搜索、关闭面板 |

支持文本、链接、图片、颜色、文件及原始剪贴板格式；保留 Pinboard、固定条目、批量操作、过滤、OCR、链接预览、暂停与隐私排除。管理窗口可从面板的更多菜单打开。

## 更新检查

设置 → 关于提供“检查更新”和“每 24 小时自动检查更新”。自动检查默认启用，记住上次检查时间，并在应用运行或从睡眠唤醒后检查到期更新。同一版本只自动提醒一次；手动检查可再次打开更新窗口。

发现新版后显示更新说明与下载按钮，管理窗口左下角也会保留“有可用更新”入口。下载按钮打开 GitHub Release 页面，由用户下载并安装。

![关于与更新](docs/public/about-updates.png)

*截图中的 v1.3.0 为合成演示版本。当前正式版本以 Releases 为准。*

更新源默认是本仓库的正式 Release。客户端使用 GitHub 的 [Latest Release API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)，校验版本与仓库链接，忽略草稿、预发布和降级；网络失败、限流与尚无正式 Release 分别显示原因。不需要 GitHub 登录或 Token。

## 数据与隐私

资料库存储在本机。可选链接预览会访问对应网站；启用更新检查会访问 GitHub。无账号、云同步或遥测。

从旧版 Trove 升级时沿用原 Bundle ID、偏好和 `~/Library/Application Support/Trove/`，无需迁移资料库。内部 Swift 目标也保留旧名称以保持构建与存储兼容，应用显示名称为 ClipDock。

## 从源码构建

只依赖 Apple 框架，Command Line Tools 即可构建。

```bash
./Scripts/build.sh
open build/ClipDock.app
```

```bash
# 独立临时库 / 偏好 / 私有 pasteboard，不改个人资料库
./build/ClipDock.app/Contents/MacOS/Trove --selftest
./build/ClipDock.app/Contents/MacOS/Trove --check-updates
./build/ClipDock.app/Contents/MacOS/Trove --check-panel /tmp/clipdock-panel-check

# 先退出其他运行实例和占用相同快捷键的应用
./build/ClipDock.app/Contents/MacOS/Trove --check-hotkeys
```

1.2.0 的验证为 34 项核心断言、33 项更新断言、22 项原生面板断言，加上真实窗口检查。物理全局快捷键、跨应用回贴、中文候选选择、外部拖放以及多屏/全屏/Spaces 的完整矩阵仍未全部验收。

演示模式使用独立临时资料库：

```bash
./build/ClipDock.app/Contents/MacOS/Trove --demo
./build/ClipDock.app/Contents/MacOS/Trove --demo-update
./build/ClipDock.app/Contents/MacOS/Trove --snapshot quick /tmp/clipdock.png --appearance light --demo
```

`--demo-update` 使用标明合成的未来版本展示提醒。仓库里的展示图来自合成演示内容或真实原生视图渲染；个人剪贴板历史和本机逆向取证材料不属于发布内容。

## 发布新版

1. 修改 `Resources/Info.plist` 的版本与 build；fork 项目时同时修改 `GitHubRepository`。
2. 运行上述检查，再执行 `./Scripts/package-release.sh`。
3. 创建同版本 tag（例如 `v1.3.0`），将 zip 和 SHA-256 文件附在正式 GitHub Release。安装包名携带构建架构。
4. 现有客户端下次检查时就会提示。更新检查检测版本变化，未实现应用内自动替换安装。

本项目为独立实现，不分发其他剪贴板产品的代码、商业服务或图标素材。纯文本编辑可用；富文本样式、图片变换和一次拖出多个文件仍有范围限制。

## License

[MIT](LICENSE)
