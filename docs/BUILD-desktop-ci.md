# 滑洲云图 ovimap —— GitHub Actions 双平台构建说明

> 面向：想拿 Windows / macOS 安装包，但手边没有对应机器的使用者。
> 目标：推一次代码 → 云端出两个压缩包 → 下载即用。

---

## 0. 一句话流程

推代码 / 手动触发 → Actions 里等两个任务变绿 → 在该次运行的 **Artifacts** 区下载
`ovimap-windows-x64-<版本>.zip` 与 `ovimap-macos-universal-<版本>.zip`。

---

## 1. 流水线结构

工作流文件：`.github/workflows/build-desktop.yml`

| 任务 | 运行环境 | 干什么 | 产物 |
|---|---|---|---|
| `build-windows` | `windows-latest` | analyze + test 门禁 → `flutter build windows --release` → zip | `ovimap-windows-x64-3.0.2.zip` |
| `build-macos` | `macos-latest` | analyze + test 门禁 → `flutter build macos --release` → ditto 打包 | `ovimap-macos-universal-3.0.2.zip` |

**两个任务各自独立跑测试**，而不是共用一个 Linux 测试任务。原因：
`test/platform_caps_test.dart`、`test/desktop_shell_wiring_test.dart` 等用例的断言
是按平台参数化的，Linux 全绿并不能证明 Windows / macOS 也绿。

**门禁规则**：静态分析或单元测试任一失败 → 该平台不出包。
`flutter analyze` 加了 `--no-fatal-infos`，只放行 **info** 级 lint（当前 68 条，
多为测试脚本里的 `print`）；**error 与 warning 仍然会让构建失败**。想收紧就删掉这个参数。

---

## 2. 触发方式

> 日常分支 / PR 门禁已交给 `.github/workflows/ci.yml`（ubuntu 1x，最便宜）。
> 本桌面工作流**只负责出包**，不再在每次 push 上跑。详见 [`BUILD-cloud.md`](BUILD-cloud.md)。

| 场景 | 做法 |
|---|---|
| 日常验证 / 提 PR | 交给 `CI 门禁`（push 到 `main`/`master` 或开 PR 自动跑） |
| 不想改代码只想出包 | Actions → 左侧「桌面端构建（Windows / macOS）」→ Run workflow |
| 发版 | 打 `v*` 标签（如 `v3.0.2`）→ 两个 zip 挂到 GitHub Release，同时触发 Android 出包 |

```bash
git tag v3.0.2
git push origin v3.0.2
```

> ⚠️ **触发条件已调整（2026-09-19）**：原 `on.push` 同时写了 `branches` 和 `tags`，
> 一次发版 push 会跑两遍（main 一遍 + tag 一遍，不同 ref → concurrency 互不取消），
> 实测白烧约 48 计费分钟。现已改为 `on: push.tags + workflow_dispatch`，
> 分支门禁交给 `ci.yml`，桌面端只在**打 tag** 或**手动**时出包。
> 因此本工作流不再有 `paths-ignore`——打了 tag 就是要出包，文档改动也照出。

---

## 3. 产物怎么用

### Windows

