# 滑洲云图 ovimap —— macOS 桌面版构建指南

> 面向：首次在 macOS 上构建本项目 `.app` 的使用者。
> 目标：`flutter build macos --release` 一次成功，产出可直接运行、可分发（ad-hoc 签名）的通用二进制应用包。

---

## 0. 一句话流程

1. 装 **Xcode**（App Store）→ 2. 同意许可 + 装命令行工具 → 3. 装 **Flutter SDK (stable)** →
4. `flutter doctor` 全绿 → 5. `flutter build macos --release` → 6. `ditto` 打包成 zip。

---

## 1. 安装 Xcode

macOS 桌面构建需要完整的 Xcode（不是 Command Line Tools 单独安装）。

1. App Store 搜 **Xcode** 安装（体积大，约 10+ GB，耐心等）。
2. 装好后首次启动一次，让它自动补装组件。
3. 同意许可并安装命令行工具：

   ```bash
   sudo xcodebuild -license accept
   sudo xcode-select --install
   sudo xcode-select -p        # 期望输出 /Applications/Xcode.app/Contents/Developer
   ```

> **常见坑**：如果 `xcode-select -p` 输出的是
> `/Library/Developer/CommandLineTools`，说明指向了精简版工具链，桌面构建会失败。切回来：
> ```bash
> sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
> ```

---

## 2. 安装 Flutter SDK

### 方式 A：官方 zip（推荐，路径可控）

1. 打开 https://docs.flutter.dev/get-started/install/macos ，下载 **stable** 版 zip。
2. 解压到**不含中文、不含空格**的路径，例如 `~/dev/flutter`：

   ```bash
   mkdir -p ~/dev && cd ~/dev
   unzip ~/Downloads/flutter_macos_arm64_*.zip     # Apple Silicon
   # 或 flutter_macos_x64_*.zip                    # Intel
   ```

3. 加入 PATH（zsh）：

   ```bash
   echo 'export PATH="$HOME/dev/flutter/bin:$PATH"' >> ~/.zshrc
   source ~/.zshrc
   ```

4. 验证：

   ```bash
   flutter --version      # 本项目基线 3.47.2，要求 >= 3.35
   ```

### 方式 B：Homebrew

```bash
brew install --cask flutter
```

> 注意 Homebrew 装的 Flutter 版本更新节奏与 cask 同步，可能滞后；本项目对版本敏感（见 §6），
> 遇到怪异报错优先切官方 zip。

---

## 3. 启用 macOS 桌面支持

```bash
flutter config --enable-macos-desktop
```

---

## 4. `flutter doctor` 排错

```bash
flutter doctor -v
```

| 条目 | 期望 | 红叉处理 |
|---|---|---|
| Flutter | √ | 版本 ≥ 3.35，否则 `flutter upgrade` |
| Xcode | √ | 见 §1，重点确认 `xcode-select -p` 指向 Xcode.app |
| CocoaPods | √ | `sudo gem install cocoapods`，或 `brew install cocoapods` |
| Android toolchain | 可有可无 | 本机只做桌面构建时可忽略 |
| Xcode 版本过旧 | — | macOS 桌面构建对 Xcode 版本不敏感，但过旧会缺 `x86_64` 交叉编译支持 |

---

## 5. 构建

```bash
cd /path/to/ovimap
flutter pub get
flutter config --enable-macos-desktop
flutter build macos --release
```

首次构建会编译 macOS 引擎与全部原生插件，通常 **2~5 分钟**。

显式指定版本号（与 `pubspec.yaml` 一致时可省略）：

```bash
flutter build macos --release --build-name=3.0.2 --build-number=8
```

**产物路径**

```
build/macos/Build/Products/Release/ovimap.app
```

---

## 6. ⚠️ 本项目在 macOS 上的已知边界

| 项 | 说明 |
|---|---|
| **窗口尺寸** | 模板 `MainMenu.xib` 默认 800×600，会把桌面三栏挤变形。`macos/Runner/MainFlutterWindow.swift` 已显式设为 **1440×900 / 最小 1024×680**，并按可见屏幕收敛 + 居中。**自建工程时别漏这一步** |
| ~~界面壳是移动竖屏壳~~ | ✅ **已修复**：`lib/main.dart` 改用 `PlatformCaps.isDesktop`，macOS 与 Windows 一致走桌面三栏壳（含菜单栏 / 工具栏 / 模式提示栏 / 状态栏 / 快捷键 / 右键菜单）。macOS 上 `Ctrl` 与 `⌘` 两套快捷键组合都可用；`supportsFileSaveDialog` 现为 **true**（走原生 NSSavePanel）。详见 [DESKTOP-UI.md](DESKTOP-UI.md) |
| **Flutter 版本敏感** | 基线 **3.47.2**。`file_picker` 固定在 `9.2.3`、`flutter_plugin_android_lifecycle` 经 `dependency_overrides` 钉在 `2.0.22`，升级 Flutter 时先确认这两处约束仍然成立 |
| **移动端专属能力降级** | 桌面无 GPS / 无罗盘 / 无相机，能力判断统一走 `lib/services/platform_caps.dart` |
| **系统级拖放** | `WM_DROPFILES` 桥（`windows/runner/flutter_window.cpp`）是 **Windows 专属**，macOS 上不生效；应用内拖拽（左栏导入区）仍可用 |
| **无代码签名证书** | 走 ad-hoc 签名（见 §7），分发时需指导用户绕过 Gatekeeper |
| **本机无法构建** | 只装 CommandLineTools（`xcode-select -p` 指向 `/Library/Developer/CommandLineTools`）时 `flutter build macos` 会报 `unable to find utility "xcodebuild"`；必须装完整 Xcode.app 或改由 CI 出包 |

