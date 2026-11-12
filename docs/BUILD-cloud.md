# 滑洲云图 ovimap —— 本地零安装出包手册（CI 接管一切）

> 目标：本机只装 **Flutter SDK** 一个工具链，所有**构建 / 测试 / 出包**都搬到 GitHub Actions。
> 本机只负责写代码 + 看门禁 + 打 tag + 下载成品。

---

## 0. 为什么本机不需要装环境

实测本机（macOS）状态：

| 维度 | 现状 | 结论 |
|---|---|---|
| Xcode | 只装了 CommandLineTools（`xcode-select -p` → `/Library/Developer/CommandLineTools`），**无完整 Xcode.app** | 本地**出不了 macOS 包**（缺 `xcodebuild`，报 `exit code 72`） |
| Windows 工具链 | 本机是 macOS，**没有 VS2022 + C++ 工作负载** | 本地**出不了 Windows 包** |
| Android 依赖 | 本机 shell 走 HTTP 代理，`maven.google.com` 被代理挡 **502**，`flutter doctor` 报依赖不可达 | 本地**Android 出包不可靠** |

三条路全被本机环境堵死，所以 **出包只能上云**。本机的职责收缩到：

- 写代码（只需 Flutter SDK：`flutter pub get` / `analyze` / `test`）
- 推代码、开 PR、打 tag
- 从 Release / Artifacts 下载成品

> 例外：如果你仍想本地出 Android APK（绕过代理问题），可以参照 §5「工具链职责表」的例外条件，但**不推荐**——本手册默认一切上云。

---

## 1. 四条日常动线

### ① 日常改代码（只需 Flutter SDK）

```bash
flutter pub get
flutter analyze --no-fatal-infos        # info 级 lint 放行；error / warning 仍致命
flutter test                            # 纯 Dart 单测，不需要 Android SDK / JDK
```

> 本机若走 HTTP 代理，必须加一行，否则 `flutter test` 的 localhost WebSocket 被劫持，
> 所有用例报 `Invalid WebSocket upgrade request`：
> ```bash
> export NO_PROXY="127.0.0.1,localhost,::1"
> ```
> GitHub runner 无代理，不需要这行。

### ② 看门禁

推代码或开 PR 后，看 **`CI 门禁`** 这个 workflow（ubuntu 1x，最便宜）：

- `push` 到 `main` / `master`（文档改动除外）会自动跑
- 开 PR 会自动跑
- 也可在 Actions 页面手动 `Run workflow`

门禁只做 `flutter analyze --no-fatal-infos` + `flutter test`，不过就进不了 `main`。

### ③ 出包

**全平台（推荐）：**

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

打 `v*` 标签会同时触发两个出包 workflow（共 3 个 job）：

- `Android 打包` → `ovimap-android-X.Y.Z.apk`
- `桌面端构建（Windows / macOS）` → `ovimap-windows-x64-X.Y.Z.zip` + `ovimap-macos-universal-X.Y.Z.zip`

三者（3 个 job 的产物）都会挂到同名的 GitHub Release 上。`CI 门禁` 不参与出包 —— 它的 `on:` 里没有 `tags`，只管分支与 PR。

**单平台按需（不想全出，省额度）：**

```bash
# 只出 Android
gh workflow run "Android 打包"
# 只出 Windows + macOS
gh workflow run "桌面端构建（Windows / macOS）"
```

> `gh workflow run` 默认跑在默认分支的最新提交上；如需指定 ref 加 `--ref <branch>`。

### ④ 下载

```bash
# 从 Release 下载（已发布版本）
gh release download vX.Y.Z -p 'ovimap-android-X.Y.Z.apk' -D ~/Downloads
gh release download vX.Y.Z -p 'ovimap-windows-x64-X.Y.Z.zip' -D ~/Downloads
gh release download vX.Y.Z -p 'ovimap-macos-universal-X.Y.Z.zip' -D ~/Downloads

# 从某次运行（Run）的 Artifact 下载（还没打 Release / 只想拿某次构建）
gh run download <RUN_ID> -n ovimap-android-X.Y.Z -D ~/Downloads
```

