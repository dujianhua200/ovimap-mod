# Release v3.0.3 — macOS 桌面壳修复 + 奥维式桌面交互

## 一句话

修掉「macOS 跑的是手机界面」这个根因缺陷（界面变形 + 滚轮缩放失效），
并把桌面壳按**奥维互动地图桌面版**的思路补齐交互（模式提示栏、状态栏鼠标经纬度、
`Ctrl±`/`Ctrl+0`/`Esc`/`Backspace` 快捷键、`⌘` 组合）。

---

## 1. 用户反馈的两个问题

> 「目前测试 mac 版本，地图缩放不管用，界面变形严重，不能按照手机的界面，来设计电脑的界面，多学一下奥维地图电脑版本的设计思路。」

| 现象 | 根因 | 修复 |
|---|---|---|
| macOS 界面变形严重、像手机界面 | `main.dart` 用 `Platform.isWindows` 挑壳，**macOS 被判成移动端**，落到 `HomePage` 竖屏壳 | 判据改为 `PlatformCaps.isDesktop`（含 Windows/macOS/Linux） |
| macOS 地图缩放（滚轮）不管用 | 一是跑的是移动壳；二是 `MapCanvas` 的**默认**交互开关是移动口径，**不含 `scrollWheelZoom`**（Windows 之所以能滚，是旧桌面壳额外传了「全部开关」） | 默认值收口到 `defaultFlagsForCurrentPlatform()`：桌面 = `drag + scrollWheelZoom`；桌面壳不再覆盖 |
| 窗口 800×600，三栏挤成一团 | `flutter create` 模板的 `MainMenu.xib` 默认尺寸 | `MainFlutterWindow.swift` 设 1440×900 / 最小 1024×680，按可见屏幕收敛 + 居中 |
| Ctrl+移动鼠标会把地图转掉 | flutter_map 默认把 Control 键当旋转触发键，与 `Ctrl+Z/S/E` 冲突 | 桌面用 `CursorKeyboardRotationOptions.disabled()` |
| `hasGps` 把 macOS/Linux 误判为「有 GPS」 | 判据写成 `!Platform.isWindows` | 收紧为 `Android \|\| iOS` |
| macOS 导出没有「另存为」 | `supportsFileSaveDialog` 写死 Windows | 纳入 macOS（原生 NSSavePanel） |

## 2. 桌面壳新增（对齐奥维桌面版）

| 项 | 说明 |
|---|---|
| **模式提示栏**（新） | 窗口底部常显：模式胶囊 + 键盘提示 + 实时数据（已连长度/测量总长/已选数）+「完成 (Esc)」 |
| **状态栏鼠标经纬度**（新） | 状态栏恒显鼠标指针处坐标（奥维同款字段）；与「视图中心」分列。走 `ValueNotifier` 局部刷新，悬停不重建地图 |
| **快捷键扩展** | 新增 `Ctrl±`（含裸 `+` `-` 与小键盘）、`Ctrl+0` 复位、`Esc` 取消、`Backspace` 退点；macOS 同时支持 `⌘` 组合 |
| **状态栏自适应** | 窄窗口下左侧信息区改为横向可滚动、坐标系钉右端（修掉了 776px 宽时的 RenderFlex 溢出） |

## 3. 一个有依据的取舍：桌面关闭「双击缩放」

flutter_map 的点击判定 `PositionedTapDetector2` 把「是否双击」和「单击」放在同一流程上：
只有 flags 含 `doubleTapZoom` 时才会注册 `onDoubleTap`，而一旦注册，**每次单击都要等
250ms 的双击判定窗口**才回调。

对现场打点（一条线点几十上百下）这个延迟是硬伤。因此桌面端：

- **关闭** `doubleTapZoom`，缩放走「滚轮 / `Ctrl±` / 工具栏 / 方向键」四条通道，落点零延迟；
- **不采用**奥维的「双击结束绘制」（我们没有连续画线状态机），结束交给 `Esc` 与提示栏「完成」；
- 移动端维持原口径不动（改它会牵动既有手感与整轮回归）。

源码依据与完整取舍见 `docs/DESKTOP-UI.md §4`。

## 4. 质量门禁

| 项 | 结果 |
|---|---|
| `flutter analyze --no-fatal-infos` | **0 error / 0 warning**（改动文件 0 info） |
| `flutter test` | **505 passed / 2 skipped / 0 failed**（本机与 CI 双平台一致） |
| 新增测试 | `desktop_shell_smoke_test.dart`（状态栏鼠标经纬度 notifier 联动 + 快捷键裸键守卫） |
| 更新测试 | 5 处断言原先编码的是**旧缺陷契约**（`Platform.isWindows` 判据、「全部交互开关」），已改写为新契约并加回归护栏 |

> ⚠️ 本机只装了 CommandLineTools（`xcode-select -p` 指向 `/Library/Developer/CommandLineTools`），
> 没有完整 Xcode，**本地无法构建 macOS 包**；macOS 产物由本 CI 构建。人工验收请按下表过一遍。

## 5. 下载与验收

| 平台 | 产物 | 用法 |
|---|---|---|
| Windows x64 | `ovimap-windows-x64-3.0.3.zip` | 解压到任意目录 → 双击 `ovimap.exe` |
| macOS Universal | `ovimap-macos-universal-3.0.3.zip` | 解压 → 拖入「应用程序」；首次打开需「右键 → 打开」绕过 Gatekeeper |

**macOS 验收清单**（针对本次修复）

1. 窗口打开即为**三栏桌面布局**（菜单栏 / 工具栏 / 左右栏 / 提示栏 / 状态栏），不是手机竖屏界面；
2. **滚轮缩放可用**，且以鼠标指针为锚点；
3. 左键拖动平移；右键弹出上下文菜单；
4. 状态栏「鼠标 …」随鼠标移动实时变化；
5. `Ctrl+0` / `⌘0` 复位视图；`+` `-` 缩放；
6. 进入测距后 `Backspace` 退点、`Esc` 结束；
7. 在搜索框里打字：`Backspace` / `Delete` / `+` / `-` 正常输入（不触发地图动作）；
8. 导出时弹出**系统「另存为」对话框**。

## 6. 已知项（未在本次范围）

- `get-task-allow` 加固（见 v3.0.2 说明）仍待处理；
- 左栏图层显隐目前是眼睛图标按钮（奥维用复选框），语义一致，纯视觉差异；
- 点位平移仍走「右键 → 待点放置 → 左键落点」，非奥维的鼠标拖拽手柄；
- 触控板双指**捏合**缩放未启用（双指滚动已能缩放）。