---

## 7. 签名与沙箱

### 7.1 签名

未配置开发者证书时，Flutter 按工程配置走 **ad-hoc 签名**（`Signature=adhoc`）。
产物可在本机直接运行，拷给别人需对方手动放行。

验证签名：

```bash
APP="build/macos/Build/Products/Release/ovimap.app"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv "$APP"                    # 期望看到 Signature=adhoc
lipo -info "$APP/Contents/MacOS/ovimap"   # 期望 x86_64 arm64
```

签名不完整时补签：

```bash
codesign --force --deep --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
```

### 7.2 通用二进制

工程默认产出 **universal**（`x86_64` + `arm64`），Intel 与 Apple Silicon 通用。
实测 `lipo -info` 输出：

```
Architectures in the fat file: .../ovimap are: x86_64 arm64
```

### 7.3 沙箱权限（entitlements）

应用开启了 **App Sandbox**（`macos/Runner/Release.entitlements`）。**实际签名里会看到 4 项**：

| 权限键 | 来源 | 为什么必须 / 说明 |
|---|---|---|
| `com.apple.security.app-sandbox` | 工程文件 | 沙箱开关 |
| `com.apple.security.network.client` | 工程文件 | 地图瓦片 / 天地图检索 / 云同步全走 HTTPS；**少了这项，界面能起来但底图与所有在线能力空白** |
| `com.apple.security.files.user-selected.read-write` | 工程文件 | 导入 GeoJSON 底图、另存为导出产物、选择取证图片 |
| `com.apple.security.get-task-allow` | **Xcode 构建时注入**（不在工程文件里） | 允许调试器附加。Release 包不该有，见下方「已知硬化项」 |

调试配置（`DebugProfile.entitlements`）在工程声明上多了 `allow-jit` 与 `network.server`
（Flutter 热重载需要）。

核实命令：

```bash
codesign -d --entitlements - build/macos/Build/Products/Release/ovimap.app | grep '\[Key\]'
```

> **改动提醒**：如果你在 macOS 上跑 release 版发现「界面正常但地图全白」，第一件事就是
> 上面这条命令，看看 `network.client` 还在不在 —— 不少 Xcode 升级会覆盖 entitlements 文件。

#### ⚠️ 已知硬化项：Release 包里带了 `get-task-allow`

`com.apple.security.get-task-allow` 让调试器能附加到进程，属于**开发期授权**，
正式分发包里不该出现。本项目的 release 包里实测有它（`Release.entitlements`
源文件里并没有），原因是 Xcode 的 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` 默认为 `YES`，
在 ad-hoc 签名下会注入这条基础授权。

**影响面**：同用户会话下的进程可附加调试器读取内存。对内部工程工具属低风险，
不影响功能与分发；但如需按安全基线收口，在 Release 配置里关掉即可：

```
# macos/Runner/Configs/Release.xcconfig（或 Xcode → Runner target → Release → Build Settings）
CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO
```

改完重新构建，再用上面的 `codesign -d` 命令确认这一项消失。
（当前 v3.0.2 未收口，已验证不影响运行。）

### 7.4 应用标识

| 项 | 值 | 位置 |
|---|---|---|
| 产品名 | `ovimap` | `macos/Runner/Configs/AppInfo.xcconfig` |
| Bundle ID | `com.dujianhua.ovimap` | 同上 |
| 最低系统 | **macOS 12.0** | `MACOSX_DEPLOYMENT_TARGET` |
| 版权 | Copyright © 2026 com.dujianhua | 同上 |

---

## 8. 打包分发

**必须用 `ditto`**，不能用 `zip` 命令：

```bash
cd /path/to/ovimap
APP="build/macos/Build/Products/Release/ovimap.app"
OUT="ovimap-macos-universal-3.0.2.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT"
ls -lh "$OUT"
```

> **为什么必须 ditto**：`.app` 是 bundle，内部含**符号链接**（`Versions/Current` → `A`）与
> **可执行位**。普通 `zip` 会丢符号链接，解压出来的 app 直接打不开（报「应用已损坏」）。
> `ditto` 是 Apple 官方工具，能完整保留 HFS/APFS 元数据。`--keepParent` 保证解压后外层就是
> `ovimap.app`，而不是散落的 `Contents/`。

### 用户侧安装提示（随包发放）

```
1. 解压得到 ovimap.app
2. 拖入「应用程序」
3. 首次打开：右键 → 打开 → 弹窗里再点「打开」
   或终端执行：xattr -dr com.apple.quarantine /Applications/ovimap.app
