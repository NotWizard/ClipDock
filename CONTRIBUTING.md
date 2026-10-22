# 参与 ClipDock

欢迎提交可复现的问题、交互建议和 Pull Request。开始较大的功能前，请先在 [Issues](https://github.com/NotWizard/ClipDock/issues) 描述使用场景，便于确认范围。

## 本地构建

需要 macOS 14 或更新版本、Apple Command Line Tools，以及 Swift 5.9 或更新版本。应用界面使用 Apple 原生框架；更新安装依赖 Sparkle 2.10.0，由 Swift Package Manager 按固定版本和校验值获取。第三方许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

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

### 1.2.2 的交互回归

核心检查 45 项、更新检查 33 项、原生面板检查 30 项通过。覆盖搜索图标首次操作、现有编辑器焦点、输入法组合状态、成功取用后的排序及持久化、批量顺序、失败写入、Pinboard 手动顺序，以及指南的窗口复用、偏好保留和关闭行为。实机从文本编辑用全局快捷键唤起后，单击搜索图标即可立即输入并筛选；指南三步均检查了原生深浅色渲染。

### 1.2.3 的更新安装验证

核心检查 45 项、更新检查 43 项、原生面板检查 30 项通过。更新检查新增实际字节进度、长度溢出、取消后重试、校验阶段不可取消、安装确认和重复触发保护。原生面板检查需要已解锁的桌面；锁屏时会有焦点或动画检查失败，失败时命令会正确返回非零状态。本次解锁后已完整复验通过。

```bash
python3 Scripts/check-updater.py /tmp/clipdock-updater-check
```

此脚本使用临时签名密钥和 `app.trove.updater-test.*` 的临时应用，测试被篡改的更新信息、损坏的安装包、真实下载取消，以及真实替换与重新启动。它比较更新前后的合成条目、Pinboard、快捷键与保留数量，并核对安装后的可执行文件。整个过程不会更新“应用程序”中的安装版，也不会访问个人资料库；临时测试旧版包含新更新器，不能称为已发布的 1.2.2。

在本机“应用程序”目录，另用带新更新器的低版本过渡包完成了“检查更新 → 从 GitHub 下载正式 1.2.3 → 校验 → 安装替换 → 自动重启”的点击验证。过渡包的版本标记为 1.2.2，代码来自 1.2.3；正式发布的旧 1.2.2 仍需手动升级一次。安装后的可执行文件与 Release 一致，原有条目、Pinboard、原始载荷及 19 项用户偏好保持不变；管理页就绪提醒的实际无障碍标签正确，再次检查显示“已是最新版本”。

### 1.2.4 的浮层位置回归

核心检查45项、更新检查43项、原生面板检查31项通过。真实NSPanel检查确认按显示器的完整frame定位、窗口层级高于Dock（21/20）、原生搜索按钮和编辑菜单、附属预览、收起及重新唤起均正常；副屏负坐标定位计算保持正确。测试与生产浮层均保留非激活行为。浅色、深色浏览截图已检查，中央导航位置不因右侧原生菜单收紧而变化；另通过CUA确认“更多”菜单能打开，并实际输入搜索词得到对应条目。完整物理多屏、Dock方向和Spaces矩阵未作完成声明。

正式Release的ZIP、SHA-256和签名appcast.xml均已回下载并与本地测试产物逐字节核对。macOS URLSession从公开地址下载三个附件均返回HTTP 200，校验值一致；真实GitHub Release发现、缓存及提醒检查通过。1.2.3到1.2.4的应用内安装和自动重启尚待实机验收。

## 演示与截图

公开图片使用合成演示内容，不使用个人剪贴板历史。演示模式会建立独立的临时资料库；`--demo-update` 中的未来版本仅用于展示提醒。

```bash
./build/ClipDock.app/Contents/MacOS/Trove --demo
./build/ClipDock.app/Contents/MacOS/Trove --demo-update
./build/ClipDock.app/Contents/MacOS/Trove --demo-onboarding
./build/ClipDock.app/Contents/MacOS/Trove --snapshot quick /tmp/clipdock-light.png --appearance light --demo
./build/ClipDock.app/Contents/MacOS/Trove --snapshot quick /tmp/clipdock-dark.png --appearance dark --demo
./build/ClipDock.app/Contents/MacOS/Trove --snapshot main /tmp/clipdock-manager.png --appearance light --demo-update
./build/ClipDock.app/Contents/MacOS/Trove --snapshot about /tmp/clipdock-about.png --appearance light --demo-update
./build/ClipDock.app/Contents/MacOS/Trove --snapshot update /tmp/clipdock-update.png --appearance light --demo-update
./build/ClipDock.app/Contents/MacOS/Trove --snapshot update-downloading /tmp/clipdock-download.png --appearance light --demo-update
./build/ClipDock.app/Contents/MacOS/Trove --snapshot update-ready /tmp/clipdock-ready.png --appearance dark --demo-update
./build/ClipDock.app/Contents/MacOS/Trove --snapshot update-error /tmp/clipdock-error.png --appearance dark --demo-update
./build/ClipDock.app/Contents/MacOS/Trove --snapshot onboarding /tmp/clipdock-guide.png --appearance light --demo
./build/ClipDock.app/Contents/MacOS/Trove --snapshot onboarding-keys /tmp/clipdock-guide-keys.png --appearance light --demo
./build/ClipDock.app/Contents/MacOS/Trove --snapshot onboarding-privacy /tmp/clipdock-guide-privacy.png --appearance dark --demo
```

`--snapshot` 通过真实 AppKit / SwiftUI 视图渲染，不代替物理输入或跨应用行为验证。提交展示图前检查内容与版本标注。公开图片统一放在 `docs/public/`；本机取证资料及其他 `docs/` 内容不纳入发布。

## 提交修改

- 说明问题发生的条件、修改后的行为与验证方式；涉及界面时附合成数据截图。
- 保留 macOS 原生输入、辅助功能标签、深浅色外观与“减少动态效果”行为。
- 涉及资料库的修改必须保留已有条目、Pinboard 与原始剪贴板格式。
- 报告问题时不要附带密码、Token、个人剪贴板历史或含隐私的截图。

## 发布新版

1. 更新 `Resources/Info.plist` 中的版本号与 build。Fork 后作为独立发行时，修改 `GitHubRepository` 为自己的 `owner/repository`。
2. 构建并运行相关检查及安装集成脚本，补齐本次修改涉及的人工验收。设置更新签名私钥路径后，执行 `./Scripts/package-release.sh` 生成 ZIP、SHA-256 和已签名的 `appcast.xml`。
3. 创建与版本一致的 tag，例如 `v1.3.0`，发布正式 GitHub Release，附上 `build/` 中生成的 ZIP、校验文件和 `appcast.xml`。打包脚本使用当前主机架构，不执行通用二进制交叉构建。
4. 下载已发布的文件，核对 SHA-256、更新信息与安装包签名、解压与版本信息，再验证带更新器的旧版测试客户端的下载、替换与重启流程。

客户端通过 [GitHub Latest Release API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release) 发现版本，安装时从正式 Release 的 `appcast.xml` 获取经过签名的更新信息。Sparkle 在解压前校验安装包，再负责替换与重启。

### 更新签名

`Resources/Info.plist` 中的 `SUPublicEDKey` 是公开的 Ed25519 公钥。对应私钥必须保存在仓库之外并安全备份，不能提交、放进安装包或写入日志。

```bash
export CLIPDOCK_UPDATE_KEY_FILE="/你的安全目录/ed25519-private-key"
./Scripts/package-release.sh
```

私钥文件使用 Sparkle 支持的 Base64 密钥格式；可用 Sparkle 的 `generate_keys` 工具管理密钥，参见[官方签名指南](https://sparkle-project.org/documentation/)。本机默认路径是 `~/Library/Application Support/ClipDock Release Signing/ed25519-private-key`。打包脚本缺少私钥时会停止；已签名的更新信息后续修改需要重新签名。

Fork 的独立发行必须生成自己的密钥，同时更新 `SUPublicEDKey`、`SUFeedURL` 和 `GitHubRepository`。原项目用户仅信任原项目密钥；不要把同一公钥误用于无法取得私钥的 Fork。Ed25519 更新签名与 Apple Developer ID 签名用途不同，Developer ID 签名和公证仍需另行完成。