`<RUN_ID>` 在 Actions 页面对应运行的 URL 里：`.../actions/runs/<RUN_ID>`。

---

## 2. 工具链职责表

| 工具链 | 现在还需要本机装吗 | 哪个 CI job 接管 | 例外条件（仍想本地出） |
|---|---|---|---|
| **Xcode**（含 `xcodebuild`） | ❌ 不需要 | `桌面端构建` 的 `build-macos` job（`macos-latest`） | 本机装**完整 Xcode.app** + `sudo xcodebuild -license accept`，可本地 `flutter build macos` |
| **MSVC**（VS2022 + C++ 负载） | ❌ 不需要 | `桌面端构建` 的 `build-windows` job（`windows-latest`，自带 VC++ Redist 拷贝逻辑） | 本机装 Windows + VS2022 C++ 工作负载，可本地 `flutter build windows` |
| **独立 JDK** | ❌ 不需要 | `Android 打包` 用 `actions/setup-java@v4`（temurin 17）；桌面端 Flutter 自带 | 本项目锁死 **Java 17**（compileOptions / kotlin jvmTarget / AGP 9.1.0 / Gradle 9.3.1），本地若装 JDK 也必须是 17，别用 21 |
| **Android SDK** | ❌ 不需要 | `Android 打包` 用 `android-actions/setup-android@v3` 补齐 | 本机装 Android SDK 且**能直连 `maven.google.com`**（绕过代理 502）后，可本地 `flutter build apk` |
| **Flutter SDK** | ✅ **必须本机装**（写代码 / 跑门禁用） | 三个 workflow 都用 `subosito/flutter-action@v2`（3.47.2 stable） | 无 |

核心结论：**本机唯一长期依赖 = Flutter SDK**。出包相关的重型工具链全部上云。

---

## 3. 计费与额度

private 仓库 GitHub Actions 免费额度 **2000 分钟/月**，且带倍率。
下表「实测」列都是 **2026-09-18 真实跑出来的**（`gh run view` 的 createdAt→updatedAt）：

| runner | 倍率 | 本项目实测 | 计费消耗 |
|---|---|---|---|
| `ubuntu-latest` — `CI 门禁` | ×1 | **2 分 53 秒** | ≈ 3 分钟 |
| `ubuntu-latest` — `Android 打包` | ×1 | **12 分 59 秒** | ≈ 13 分钟 |
| `windows-latest` — `桌面端构建` | ×2 | ≈ 9 分 07 秒 | ≈ 18 分钟 |
| `macos-latest` — `桌面端构建` | **×10** | ≈ 3 分钟 | **≈ 30 分钟** |

**纪律：绝不在每次 push 上跑 macOS。**

- 分支 / PR 门禁交给 `ci.yml`（ubuntu 1x）。`flutter test` 是纯 Dart 单测，
  不需要 Android SDK / JDK / Xcode / MSVC —— 所以本机也只需要装 Flutter 一个。
- 桌面端只在**打 tag** 或**手动**时出包（`on: push.tags + workflow_dispatch`）。
- Android 出包同样只在 tag / 手动时跑（ubuntu 1x，约 13 分钟一次）。

各场景的计费分钟估算：

| 场景 | 计费分钟 | 说明 |
|---|---|---|
| push 到 main（只跑门禁） | ≈ 3 | 一天推 20 次也才 60 分钟 |
| 手动单出 Android | ≈ 13 | 最便宜的出包方式 |
| 手动单出 Windows | ≈ 18 | |
| 手动单出 macOS | ≈ 30 | 最贵，按需再用 |
| 打 tag（全平台一起出） | ≈ 64 | 3 + 13 + 18 + 30 |

对照：旧版配置下一次「push 到 main」就会烧 ≈ 48 计费分钟（Windows 18 + macOS 30），
而一次「改完就发版」的 push 会因 `on.push` 同时写 `branches` 与 `tags` 而跑两遍 ——
**≈ 96 计费分钟**。现在同样的动作是 3 分钟，降了一个数量级。

---

## 4. 签名与覆盖安装（重要）

