# 滑洲云图 ovimap —— Windows 桌面版构建指南

> 面向：首次在 Windows 上构建本项目 exe 的使用者。
> 目标：`flutter build windows --release` 一次成功，产出免安装「绿色版」。

---

## 0. 一句话流程

1. 装 **Flutter SDK (stable)** → 2. 装 **Visual Studio 2022（C++ 桌面工作负载）** →
3. `flutter doctor` 全绿 → 4. 双击 `scripts\build_windows.bat` → 5. 到
`dist\ovimap-windows-x64\` 取 `ovimap.exe`。

---

## 1. 安装 Flutter SDK

1. 打开 https://docs.flutter.dev/get-started/install/windows ，下载 **stable** 版 zip。
2. 解压到**不含中文、不含空格**的路径，例如 `C:\src\flutter`。
3. 把 `C:\src\flutter\bin` 加入系统环境变量 `PATH`。
4. **重新打开**一个新的 PowerShell / CMD 窗口，执行：

   ```powershell
   flutter --version
   ```

   能打印版本号（本项目基线 **3.47.2**，要求 **≥ 3.35**）即成功。

> 若提示 `flutter` 不是内部或外部命令：PATH 没生效，重开终端或检查路径拼写。

---

## 2. 安装 Visual Studio 2022（C++ 桌面开发）

Windows 桌面构建需要 MSVC 工具链。

1. 下载 **Visual Studio 2022 Community**（免费）：https://visualstudio.microsoft.com/vs/community/
2. 安装时在「工作负载」页勾选：
   - ✅ **使用 C++ 的桌面开发**（Desktop development with C++）
3. 安装完成后，执行 `flutter doctor -v`，确认 **Visual Studio** 一栏是 `√`。

> 常见问题：
> - 只装了 VS Code 不够，必须有 Visual Studio 本体 + C++ 工作负载。
> - 装完后仍未识别：重启终端 / 重启机器。

---

## 3. 启用 Windows 桌面支持

```powershell
flutter config --enable-windows-desktop
```

---

## 4. `flutter doctor` 排错

```powershell
flutter doctor -v
```

逐条看：

| 条目 | 期望 | 红叉处理 |
|---|---|---|
| Flutter | √ | 版本 ≥ 3.35，否则 `flutter upgrade` |
| Windows Version | √ | 需 Windows 10 1809+ |
| Visual Studio | √ | 见 §2 勾选 C++ 工作负载 |
| Android toolchain | 可有可无 | 本机只做桌面构建时可忽略 |

---

## 5. 一键构建

在项目根目录双击：

```
scripts\build_windows.bat
```

或命令行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1
```

脚本会依次：检测 Flutter → 校验版本 → 启用桌面 → 检查 VS → `pub get` →
`flutter build windows --release` → 把产物复制到 `dist\ovimap-windows-x64\`。

首次构建会下载 Flutter Windows 引擎并编译 C++，通常需要几分钟。

---

## 6. 产物与「绿色版」分发

| 项 | 路径 |
|---|---|
| 构建输出 | `build\windows\x64\runner\Release\ovimap.exe`（同目录含 `flutter_windows.dll`、`data\`、插件 DLL） |
| 分发副本 | `dist\ovimap-windows-x64\`（整目录） |

- **免安装绿色版**：把 `dist\ovimap-windows-x64\` 整个文件夹拷贝到任意位置，双击
  `ovimap.exe` 即可运行。
- **数据位置**：`%APPDATA%\ovimap`（`C:\Users\<用户>\AppData\Roaming\ovimap`）。
  与程序目录分离——删掉程序不会丢数据。
- **与手机数据互换**：Windows 的 `%APPDATA%\ovimap\labels\` 与手机
  `<外部存储>/ovimap/labels/` **目录结构逐字一致**，整目录拷贝即可互换。

---

## 7. Visual C++ 运行库

目标机需具备 **Microsoft Visual C++ 2015-2022 运行库（x64）**（Win10/11 通常自带）。

若目标机缺失，会出现「找不到 VCRUNTIME140.dll / MSVCP140.dll」类报错，安装：

- https://aka.ms/vs/17/release/vc_redist.x64.exe

> 如需彻底免依赖，可打包 MSIX（本项目暂不做，留待后续）。

---

## 8. 首次使用（同步，可选）

桌面版本地功能开箱即用。云同步为**增强能力**（已接入，可选启用）：

- 未配置令牌时：本地建工程 / 打点 / 连线 / 导出 DXF / 导入 GeoJSON 全部可用。
- 启用：菜单「同步 → 云同步面板」或工具栏 🔄 → 「同步设置」，填入服务器地址与
  同步令牌（详见 `docs/DEPLOY-sync.md`）。同一令牌的手机与电脑即可双向同步。

---

## 9. 常见问题

**Q：`flutter build windows` 报找不到 `flutter_windows.dll`？**
A：请整目录运行/拷贝 `Release\`，不要只拷 `ovimap.exe`。

**Q：中文窗口标题乱码？**
A：本项目已在 `windows/CMakeLists.txt` 加 `/utf-8`、`Runner.rc` 用 `code_page 65001`，
正常不会乱码。若自改源码后出现，请确认源文件以 UTF-8 保存。

**Q：构建很慢 / 卡在下载？**
A：首次需下载 Windows 引擎；国内网络可配置 Flutter 镜像后再试。

---

## 10. 工程文件（`.ovimap`）与文件关联（T22）

### 10.1 `.ovimap` 格式定义

**`.ovimap` 就是 `collection_<id>.json` 的原文件**（不引入新格式、零解析歧义）：
一个 JSON 对象，含 `id` / `name` / `kind` / `folderId` / `editMode` / `labels`（可选
`distances`）。Windows 与手机端的 `labels/` 目录逐字同构，故该文件天然可跨端互导。

- 菜单「文件 → 导出工程文件(.ovimap)」：把**当前打开的工程**原文另存为 `<工程名>.ovimap`。
- 菜单「文件 → 打开工程文件(.ovimap)」（`Ctrl+O`）：选 `.ovimap` → **新建**一个工程
  （重名自动追加 `(2)/(3)…`，绝不覆盖既有工程）并自动打开。
- 双击 `.ovimap`（已做关联时）→ 启动 `ovimap.exe "<文件>"` → 主进程把该路径经
  `set_dart_entrypoint_arguments` 传给 Dart `main(List<String> args)` → 启动后自动导入并打开。

> **取舍**：未引入自定义扩展结构（如打包照片/底图）。优点是导出/导入与原 `collection_*.json`
> 完全同构、跨端零成本；代价是 `.ovimap` 不含照片与底图（照片本来就是按相对文件名引用、
> 底图是项目级缓存，均不随工程单文件走）。

### 10.2 注册文件关联（免管理员）

```powershell
# 注册（HKCU\Software\Classes，当前用户，无需管理员）
powershell -ExecutionPolicy Bypass -File scripts\install_association.ps1