```

---

## 9. 数据位置

| 项 | 路径 |
|---|---|
| 应用数据 | `~/Library/Containers/com.dujianhua.ovimap/Data/Library/Application Support/...`（沙箱容器内） |
| 非沙箱 / 调试 | `~/Library/Application Support/ovimap/` |

**跨端数据互换**：Windows 的 `%APPDATA%\ovimap\labels\` 与手机 `<外部存储>/ovimap/labels/`
**目录结构逐字一致**，可直接整目录拷贝互换；macOS 沙箱版数据在容器内，导出请走
「文件 → 导出工程文件(.ovimap)」再拷出。

---

## 10. 常见问题

**Q：`flutter build macos` 报 `CocoaPods not installed`？**
A：`sudo gem install cocoapods`（Apple Silicon 上如果 gem 报权限错，用 `brew install cocoapods`）。

**Q：报 `xcodebuild: error: The project ... does not contain a scheme named "Runner"`？**
A：Xcode 缓存脏了。删掉 `macos/Runner.xcworkspace/xcuserdata/` 与
`macos/Runner.xcodeproj/xcuserdata/`，再重跑构建。

**Q：构建成功但打开 app 闪退？**
A：先看日志：`open -a ovimap` 或直接跑二进制
`./build/macos/Build/Products/Release/ovimap.app/Contents/MacOS/ovimap`。
常见原因是 entitlements 缺 `network.client` 导致在线能力初始化失败，或签名不完整。

**Q：界面能起来但地图全白？**
A：沙箱出网权限被覆盖了。检查 §7.3，重新 `codesign --force --deep --sign - "$APP"`。

**Q：发给同事，同事打不开，提示「已损坏」？**
A：两种可能 —— ① 打包用了 `zip` 而不是 `ditto`，符号链接丢失；② Gatekeeper 拦截 quarantine。
按 §8 重新打包，并让同事走「右键 → 打开」。

**Q：能不能做成免 Gatekeeper 的正式包？**
A：需要 Apple Developer 账号（$99/年）+ Developer ID 证书 + 公证（notarization）。
流程：`codesign --deep --force --options runtime --sign "Developer ID Application: XXX"` →
`xcrun notarytool submit --wait` → `xcrun stapler staple`。本项目当前不做，成本与收益不匹配。

**Q：`flutter test` 报 `PathAccessException` / 临时目录删不掉？**
A：Windows 上更常见（文件锁竞态），macOS 偶发。工程内已用 `test/_fs_cleanup.dart` 的
`deleteTempDirResilient` 做重试，仍失败就重跑一次。

---

## 11. 与 Windows 构建的差异对照

| 项 | Windows | macOS |
|---|---|---|
| **界面壳** | ✅ 桌面三栏壳（菜单栏 / 工具栏 / 模式提示栏 / 状态栏 / 快捷键 / 右键菜单） | ✅ 同上（`PlatformCaps.isDesktop` 分支，含 `⌘` 快捷键与原生另存为） |
| 工具链 | Visual Studio 2022 + C++ 工作负载（MSVC） | Xcode + CocoaPods |
| 启用命令 | `flutter config --enable-windows-desktop` | `flutter config --enable-macos-desktop` |
| 产物 | `build\windows\x64\runner\Release\` 整个目录 | `build\macos\Build\Products\Release\ovimap.app` |
| 额外依赖 | 需补 VC++ 运行库 dll（MSVCP140 / VCRUNTIME140 / VCRUNTIME140_1） | 无（系统自带 Swift 运行时） |
| 打包工具 | `Compress-Archive` | **`ditto`**（`zip` 会丢符号链接） |
| 签名 | 无 | ad-hoc 签名（无证书时） |
| 首次运行拦截 | 无 | Gatekeeper（右键 → 打开） |
| 文件关联 | `scripts\install_association.ps1`（HKCU） | 未做（`.ovimap` 通过 Ctrl+O 打开） |
| 系统拖放 | ✅ `WM_DROPFILES` 桥 | ❌ 仅应用内拖拽 |
| 原生另存为 | ✅ | ❌ 走分享/落地数据目录 |
| CI runner | `windows-latest` | `macos-latest` |