### 为什么必须用同一个 keystore

Android 应用靠 **签名证书** 标识身份。真机上已装旧版时，新包若签名不同，系统直接拒绝覆盖安装：

```
INSTALL_FAILED_UPDATE_INCOMPATIBLE
```

**卸载重装会丢现场数据**（工程文件、缓存等）。所以 CI 出包必须用**和本机发布同一个 keystore**。

### 三级签名解析（见 `android/app/build.gradle.kts`）

优先级从高到低：

1. **`android/key.properties`**（CI 由 Secret 还原；本机也可自建）—— 存放 keystore 引用与口令。
2. **本机旧工程绝对路径** `/Users/dujianhua200/Doubao/滑洲云图/outputs/ManualApp/debug.keystore`
   （历史遗留，口令 `android` / 别名 `androiddebugkey` / 口令 `android`），保持「能覆盖安装」。
3. **都没有 → 退回 AGP 内置 debug 签名**（`~/.android/debug.keystore`，AGP 自动生成）。
   能保证「任何环境都能出一个可安装包」，但**签名与手机旧版不同**，覆盖安装会报
   `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，需先卸载——仅用于临时调试，**不能当发布包**。

### 4 个 Secret（仓库 Settings → Secrets → Actions）

| Secret 名 | 内容 | 来源 |
|---|---|---|
| `ANDROID_KEYSTORE_BASE64` | 本机发布 keystore 的 **base64 全文（单行）** | `openssl base64 -A -in debug.keystore` 的输出 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 口令（storePassword） | 发布时用的口令 |
| `ANDROID_KEY_ALIAS` | 别名（keyAlias） | 通常为 `androiddebugkey` 或自定义 |
| `ANDROID_KEY_PASSWORD` | 密钥口令（keyPassword） | 通常与 storePassword 相同 |

CI 流程：`ANDROID_KEYSTORE_BASE64` → `base64 -d` → `android/ovimap.keystore`；
同时生成 `android/key.properties`（含四个字段），Gradle 据此还原 `ovimap` signingConfig。

> `key.properties` 与 `*.keystore` 已被 `android/.gitignore` 忽略，**绝不进仓库**。
> 本地自建 `key.properties` 的字段示例（**不要写进仓库**）：
> ```
> storeFile=ovimap.keystore
> storePassword=android
> keyAlias=androiddebugkey
> keyPassword=android
> ```

**无密钥 / fork 场景**：若 `ANDROID_KEYSTORE_BASE64` 为空，还原步骤被 `if: env.KS_B64 != ''` 守卫跳过，
构建会回退到 AGP 内置 debug 签名——**这个回退会让构建成功、门禁变绿、Release 照挂包**，
而包却与手机上的旧版不同签名。为了不让它静默发生，见 §4.4。

### 4.4 签名一致性校验（防「静默错签」）

`Android 打包` 在重命名 APK 之后、上传之前，有一道**签名校验**：

1. 从注入的 `android/ovimap.keystore` 取期望 SHA1；
2. 从产出的 APK 取实际签名 SHA1（用 `apksigner verify --print-certs`，
   不是 `keytool -printcert -jarfile` —— 后者只能看 v1/JAR 签名，新版 AGP 可能只签 v2/v3，会误判）；
3. 两者不一致 → `::error` + `exit 1`；`ANDROID_KEYSTORE_BASE64` 为空 → 直接失败。

**为什么值得加这一步**：签名错签是本项目最贵的失效模式 —— 用户现场勘察的数据全在手机上，
一旦侧载报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，卸载重装就把数据丢了。
而错签在加这道校验之前是**完全静默**的。

当前命令查到的期望指纹（本机 keystore，标准 Android debug 证书）：

```
SHA1: DF:C8:26:BB:88:E0:42:6E:DA:78:75:0D:0A:B8:5C:F3:00:EE:41:C3
```

**人工复核方式**（想自己再确认一次时）：

```bash
gh release download vX.Y.Z -p 'ovimap-android-*.apk' -D /tmp
keytool -printcert -jarfile /tmp/ovimap-android-X.Y.Z.apk   # 若只签了 v2/v3，改用：
$ANDROID_HOME/build-tools/*/apksigner verify --print-certs /tmp/ovimap-android-X.Y.Z.apk
```

---

## 5. 排障

### 5.1 `flutter.sdk not set in local.properties`

- **现象**：裸跑 `./gradlew` 或某些 Gradle 命令时报。
- **原因**：`android/settings.gradle.kts` 强制要求 `local.properties` 里有 `flutter.sdk`，
  而该文件只有 `flutter build` 自动生成。
- **对策**：**不要用裸 `./gradlew` 出 Android 包**，统一用 `flutter build apk`。CI 的 `Android 打包` 也是这么做的。

### 5.2 `maven.google.com` 不可达（502）

- **现象**：`flutter doctor` / 依赖解析阶段报 502，Google Maven 仓库拉不下来。
- **原因**：本机 HTTP 代理把 `maven.google.com` 当外网劫持。
- **对策**：出包上云（GitHub runner 无代理）。本地若一定要试，需让代理放行 `maven.google.com`，
  或配置 `ANDROID_SDK_ROOT` 走国内镜像——但**不推荐**，容易引入不一致。

### 5.3 NDK 缺失

- **现象**：构建报找不到 NDK（`ndkVersion` 未安装）。
- **对策**：`Android 打包` 里**显式**安装，不指望 AGP 自动补齐：

  ```bash
  sdkmanager --install "platform-tools" "platforms;android-36" \
                         "build-tools;36.0.0" "ndk;28.2.13676358"
  ```

  版本来源是 Flutter 3.47.2 的 `FlutterExtension.kt`（与本机 SDK 已装组件核对一致）：
  `compileSdkVersion=36` / `targetSdkVersion=36` / `minSdkVersion=24` / `ndkVersion=28.2.13676358`。
  升级 Flutter 后这几个数要重新核对。

### 5.4 JVM OOM（内存溢出）

- **现象**：Gradle 构建中途 `Java heap space` / `OutOfMemoryError`。
- **原因**：`android/gradle.properties` 写死 `-Xmx8G -XX:MaxMetaspaceSize=4G`，
  那是给本机 8G 内存机器调的；CI runner 内存有限，按 8G 起 JVM 会挤爆。
- **对策**：`Android 打包` 在构建前用 `sed` 把工作区副本降到 `-Xmx4G` / `-XX:MaxMetaspaceSize=2G`
  （**只改检出副本，不落库**）。本机 8G 机器保留原值即可。

### 5.5 其它

- **门禁红了但只是 info**：确认 `analyze` 带了 `--no-fatal-infos`；error / warning 仍致命。
- **Release 挂不上（Resource not accessible by integration）**：检查 workflow 顶层是否声明了
  `permissions: contents: write`（本仓库默认工作流权限是 read）。两个出包 workflow 都已声明。
- **Android 包签名校验失败**：`Android 打包` 末尾会比对「注入 keystore 的 SHA1」与「APK 实际签名 SHA1」，
  不一致就 `exit 1`。见 §4.4。

### 5.6 ⚠️ 已知偶发：`flutter test` 用例全绿却 exit 1

**现象**（macOS 与 ubuntu 都实测到过）：

```
🎉 501 tests passed, 2 skipped.      ← 正常应是 505
##[error]Process completed with exit code 1.
```

日志里**一条报错都搜不到**（没有 `❌`、没有 `Expected/Actual`）；macOS 上偶尔会多打一行
`TestDeviceException(Shell subprocess crashed with segmentation fault.)` 并挂在 `finalization`。

**定性方法**（30 秒，别去猜）：**同一提交直接重跑**。

```bash
gh run rerun <RUN_ID> --failed
```

- 重跑转绿 → 是偶发（2026-09-18 实测：同一提交第一次红、重跑就 `505 passed / 2 skipped`）；
- 重跑还红 → 才是确定性缺陷，去比两次运行「实际执行的用例集合」找嫌疑人（手法见
  `docs/BUILD-desktop-ci.md`）。

**我们的对策**：`ci.yml` 与 `build-android.yml` 的测试步骤做了**「至多一次」重试** ——
第一次非零退出就再跑一次；两次都红才判失败。这样确定性失败仍然拦得住，只有偶发崩溃被吸收。

> ⚠️ **不要**把它改成 `flutter test || true` —— 那是掩盖问题。
> 也不要把 `exit 1` 的判定换掉（比如「摘要说全过就算过」），真崩溃会被一起吞掉。

### 5.7 ⚠️ 不要用 `android-actions/setup-android@v3`

**现象**（2026-09-18 实测，runner 镜像 cmdline-tools 16.0）：

```
[command]/usr/local/lib/android/sdk/cmdline-tools/16.0/bin/sdkmanager tools
Warning: Failed to find package 'tools'
Error: The process '.../sdkmanager' failed with exit code 1
```

该 action 内部的步骤 `sdkmanager tools` 会失败 —— 新版 sdkmanager 已经**移除了 `tools` 包**。
因为它在 job 的第 5 步就抛错，后面**所有**步骤都变成 skipped，看起来像「Android 完全跑不起来」。

**关键事实**：GitHub 托管的 ubuntu runner **本身就预装了 Android SDK**
（`/usr/local/lib/android/sdk`，含 cmdline-tools）。所以这个 action 是多余的。

**对策**：删掉该 action，改为自己定位 SDK + `sdkmanager --licenses` + 显式装组件（见 §5.3）。
定位逻辑对 `$ANDROID_HOME` / `$ANDROID_SDK_ROOT` / `/usr/local/lib/android/sdk` 三重兜底，
并把 `ANDROID_HOME` 写回 `$GITHUB_ENV`，供后续步骤（含 `apksigner` 定位）使用。

---

## 6. 实测验证记录（2026-09-18 首次全通）

留档的是**证据**，不是「应该能行」：

| 项 | 命令 / 位置 | 结果 |
|---|---|---|
| `CI 门禁` | run `35369608208`（commit `5a496ec`） | ✅ success，2 分 53 秒 |
| `Android 打包` | run `35369620051`（commit `5a496ec`，手动 dispatch） | ✅ success，12 分 59 秒 |
| 云端跑测试 | 上述两个 job 内 | 🎉 `505 tests passed, 2 skipped`（与 macOS 本机一致） |
| APK 签名一致性 | `Android 打包` 的「校验 APK 签名」步骤 | 期望 `dfc826bb…41c3` ＝ 实际 `dfc826bb…41c3` ✅ |
| 产物独立复核 | 下载后本机 `apksigner verify --print-certs` | `CN=Android Debug, O=Android, C=US`，SHA-1 同上 ✅ |
| APK 包信息 | `aapt2 dump badging` | `com.dujianhua.ovimap` / `versionName=3.0.3` / `versionCode=9` / label「滑洲云图」 |
| APK 体积 | `gh run download` | 63 MB（universal，含全 ABI） |
| 触发面 | push 到 main 后 `gh run list` | **只**触发 `CI 门禁`；桌面 workflow 未被触发（双跑浪费已消除）✅ |

**尚未实测的一项**（诚实标注）：还没打过 tag，所以「三个 job 并行写同一个 Release、三类资产都挂上」这件事
只在结构上成立、未在真实 Release 上验证过。下次真发版时请确认 Release 页面同时有
`ovimap-android-*.apk` + `ovimap-windows-x64-*.zip` + `ovimap-macos-universal-*.zip`。

---

## 7. 相关文件

| 文件 | 作用 |
|---|---|
| `.github/workflows/ci.yml` | 日常门禁（ubuntu，analyze + test） |
| `.github/workflows/build-android.yml` | Android 出包（tag / 手动） |
| `.github/workflows/build-desktop.yml` | Windows + macOS 出包（tag / 手动） |
| `android/app/build.gradle.kts` | 三级签名解析 |
| `docs/BUILD-desktop-ci.md` | 桌面端 CI 详细说明 + 版本发布流程 |
| `docs/BUILD-windows.md` / `docs/BUILD-macos.md` | 本地构建完整指南（如需本地出） |