# 指定 exe 绝对路径（自动探测失败时）
powershell -ExecutionPolicy Bypass -File scripts\install_association.ps1 -ExePath "D:\apps\ovimap-windows-x64\ovimap.exe"

# 解除关联
powershell -ExecutionPolicy Bypass -File scripts\install_association.ps1 -Uninstall
```

脚本写入的键：`HKCU\Software\Classes\.ovimap`（默认值 `OviMap.Project`）与
`HKCU\Software\Classes\OviMap.Project\{DefaultIcon,shell\open\command}`。

**验证步骤（待 Windows 实测）**：
1. 执行注册脚本，无报错；
2. 任选一个 `.ovimap` 文件，右键「属性 → 打开方式」应显示「滑洲云图 工程文件」，图标为本程序图标；
3. 双击该文件 → 程序启动并自动打开该工程（左侧列表出现、地图显示点位）；
4. 执行 `-Uninstall` 后，`.ovimap` 不再关联本程序。

---

## 11. 批量导出 / 拖拽导入（T21）

- **批量导出 DXF**：左栏工程列表 **Ctrl/Shift 多选** → 列表顶部或右键「批量导出 DXF」→
  每个工程导出到 `%APPDATA%\ovimap\labels\export\批量\<工程名>\<工程名>.dxf`，完成后自动打开该目录。
  导出选项沿用「导出成果 → DXF」里上次的勾选，口径与单工程导出一致。
- **拖拽导入**：把文件拖到**窗口任意位置**（Windows 资源管理器拖入）即处理：
  - `.ovimap` → 导入并打开工程；
  - `.geojson` / `.json` → 导入本地开源矢量底图（项目级离线复用）；
  - `.dxf` / `.csv` → 明确中文提示（暂不支持导入）。
  左栏底部「导入区」也可**点击**选择文件（等价入口）。

---

## 12. ⚠️ 待 Windows 验证清单（本批 C++/PowerShell 改动）

> 以下改动**无法在 macOS 上编译/运行验证**，需在 Windows 上 `flutter build windows --release` 后实测。

| 项 | 文件 | 验证点 | 若失败的排查/回退 |
|---|---|---|---|
| 系统文件拖放 | `windows/runner/flutter_window.cpp` / `.h` | `flutter build windows --release` 能编译；拖 `.ovimap`/`.geojson` 到窗口触发导入 | 见下方「编译期回退」 |
| 文件关联 | `scripts/install_association.ps1` | 注册/卸载；双击 `.ovimap` 打开 | 纯脚本，`-Uninstall` 可完全回滚 |

**编译期回退（若 C++ 不过）**：本批 C++ 改动是**加法**，仅涉及
`FlutterWindow::OnCreate` 里建通道 + `DragAcceptFiles`、`OnDestroy` 置空、以及
`MessageHandler` 顶部一个 `if (message == WM_DROPFILES) {...}` 分支与两个 include。
若报错，按注释标记 `T21` 逐处删除即可恢复原状（Dart 侧 `FileDrop.register` 在无通道时
静默不触发，不影响其它功能）。

**可能原因**：① 引擎头文件路径随 Flutter 版本变化（本项目基线 3.47.2 的
`flutter/method_channel.h`、`flutter/standard_method_codec.h`、`flutter/encodable_value.h` 均在）；
② `flutter::EncodableValue`/`EncodableList` 命名空间；③ 忘记 `#include <shellapi.h>`。

**注意**：Flutter 的 `DragTarget` **只处理应用内拖拽**，收不到资源管理器拖入的文件；
真正的系统拖放由上述 C++ `WM_DROPFILES` 提供，二者互补（应用内拖拽 → 左栏「导入区」；
系统拖放 → 整个窗口）。

