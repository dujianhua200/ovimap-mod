# ovimap 项目长期记忆

## 仓库与发布
- 仓库 `dujianhua200/ovimap`（**PRIVATE**）。默认工作流权限 **read** —— 要挂 Release 的 workflow 必须显式 `permissions: contents: write`。
- 版本号在 `pubspec.yaml`（`version: X.Y.Z+N`），由 workflow 读取注入到产物名与构建参数。
- 打 `v*` 标签即发版；产物挂到同名 GitHub Release。

## CI 拓扑（2026-09-19 定型，三个 workflow）
| 文件 | 作用 | 触发 | runner |
|---|---|---|---|
| `ci.yml` `CI 门禁` | analyze + test | push main/master（ignore `docs/**`、`**/*.md`）+ PR + 手动 | ubuntu（1x） |
| `build-android.yml` `Android 打包` | universal APK | tag v* + 手动 | ubuntu（1x） |
| `build-desktop.yml` `桌面端构建` | Windows + macOS 出包 | tag v* + 手动 | win（2x）/ mac（**10x**） |

**硬规则**：
- `ci.yml` 里**不写 tags**；出包 workflow 里**不写 paths-ignore**。否则打 tag 会双跑。
- **绝不把 macOS runner 放到 push/PR 触发上**（×10 计费，一次 ≈30 计费分钟）。桌面与 Android 出包只在 tag/手动时跑。
- 测试步骤用「**至多一次重试**」吸收 `flutter_tester` 收尾偶发崩溃（用例全绿却 exit 1，三平台都遇到过）。
  **禁止**改成 `|| true` 或包装退出码。

## Android 签名（铁律）
- 真机侧载要能**覆盖安装**手机上的旧版，否则卸载重装会**丢现场数据**。
- keystore 是 `/Users/dujianhua200/Doubao/滑洲云图/outputs/ManualApp/debug.keystore`（alias `androiddebugkey`，口令 `android`），
  证书 SHA1 `dfc826bb88e0426eda78750d0ab85cf300ee41c3`。
- CI 通过 4 个 Secret 注入（`ANDROID_KEYSTORE_BASE64` / `..._PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD`），
  **keystore 绝不进仓库**。
- `android/app/build.gradle.kts` 的签名是**三级解析**：`android/key.properties` → 本机 legacy 绝对路径 → 回退 AGP 内置 `debug`。
  最后一级会静默出「签名不对的包」，所以构建后有**签名一致性校验**步骤兜底。
- 改签名相关代码时，务必保留那道校验；它是防「静默错签」的唯一防线。

## 本机工具链现实
- 只有 Flutter 3.47.2 是本地必需（写代码 + 跑门禁）。
- **Xcode 只有 CommandLineTools** → 本地出不了 macOS 包；本机是 macOS → 出不了 Windows 包；
  **代理挡 `maven.google.com`（502）** → 本地 Android 出包不可靠。**出包一律上云。**
- 本机 Android SDK 在 `/Users/dujianhua200/Library/Android/sdk`（NDK 28.2.13676358），
  JDK 便携式在 `~/toolchain/temurin17`，由 `flutter config --jdk-dir` 指向（`java` 不在 PATH）。

## 构建命令注意
- `flutter build apk` 会自动生成 `android/local.properties`（含 `flutter.sdk`）；
  `android/settings.gradle.kts` 强制要求它，所以**不能**用裸 `./gradlew`。
- `flutter_lints` 下 `flutter analyze` 默认把 info 判死 → 一律带 `--no-fatal-infos`（error/warning 仍致命）。
- 本机跑 `flutter test` 必须绕开会话代理劫持 flutter_tester 的 WebSocket：
  `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy NO_PROXY=localhost,127.0.0.1 flutter test`
- 本机 `git push` / `git ls-remote` 必须走 xray 代理（大小写四个变量都设）：
  `env HTTPS_PROXY=http://127.0.0.1:10808 HTTP_PROXY=... https_proxy=... http_proxy=... git push`
  —— `HTTP_PROXY` 默认指向 sandbox 代理 56315，对 github.com 返回 CONNECT 502。
