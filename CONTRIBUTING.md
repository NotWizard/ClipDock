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

1.2.8 起，维护者使用固定的自签名证书构建发行包；公有证书位于 `Resources/Signing/ClipDock.cer`。没有对应私钥时，本地开发构建仍可使用 ad-hoc 签名，脚本会明确提示授权可能重置；正式打包不允许降级到 ad-hoc。

## 验证

在仓库根目录运行。以下检查使用独立的临时资料库与偏好。核心检查使用私有 pasteboard；面板提交检查会暂时写入系统剪贴板，保存并恢复原有格式，期间发生的新复制不会被恢复操作覆盖：

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

正式Release的ZIP、SHA-256和签名appcast.xml均已回下载并与本地测试产物逐字节核对。macOS URLSession从公开地址下载三个附件均返回HTTP 200，校验值一致；真实GitHub Release发现、缓存及提醒检查通过。

2026-10-22：用户完成正式1.2.3（6）到1.2.4（7）的更新并确认重启。随后被动核对安装版本、运行进程和完整应用签名，可执行文件与Release一致；升级前的全部条目、Pinboard、原始载荷及19项用户偏好均保留。界面操作与自动重启过程未独立观察。

### 1.2.5 的图标与关于页验证

核心检查45项、更新检查43项通过；最终安装包的应用签名、更新信息与安装包签名、SHA-256及解压内容均已核对。独立临时应用的更新集成测试通过4类用例：篡改更新信息、损坏安装包、取消下载，以及正常替换与重启，并保留合成资料与偏好。该低版本测试客户端使用当前更新器代码，不等同于已发布的旧版本。

原生渲染覆盖图标16–256 pt、22 pt菜单栏记录/暂停状态，以及关于、引导和更新窗口的深浅色外观。个人安装版未被测试脚本替换；新版在真实菜单栏中的点击、实时桌面背景对比及个人安装版升级过程未独立验收。

### 1.2.6 的搜索点击回归

核心检查45项、更新检查43项和解锁桌面后的原生面板检查33项全部通过；4类隔离安装集成测试通过。修复前，聚焦的原生文本编辑器接收了收起状态搜索图标的点击；修复后，首次点击及重新唤起后的点击均展开搜索，并保留原有编辑器、文本编辑与中文输入法行为。

搜索回归改为向真实NSPanel发送原生鼠标按下/释放事件，不再直接调用搜索动作。锁屏时的4项焦点、菜单与动画相关失败已在解锁后完整复验通过；这些事件与原生截图不代替人工跨应用使用验收。

### 1.2.7 的直接回贴回归

核心检查47项、更新检查43项、原生面板检查37项及独立接收器回贴检查8项通过；4类隔离安装集成测试通过。提交时先启动浮层收起动画，窗口隐藏后恢复原应用输入焦点、发送一次粘贴按键，再调整历史顺序。覆盖关闭前卡片顺序不变、关闭取消、重复提交不重复粘贴，以及下次唤起选中最近使用的条目。

```bash
python3 Scripts/check-paste.py /tmp/clipdock-paste-check
./build/ClipDock.app/Contents/MacOS/Trove --paste-status
```

回贴检查需要已解锁的桌面与有效的辅助功能/发送事件权限。脚本建立独立原生文本接收器，在 `left--right` 的中间保留插入点，通过生产面板的提交路径验证实际收到 `left-CLIPDOCK_CARET_TEST-right`，并确认只收到一次粘贴；它不会直接调用接收器的粘贴动作。原剪贴板的所有表示仅在内存中备份，测试结束时若剪贴板仍归测试所有才恢复；合成条目带临时标记。诊断命令只读取版本、授权、粘贴开关与前台应用标识，不输出剪贴板内容。

这些检查验证了跨进程回贴及原生面板行为，未模拟物理全局快捷键或卡片双击，不代表所有第三方应用、多屏与Spaces组合均已验收。个人安装版未被测试脚本替换。

### 1.2.8 的固定签名与授权保留验证