1. 下载 `ovimap-windows-x64-3.0.2.zip`，解压到任意目录（**不要**只把 `ovimap.exe`
   单独拖出来，它依赖同级的 `data\` 目录与若干 dll）。
2. 双击 `ovimap.exe` 即可。
3. 如需双击 `.ovimap` 工程文件直接打开，用管理员 PowerShell 跑一次
   `scripts\install_association.ps1` 注册文件关联。

**关于 VC++ 运行库**：Flutter 的 Windows 产物以 `/MD` 动态链接 C 运行库，
`ovimap.exe` 的导入表里含 `MSVCP140.dll` / `VCRUNTIME140.dll` / `VCRUNTIME140_1.dll`，
而 Windows 只自带 UCRT（`api-ms-win-crt-*`），不带这几个。所以打包步骤会从
runner 上 VS 2022 的 `VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT` 目录把整套 VC143
CRT 拷进产物目录，做成真正双击即用的绿色版；该目录不存在时回退到从
`System32` 取这三个必需项。

> 许可提示：这些 dll 属于 Microsoft Visual C++ 可再发行组件，VS 的许可条款允许
> 随你的应用一起分发。若贵司合规口径不允许随包分发，删掉工作流
> 「打包为 zip」步骤里的那段拷贝逻辑即可，代价是用户机器需自行安装
> 「Microsoft Visual C++ 2015-2022 Redistributable (x64)」。

### macOS

1. 下载 `ovimap-macos-universal-3.0.2.zip`，解压得到 `ovimap.app`，拖入「应用程序」。
2. **首次打开会被 Gatekeeper 拦**：包是 ad-hoc 签名的（没有 Apple 开发者证书），
   系统会提示「无法验证开发者」。任选其一放行：
   - 右键 `ovimap.app` → 「打开」→ 在弹窗里再点「打开」（只需一次）；
   - 或终端执行 `xattr -cr /Applications/ovimap.app`。
3. 架构是 universal（arm64 + x86_64），Apple Silicon 与 Intel 都能跑。

> 想让包变成「双击即开、无任何提示」，需要 Apple Developer 付费账号
> （$99/年）做 Developer ID 签名 + 公证。当前没有配证书，因此走 ad-hoc。

---

## 4. 手动改配置

| 想改什么 | 改哪里 |
|---|---|
| Flutter 版本 | 工作流顶部 `env.FLUTTER_VERSION`（当前 `3.47.2`，与 `docs/BUILD-windows.md` 基线一致） |
| artifact 保留天数 | 各任务 `upload-artifact` 的 `retention-days`（当前 30 天） |
| 任务超时 | 各任务 `timeout-minutes`（Windows 60 分钟 / macOS 90 分钟） |
| 关掉发版挂载 | 删掉两个 `挂到 Release` 步骤 |

---

## 5. 已知边界（重要）

### 5.1 ~~macOS 端是「移动壳」界面~~ → 已修复（v3.0.3）

**历史缺陷（v3.0.2 及更早）**：`lib/main.dart` 的顶层平台判断是

```dart
home: Platform.isWindows ? const WorkspacePage() : const HomePage(),
```

macOS 不属于 `isWindows`，于是落到移动竖屏壳（`HomePage`），并且
`SystemChrome.setPreferredOrientations` 按移动端锁方向。症状：
**宽窗口下界面变形、滚轮缩放完全没反应**（移动壳的 `MapCanvas` 默认交互开关不含
`scrollWheelZoom`）。

**修复（已合入 main，随 v3.0.3 出包）**：

| 位置 | 改动 |
|---|---|
| `lib/main.dart` | 判据换成 `PlatformCaps.isDesktop`（含 macOS），竖屏锁改为 `!PlatformCaps.isDesktop` |
| `macos/Runner/MainFlutterWindow.swift` | 窗口 1440×900 / 最小 1024×680（模板默认 800×600 会把三栏挤变形） |
| `lib/ui/map/map_canvas.dart` | 默认交互开关收口到 `defaultFlagsForCurrentPlatform()`：桌面 `drag + scrollWheelZoom`；关闭「Ctrl+鼠标旋转」的默认绑定 |
| `lib/services/platform_caps.dart` | `hasGps` 收紧为 `Android \|\| iOS`（原 `!isWindows` 把 macOS 误判为有 GPS）；`supportsFileSaveDialog` 纳入 macOS |
| `lib/ui/desktop/*` | 新增模式提示栏 + 状态栏鼠标经纬度；快捷键补 `Ctrl±` / `Ctrl+0` / `Esc` / `Backspace` 与 macOS `⌘` 组合 |

设计与取舍的完整说明见 **[DESKTOP-UI.md](DESKTOP-UI.md)**。

### 5.2 macOS 端的桌面能力（已对齐）

`PlatformCaps.supportsFileSaveDialog` 原先写死 `Platform.isWindows`，macOS 导出只能走
「分享 / 落盘到数据目录」。现已纳入 macOS（`file_picker.saveFile` → 原生 NSSavePanel），
依赖沙箱授权 `com.apple.security.files.user-selected.read-write`（`Release.entitlements`
已声明）。

### 5.3 `flutter analyze` 现有 68 条 info

不是本次引入的，是仓库既有状态（`drawer_panel.dart` 的
`use_build_context_synchronously`、测试与 `tool/` 里的 `avoid_print` 等）。
CI 里已放行 info 级，不影响出包。

> 桌面壳改造涉及的文件（`main.dart` / `platform_caps.dart` / `ui/desktop/*` /
> `ui/map/map_canvas.dart`）已做到 **0 error / 0 warning / 0 info**。

### 5.4 桌面构建与 Android 侧无关

两个任务都不会触发 Gradle，因此不受 `dependency_overrides`
（`flutter_plugin_android_lifecycle: 2.0.22`）与 AGP 9 相关约束的影响。

> 提示：`android/.gitignore` 里忽略了 `gradle-wrapper.jar` 与 `gradlew`。
> 如果以后想给 Android 也加云端构建，需要注意新克隆的仓库缺 wrapper，
> 得先本地跑一次构建或把这些文件补进版本库。

### 5.5 本地为什么不能出 macOS 包

`xcode-select -p` 指向 `/Library/Developer/CommandLineTools`（只装了命令行工具）时：

```
ProcessException: Process exited abnormally with exit code 72:
xcrun: error: unable to find utility "xcodebuild", not a developer tool or in PATH
```

装完整 Xcode.app 才能本地构建；否则 **macOS 产物只能由本 CI 出**。
Windows 侧同理（需 VS2022 + C++ 工作负载）。这也是这套 CI 存在的理由。

### 5.5 Windows 与 macOS 的测试差异

同一套测试在两个平台上的表现**不完全一致**，两类已知差异：

1. **临时目录清理**（已修）：Windows 不允许删除仍被打开的文件。涉及云同步的
   用例在 `tearDown` 里删临时目录时会撞上在途写盘句柄，抛
   `PathAccessException ... errno = 32`。已统一改用 `test/_fs_cleanup.dart`
   里的 `deleteTempDirResilient()`（退让重试、失败只告警），用于
   `restore_confirm_indep_test` / `version_history_indep_test` / `sync_controller_test`。
2. **`HOME` 环境变量**：Windows 上只有 `USERPROFILE`，没有 `HOME`。
   凡是靠 `Platform.environment['HOME']` 定位本机样本的用例，在 Windows 上会
   落到「跳过」。**两端的跳过集合可能不同，不要用一端的通过数去推断另一端。**
   （截至 v3.0.3，Windows 与 macOS 恰好都是 `505 passed / 2 skipped`；
   更早的 v3.0.2 上曾是 macOS `+502 ~1` / Windows `+500 ~2` 的差异。）属预期行为，不是失败。

因此**不要用 macOS 本地全绿来推断 Windows 也会绿**，反之亦然。

---

## 6. 验证产物（构建成功 ≠ 产物可用）

```bash
gh run download <run-id> -n ovimap-macos-universal-3.0.2 -D /tmp/art
cd /tmp/art && mkdir x && cd x && ditto -x -k ../ovimap-macos-universal-3.0.2.zip .
lipo -info "ovimap.app/Contents/MacOS/ovimap"        # x86_64 arm64
codesign --verify --strict --verbose=2 ovimap.app    # valid on disk
codesign -d --entitlements - ovimap.app              # 核对 network.client
open ovimap.app                                      # 真启动
```

⚠️ **不要**直接用 `./ovimap.app/Contents/MacOS/ovimap` 跑二进制来验证。
带 app-sandbox 的 app 在**本身已被沙箱限制的 shell** 里直启，会在
`libsystem_secinit` 的 `_libsecinit_appsandbox` 处 SIGTRAP（退出码 133），
并留下 `.ips` 崩溃报告，看起来像应用崩了。判别方法：用同样方式跑
`/System/Applications/Calculator.app/Contents/MacOS/Calculator`，
若它也非零退出（137），就是环境限制；用 `open` 启动才是真实结果。

---

## 7. 本地等价命令

想在本地复现 CI 的动作（macOS 需装完整 Xcode）：

```bash
export NO_PROXY="127.0.0.1,localhost,::1"   # 本机若走 HTTP 代理，必须加这行
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter build macos --release                 # 或 flutter build windows --release
```

`NO_PROXY` 那行是本机环境特有的：本地 shell 配了 `HTTP_PROXY=127.0.0.1:xxxxx`，
会把 `flutter_tester` 与测试进程之间的 localhost WebSocket 当成外网请求劫持，
表现为所有用例加载失败并报 `Invalid WebSocket upgrade request`。
GitHub 的 runner 没有代理，不需要这行。

---

## 8. 实测结论（2026-09-18）

流水线跑通后，把两个 artifact 都拉回本机核对过：

| 检查项 | 结果 |
|---|---|
| 两个任务 | `Windows x64 打包` 13m12s ✓ / `macOS 打包` 2m35s ✓ |
| macOS 架构 | `lipo -info` → `x86_64 arm64`（真 universal） |
| macOS 签名 | `codesign --verify --strict` → `valid on disk` + `satisfies its Designated Requirement` |
| macOS 权限 | 签名中实际含 `app-sandbox` / `network.client` / `files.user-selected.read-write`（另有一条 Xcode 注入的 `get-task-allow`，见 BUILD-macos.md §7.3 已知硬化项） |
| macOS 版本 | `CFBundleShortVersionString=3.0.2`、`CFBundleVersion=8`、id `com.dujianhua.ovimap` |
| macOS 可运行 | `open ovimap.app` → 进程稳定存活 13 秒以上，无新崩溃报告 |
| macOS 体积 | .app 53 MB，zip 21 MB |
| Windows 内容 | 20 个条目：`ovimap.exe` + `flutter_windows.dll` + `dartjni.dll` + 4 个插件 dll + `data/`；解压后 33.7 MB，zip 13 MB |
| 本地测试 | `flutter test` 505 通过 / 2 跳过 / 0 失败（本机与 CI 双平台一致） |

Windows 包的**真实启动**未在本机验证（本机没有 Windows），
只核对了导入表与文件完整性；首次真机运行时如报缺 dll，请看 §3 的运行库说明。

---

## 9. 成本提醒

private 仓库的 GitHub Actions 免费额度是 **2000 分钟/月**，且计费带倍率：

| runner | 倍率 | 本项目单次约耗 |
|---|---|---|
| `windows-latest` | ×2 | ~13 分钟 → 计费 ~26 分钟 |
| `macos-latest` | ×10 | ~2.6 分钟 → 计费 ~26 分钟 |

即**一次双平台构建约消耗 50 分钟额度，每月大约 40 次**。
如果构建频次高，可以：

- 把仓库改为 public（Actions 分钟数不限）；
- 或删掉工作流里的 `unit test` 步骤减少耗时（不推荐，会失去门禁）；
- 或把 macOS 任务改成只在打 tag 时跑（加 `if: startsWith(github.ref, 'refs/tags/v')`）。

---

## 10. 发布版本（GitHub Release）

### 10.1 自动路径（推荐，产物可溯源）

打 `v*` 标签 → 工作流在构建成功后调用 `softprops/action-gh-release@v2`
把两个 zip 挂到该标签对应的 Release 上：

```bash
git tag v3.0.2
git push origin v3.0.2
```

工作流里两个任务各有一段：

```yaml
- name: 挂到 Release（仅打 v* 标签时）
  if: startsWith(github.ref, 'refs/tags/v')
  uses: softprops/action-gh-release@v2
  with:
    files: ovimap-windows-x64-${{ env.BUILD_NAME }}.zip   # macOS 任务为 universal 那个
    fail_on_unmatched_files: true
```

`fail_on_unmatched_files: true` 是刻意的：**产物没生成就报错**，避免出现
「Release 建好了但资产是空的」这种静默失败。

> ⚠️ **踩坑：必须显式声明 `permissions: contents: write`（2026-09-18 实测踩到）**
>
> 本仓库的 Actions 默认工作流权限是 **read**：
> ```bash
> gh api repos/dujianhua200/ovimap/actions/permissions/workflow
> # {"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}
> ```
> 工作流里若不声明 `permissions`，`GITHUB_TOKEN` 只能读，`action-gh-release` 会以
>
> ```
> X Resource not accessible by integration - https://docs.github.com/rest/releases/releases#update-a-release
> ```
>
> 失败。**表现很隐蔽**：前面的 analyze / test / build / zip / upload-artifact 全绿，
> 只有最后这一步红，让人误以为「包出了就行」。已在工作流顶层补上：
>
> ```yaml
> permissions:
>   contents: write
> ```
>
> 注意这是**工作流级**声明，两个 job 都受益；只改 job 级也可以，但要记得两处都加。
> 排错顺序：先查 `default_workflow_permissions`，再查工作流有没有 `permissions` 块。

### 10.2 手动路径（不等 CI，用已验证的本地包）

手边已有验证过的 `dist/` 压缩包、又不想等一次完整 CI 时：

```bash
gh release create v3.0.2 \
  dist/ovimap-windows-x64-3.0.2.zip \
  dist/ovimap-macos-universal-3.0.2.zip \
  --title "滑洲云图 ovimap v3.0.2 桌面版" \
  --notes-file release-notes-v3.0.2.md
```

注意：`gh release create` 会在远端**创建同名标签**，而标签推送会再次触发工作流
（GitHub 的 `paths-ignore` 过滤器对标签推送不生效）。两条路径不冲突 ——
CI 重新构建后会以同名资产覆盖上传，等于给该版本补一次「云端可复现」验证；
若 CI 因为偶发用例失败，已上传的本地包仍在，Release 不会变空。

补传 / 替换资产：

```bash
gh release upload v3.0.2 dist/*.zip --clobber
```

### 10.3 已发布版本记录

| 标签 | 日期 | 标签指向 | 内容 |
|---|---|---|---|
| `v3.0.2` | 2026-09-18 | `f669d80` | 首个桌面稳定版：Windows x64 绿色版 + macOS universal，对应 `pubspec.yaml` 的 `3.0.2+8` |

**v3.0.2 的发布过程（留档，含一次真实踩坑与修复）**

1. 先用手动路径（`gh release create` + 本地已验证的两个 zip）把 Release 建起来，
   保证「发版」这件事件本身不依赖 CI 是否顺利 —— 资产立即可用。
2. 该动作会创建同名标签，标签推送随即触发 CI 复验。
3. **第一次复验（run `35352175692`）失败**：analyze / test / build / zip /
   upload-artifact 全绿，只有「挂到 Release」一步红，报
   `Resource not accessible by integration`。根因就是 §10.1 提示框里那个
   **缺失的 `permissions: contents: write`** —— 也就是说，**自动路径此前从未真正可用过**。
4. 补上权限（`f669d80`），把标签强制移到该提交（代码零改动，仅多了权限声明与文档），
   重跑复验。
5. **第二次复验（run `35353588357`）全绿**，包括两个平台的「挂到 Release」步骤。
   资产被 CI 构建的同名包覆盖上传，Release 页面最终挂的是**经过门禁的 CI 产物**。

| 最终资产 | 大小 | sha256 |
|---|---|---|
| `ovimap-macos-universal-3.0.2.zip` | 21 685 883 B | `d9405c049dd5aa5d7c76c8199c9e9ec542e998e0684eabf9be26ae641b4f2448` |
| `ovimap-windows-x64-3.0.2.zip` | 14 280 867 B | `9381f491d5f0107d6eeb816dc18ad187423e5f7b4bfaa68c08688f23ffc6365b` |

> 与本地构建的包相比字节不同（zip 内含时间戳等因素），属正常；
> 关键是**发布出去的就是 CI 在门禁通过后构建的那一份**。
>
> 事后复盘：正确顺序其实是「先修权限、再发版」。手动路径适合抢时间，
> 但**不要用它替代 CI 复验**，否则会把「CI 其实一直在失败」这个事实掩盖过去。
> 排错时如果只看「Release 里有包」就收工，就会漏掉这个缺陷。

### 10.4 版本号从哪来

`pubspec.yaml` 的 `version: <name>+<number>` 是唯一真源，工作流开头用一段
`Select-String`（Windows）/ `grep+sed`（macOS）解析出 `BUILD_NAME` 与 `BUILD_NUMBER`，
再传给 `flutter build --build-name --build-number`。
**升级版本时只改 `pubspec.yaml` 这一处**，标签名与产物文件名会自动跟上。