核心47项、更新43项、原生面板37项、原生签名8项、应用自身授权2项、真实回贴8项检查通过，共145项；另有5类隔离安装集成测试通过。两个不同的可执行文件拥有不同代码哈希，但保持同一证书与Bundle ID要求。通过LaunchServices启动后，首次授权前两者均返回辅助功能/发送事件权限为false；用户授权一次后，两者均返回true，期间未再次授权。真实接收器收到原光标位置的合成文本且仅一次，面板关闭、使用后排序和下次唤起均通过。第一次回贴检查中的粘贴后焦点项未通过，复验完整8项通过，未放宽检查条件。

本机1.2.7安装版已通过正常退出、备份及替换安装为1.2.8，原有36个条目、1个Pinboard和119个原始载荷文件在替换时均保留；用户在系统界面完成了签名身份切换后的首次辅助功能授权。签名身份测试验证了同一授权适用于两份不同代码，未把物理全局快捷键或尚未发布的未来正式版本升级视为已实测。

## 演示与截图

应用图标的生成模型源图与完整提示词位于 `Resources/Artwork/`。`Scripts/make-icon.swift` 仅为该源图生成原生尺寸和光学留白；菜单栏图标由同一套折角卡片与托盘轮廓绘制为22 pt模板PDF，包含记录和暂停两种状态。构建不需要重新调用生成模型。

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

### 固定的应用签名身份

1.2.8 起，发行包使用 `ClipDock Local Code Signing` 自签名证书。原生 designated requirement 同时绑定应用 Bundle ID 与证书指纹，不包含版本的代码哈希，也不以名称相同代替证书校验。该方案无需 Apple Developer 账号，但不提供 Apple 公证或 Gatekeeper 的开发者认证。证书转换时仍需用户手动授权一次；保持授权的目标适用于后续沿用同一身份的版本。

公开证书固定在 `Resources/Signing/ClipDock.cer`，私钥保存在仓库外的 `~/Library/Application Support/ClipDock Release Signing/` 独立钥匙串中；`CLIPDOCK_SIGNING_DIR` 可指定外部备份目录。密码与加密的 `app-signing-identity.p12` 也在这个私有目录中，权限为600。请将整个私有目录另行安全备份，不能提交或放进安装包。丢失私钥后不能仅靠公开证书恢复同一身份。

`Scripts/sign-app.py --init` 仅供首次创建独立身份使用，已有证书或私钥时会拒绝运行。常规更新必须恢复并复用既有身份，不能每次初始化。签名不要求用户导入证书为系统信任根，也不改写辅助功能权限数据库。

```bash
python3 Scripts/sign-app.py build/ClipDock.app --verify
python3 Scripts/check-signing.py /tmp/clipdock-signing-check
python3 Scripts/check-updater.py /tmp/clipdock-updater-check
```

签名检查需要维护者的固定签名身份，验证两个不同可执行文件互认同一证书与标识，并拒绝相同标识的ad-hoc副本、其他标识和篡改资源。安装检查从1.2.8起使用同一签名助手，覆盖5类用例：篡改更新信息、损坏安装包、取消下载、固定签名间的正常替换重启，以及旧ad-hoc到固定签名的迁移。

辅助功能必须在应用自己的启动身份下检查。通过终端直接运行二进制可能继承终端或代理的权限，因此回贴检查改为经LaunchServices启动测试宿主；不会以终端里的授权状态替代App实际授权。用户手动授权固定身份后，可运行下面的检查，确认两份不同二进制都保留辅助功能及发送事件权限：

```bash
python3 Scripts/check-signing.py /tmp/clipdock-permission-check --check-permissions
python3 Scripts/check-paste.py /tmp/clipdock-paste-check
```

权限检查不发送粘贴事件，仅调用系统授权查询，测试产物使用正式Bundle ID与固定证书；回贴检查将一次真实粘贴发送到独立的合成文本接收器。两种检查均不写入个人资料库或替换安装版。未授权时应明确失败，不能声称已完成升级后的授权保留验收。
