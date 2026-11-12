# 桌面界面设计说明（DESKTOP-UI）

> 适用范围：Windows / macOS / Linux 桌面壳（`lib/ui/desktop/`）。
> 设计参照：**奥维互动地图桌面版**（下称「奥维桌面版」）的布局与交互口径。
> 相关文档：[BUILD-windows.md](BUILD-windows.md) · [BUILD-macos.md](BUILD-macos.md) · [USAGE.md](USAGE.md)

---

## 0. 一句话结论

**桌面端不是移动端的放大版。** 它有一套独立的 Chrome（菜单栏 / 工具栏 / 三栏 / 提示栏 / 状态栏）和一套独立的地图交互口径，只在「业务核心 + 数据模型 + 共享图层构建」这三层与移动端复用同一份代码。

把手机竖屏界面拉宽塞进桌面窗口，是 2026-09 那一版 macOS 包「界面变形严重、地图缩放不管用」的直接原因。本文记录问题根因、修复位置，以及桌面端相对奥维桌面版**对齐了什么、刻意不一样的是什么、为什么**。

---

## 1. 问题 → 根因 → 修复

| 现象（用户反馈） | 根因 | 修复位置 |
|---|---|---|
| macOS「界面变形严重，不能按照手机的界面来设计电脑的界面」 | `main.dart` 用 `Platform.isWindows` 挑壳，**macOS 被判成移动端**，落到 `HomePage` 移动竖屏壳；宽窗口下底部条、抽屉、竖排工具栏全被拉变形 | `lib/main.dart`：改用 `PlatformCaps.isDesktop` |
| macOS 上窗口方向被锁竖屏 | 竖屏锁的判据同样是 `Platform.isWindows` | `lib/main.dart`：`!PlatformCaps.isDesktop` 才锁竖屏 |
| 窗口只有 800×600，三栏被挤成一团 | `flutter create` 模板的 `MainMenu.xib` 默认尺寸，Dart 侧无法覆盖 | `macos/Runner/MainFlutterWindow.swift`：1440×900，最小 1024×680，并按可见屏幕收敛 + 居中 |
| macOS「地图缩放不管用」 | macOS 跑的是移动壳，而 `MapCanvas` 的**默认** flags 是移动口径（`pinchZoom\|drag\|doubleTapZoom\|rotate`），**不含 `scrollWheelZoom`** → 滚轮完全没接线。（Windows 之所以能滚，是因为旧桌面壳额外传了 `InteractiveFlag.all`。） | `lib/ui/map/map_canvas.dart`：默认值收口到 `defaultFlagsForCurrentPlatform()`；桌面壳**不再覆盖** |
| 按住 Ctrl 移动鼠标时地图被转掉，Ctrl+Z/S/E 顺手把图转歪 | flutter_map 的 `CursorKeyboardRotationOptions` 默认把 Control 键当旋转触发键，与桌面快捷键直接冲突 | `lib/ui/map/map_canvas.dart`：桌面用 `CursorKeyboardRotationOptions.disabled()` |
| `Platform.isWindows` 散落各处，改一处漏一处 | 平台能力判断没有单点收口 | `lib/services/platform_caps.dart`：`isDesktop` / `hasGps` / `hasCompass` / `hasCamera` / `supportsFileSaveDialog` |
| macOS「最上面有 1 排英文设置菜单，下面还有一排中文设置菜单」 | 英文那排是 **macOS 原生主菜单**（`MainMenu.xib`，Flutter 侧根本没有英文字符串）；中文那排是应用自绘菜单。两者互不知情，于是叠加成两排 | `lib/ui/desktop/app_platform_menu_bar.dart`：`PlatformMenuBar` **整体接管**主菜单（含应用菜单的 隐藏/退出）；`workspace_page.dart` 在 macOS 下**不渲染**自绘那一行 |
| 「切换设置菜单每次都要点击 2 次」 | `PopupMenuButton` 的交互是「点标题展开 → 点条目执行」；而 Flutter 的 `MenuBar` / `SubmenuButton` **都不支持悬停展开**（`menu_anchor.dart` 里没有 `MouseRegion`/`onHover`） | macOS 用原生菜单（横扫即切换）；Windows/Linux 在 `app_menu_bar.dart` 自绘 `OverlayEntry` + `MouseRegion`：停留 120ms 展开、展开后横扫立即切换 |
| 桌面端「竣工模式没了、很多符号标签也没了」 | **不是回归，是桌面壳从来没做**：`chooseEditMode` 只在 `home_page.dart` 被调用，`setType` / `LabelType.all` 的符号选择器也只有移动端有 → 桌面端落点前无法选符号 | `lib/ui/desktop/toolbar.dart`（符号库按钮 + 设计/竣工模式）+ `symbol_library.dart`（16 符号）；菜单开两个入口 |
| 「地图的利用率不如奥维大」 | 左右栏常驻 260+300 ≈ 572px，1440 窗口下地图只剩 868px（60%） | `workspace_page.dart`：左 220 / 右 280、**右栏默认收起且选中点自动展开**；工具栏 48→42；新增「专注地图」`⌥⌘M`（详见 §3.1） |
| 「主题变成白色」 | Flutter 侧本就是 `Brightness.dark`；白的是 **macOS 系统外壳**（系统菜单栏 + 窗口标题栏跟随系统浅色模式） | `macos/Runner/AppDelegate.swift`：`applicationWillFinishLaunching` 里钉 `NSApp.appearance = darkAqua`（放这里才不闪白）+ 窗口底色对齐 `0xFF101418` |
| 「42 应能显示成 埋42」 | 数据层早有 `distLabel`，但前缀 chip 在输入框为空时**只填出光秃秃一个「埋」**（不会带上该段已有的距离）；也没有全局前缀 | `lib/geo/geo_util.dart` 的 `segLabelFor` 收敛为**唯一真源**（地图 / DXF / 成册共用）；`AppState` 加持久化的「段标前缀」；`segPrefixChips` 加 `autoDist` 参数 |
| 「主题我不喜欢黑色，弄成白色」（v3.3.0） | 上一轮把 macOS 外壳钉成深色是对的（消除上白下黑），但用户要的是**整体浅色** | v3.3.0 全面翻白：`design_tokens.dart` 的 `TokC` 换浅色调色板（面板 `FAF9FAFB`、强调 `0288D1`、正文 `1C242C`）；`main.dart` `Brightness.light`；macOS 宿主 `NSApp.appearance = aqua` + 窗口底色 `0xF2F4F6`。**三个落点必须同改**，缺一个就出现「上黑下白」或「上白下黑」 |
| 「添加的轨迹和标签没有保存功能」（v3.3.0） | `openCollection` 后打点 / 删点 / 撤销 / 续画只写 `draft.json`，收藏文件停在打开时的旧内容，重启即丢 | `app_state.dart` 的 `_saveDraft()` 收口：`activeCollectionId` 非空时同步写回 `collection_<cid>.json`；新增 `startNewDraft()` 保证「先脱离收藏再清空」。护栏测试 `test/collection_autosave_indep_test.dart` |
| 「新建一个（文件夹）就出现 2 个」（v3.4.0） | `_addFolder` 的 `onSubmitted` 里 `created.complete(st.store.addFolder(...))`：回车后**对话框不关闭**；再按回车时 `complete` 的参数表达式**先求值**（第二个 `addFolder` 已发出）才抛 StateError，两个并发写盘竞态后同名文件夹出现两个 | `left_panel.dart`：改为单一提交口 `submit()` + `done` 闸门，回车/按钮谁先来都只建一次，**回车立即关框**；`showFinishDialog` 内的「新建文件夹」同口径封堵 |
| 「收藏夹用叠加功能实现多级访问」「左栏做个收藏夹图标」「右栏鸡肋」「移动文件不满意」「打点弹属性框烦」（v3.4.0） | 文件夹树平铺全树、移动是逐文件夹按钮、左右栏常驻挤占地图、竣工模式逐点弹属性框 | `left_panel.dart` + `workspace_page.dart` + `map_canvas.dart` 全面重排：① 文件夹树改**叠加式导航**（`_nav` 栈逐级钻入，「..」/面包屑返回，列表只显示当前层，搜索跨全库）；② 左栏收成 52px **图标轨道**，点「收藏夹」以 320px 悬浮面板**叠加**在地图上（Esc/再点收起）；③ 右栏默认隐藏，选中点**不再自动展开**；④ 移动工程改**下拉选择**（层级缩进 + 根目录）；⑤ 打点不再自动弹属性框（补属性走右键「编辑属性」）。护栏测试 `test/favorites_stack_nav_test.dart` |
| 「界面像奥维：收藏夹/文件夹树定版」（v3.6.0，用户给奥维截图） | v3.4 的悬浮叠加面板遮挡地图、逐级钻入不如整树直观；截图里奥维是**常驻停靠左栏 + 整树平铺** | `workspace_page.dart`：面板改回**停靠**（默认打开、可拖宽 220~460、可收起成 52px 图标轨道）；`left_panel.dart`：删掉 `_nav` 钻入栈与面包屑，改**整树平铺**——根「收藏夹[n]」+ 各级文件夹，+/− 折叠（`_collapsed` 记录收起项，未记录=展开）、黄色文件夹图标 `0xFFE6A23C`、名称后 `[工程数]`；点名称选层过滤下方列表（`_selFolder` 同步 `st.folderId`），删除文件夹后选中复位；护栏测试 `test/favorites_stack_nav_test.dart` 重写为树口径 |

> **教训**：平台分支只有一处（`main.dart`），平台能力只有一处（`PlatformCaps`）。
> 新增平台相关判断时一律走 `PlatformCaps.isDesktop`，**不要写单一平台的 `isXxx`** ——
> `hasGps` 曾经写成 `!Platform.isWindows`，把 macOS / Linux 误判成「有 GPS」，
> 这类错误在移动端跑不出来、只在桌面端炸。

---

## 2. 与奥维桌面版的对照表

| 奥维桌面版的做法 | 本应用 | 状态 |
|---|---|---|
| 顶部菜单 + 工具栏 | 菜单栏（文件 / 编辑 / 工程 / 底图 / 同步 / 帮助）+ 图标工具栏 | ✅ 对齐 |
| 左侧「收藏夹」面板：目录树 + 逐项控制显隐 | 左栏：文件夹树 + 工程列表，每项右侧「显示到地图 / 从地图隐藏」按钮；**文件夹/工程均支持右键菜单**（新建子文件夹 / 重命名 / 删除 / 移动 / 批量删除），删除有确认且内容上移不丢 | ✅ 对齐（v3.3.0 补齐右键菜单与删除） |
| 中央地图 | 中央地图（含比例尺、右键菜单、业务符号图层） | ✅ 对齐 |
| 右侧属性面板 | 右栏：选中点位的属性编辑 + 来源工程 | ✅ 对齐 |
| 底部状态栏：**鼠标指针处经纬度** + 显示级别 + 坐标系 | 状态栏：鼠标经纬度 + 视图中心 + 图源 + 缩放级别 + 选中数 + 同步态 + 坐标系 | ✅ 对齐 + 增强 |
| 模式提示栏（当前操作提示） | 提示栏：模式胶囊 + 键盘提示 + 实时数据 + 「完成 (Esc)」 | ✅ 对齐 |
| 滚轮缩放以**鼠标指针为锚点** | flutter_map `scrollWheelZoom` 原生以指针为锚 | ✅ 对齐 |
| 左键拖动平移 | `InteractiveFlag.drag` | ✅ 对齐 |
| 方向键微移地图 | flutter_map `KeyboardOptions.enableArrowKeysPanning`（默认开） | ✅ 对齐 |
| 右键上下文菜单 | `onSecondaryTap` → 地图上下文菜单 | ✅ 对齐 |
| 双击结束折线绘制 | **不采用**，结束动作交给 `Esc` 与提示栏「完成」 | ⚠️ 有意差异，理由见 §4 |
| 双击缩放 | **桌面不启用** | ⚠️ 有意差异，同上 |

---

## 3. 桌面 Chrome 的组成与尺寸

自下而上（`lib/ui/desktop/workspace_page.dart` 的 `Column`）：

| 部件 | 文件 | 高度 | 说明 |
|---|---|---|---|
| 菜单栏 | `app_menu_bar.dart`（Windows/Linux）<br>`app_platform_menu_bar.dart`（macOS） | 34 / 0 | **macOS 不占窗口高度**：菜单渲染到屏幕顶部系统菜单栏，窗口内这一行不画 |
| 工具栏 | `toolbar.dart` | 42 | 打点 · **符号库** · **设计/竣工模式** · 连线 · 测距 · 轨迹 · 定位 · 撤销 · 重做 · 删除 · 缩放 ± · 图源 · 导出 · 同步 · 折叠左右栏 |
| 三栏主体 | `left_panel / map / right_panel` | `Expanded` | 左 220（可拖 180–420）、右 280（可拖 240–460），分隔条可拖拽 |
| **模式提示栏** | `workspace_page._hintBar` | **30** | 模式胶囊 + 操作提示 + 实时数据 + 「完成 (Esc)」 |
| 状态栏 | `status_bar.dart` | 26 | 设备 · 同步 · 最后同步时间 · **鼠标经纬度** · 视图中心 · 图源 · 缩放 · 选中数 · 坐标系 |

**窗口下限**：1024×680（与 Windows 侧 `win32_window.cpp` 的 `WM_GETMINMAXINFO`、macOS 侧 `MainFlutterWindow.contentMinSize` 一致）。
窗口宽 < 1180 时右栏自动收起（`_body` 里的阈值），避免挤压地图。

### 3.1 地图占屏口径（v3.1.0 调整）

右栏是「选中点的属性检查器」，**默认收起**，选中点时才自动展开；取消选中**不**自动收起
（用户常在连续核对多个点，频繁开合会打断操作）。要主动全屏看图用
「视图 → 专注地图」`⌥⌘M`，再按一次**还原**到进入前状态（而不是盲目全展开）。

| 场景（1440×900） | 地图宽度 | 占比 |
|---|---|---|
| 改造前（左右栏常驻 260+300） | 868px | ~60% |
| 现在：未选中点（右栏收起，左栏 220） | 1214px | ~84% |
| 现在：选中点（左 220 + 右 280） | 928px | ~64% |

### 3.2 菜单架构：一份定义，两种渲染

菜单定义只存在于 **`lib/ui/desktop/menu_model.dart`**（`oviMenuGroups` + `dispatchOviMenuItem`）。
两端只负责渲染，**不得各自写一套菜单** —— 否则会出现「macOS 有这一项、Windows 没有」的漂移：
本项目桌面壳当初缺「符号库」与「设计/竣工模式」入口，正是这种漂移的后果。

| 平台 | 渲染器 | 落点 | 展开方式 |
|---|---|---|---|
| macOS | `PlatformMenuBar` | 屏幕顶部系统菜单栏 | 原生：点击展开，展开后横扫即切换；`⌘` 原生 |
| Windows / Linux | 自绘 `OverlayEntry` + `MouseRegion` | 窗口内第一行 | 指针停留 120ms 展开；展开后横扫立即切换；离开 200ms 收起 |

四条硬规则（都有单测护栏，见 `test/macos_native_menu_test.dart`）：

1. **应用菜单必须自己建**。`PlatformMenuBar` 接管的是**整个**主菜单，
   包括 macOS 那个以应用名命名的第一个菜单。Flutter 不会替你生成它 ——
   漏了就是用户失去 ⌘Q（退出）与 ⌘H（隐藏）。系统级行为（隐藏 / 退出 /
   最小化 / 缩放 / 全屏）走 `PlatformProvidedMenuItem`，这些是 `hide:` /
   `terminate:` 之类的 selector，纯 Flutter 复刻不了。
2. **裸键不当菜单快捷键**。把 `Delete` 声明成菜单 key equivalent 会把按键
   从文本框里抢走（左栏搜索框里删不掉字）。裸键仍由 `shortcuts.dart` 按
   「主焦点不在 `EditableText` 内」注册，菜单里只写文案提示。
3. **带修饰键的快捷键可以声明，不会双重触发**。按 Apple《Handling Key Events》
   的派发顺序，按键先沿**视图层级**（Flutter 视图）走 `performKeyEquivalent:`，
   只有视图层不处理时才轮到菜单栏 —— 两条路径命中同一动作，且一条命中即终止。
4. **`PlatformCaps.isMacOS` 与 `isDesktop` 是两回事**。`isMacOS` 只用于
   「原生菜单栏」这类 macOS 独有能力；`hasGps` / `hasCompass` / `hasCamera` /
   `supportsFileSaveDialog` 一律继续用 `isDesktop`（历史的
   `Platform.isWindows` 散判就出过错，见 §1）。

---

## 3.3 尺度收敛：把「界面太粗糙」变成可度量的事（v3.2.0）

### 先量化，再动手

「粗糙」不是审美问题，是**局部合理、整体不齐**。动手前先数了一遍：

| 维度 | 收敛前 | 收敛后 |
|---|---|---|
| 全项目字号档位 | **11 档**：9 / 9.5 / 10 / 10.5 / 11 / 11.5 / 12 / 12.5 / 13 / 13.5 / 15 | **6 档**：10 / 11 / 12 / 13 / 14 / 15 |
| 桌面壳四主文件（左栏 / 右栏 / 工具栏 / 外壳）硬编码字号 | 25 处 | **0 处** |
| 圆角档位（右栏/左栏/工具栏） | 4 / 5 / 9 / 10 四档即兴取值 | 统一 `TokR`（6 / 8 / 12） |
| 颜色硬编码（右栏） | `0xFF141920`、`Colors.white12`、`white24`、`0xFFFF5252`、`0xFF232A31` | 全部走 `TokC` |

相邻两档只差 0.5px 肉眼几乎不可分辨，却让每处界面都在"再微调一点点"——这正是粗糙感的来源。

### 唯一真源：`lib/ui/design_tokens.dart`

| 类 | 内容 | 使用约定 |
|---|---|---|
| `TokSp` | 间距 2/4/8/12/16/24 + `panelPad`/`titlePad`/`rowPad` | 4 的倍数，不再出现 5/7/9/14 |
| `TokR` | 圆角 6 / 8 / 12 | 小控件 / 常规控件 / 容器 |
| `TokFs` | 字号 10 / 11 / 12 / 13 / 14 / 15 | micro / caption / small / body / title / heading |
| `TokC` | 配色 + 领域语义色 `TokC.kind(k)` | 敷设方式色标与 `RouteSegment` 枚举同源 |

> `dialogs.dart` 里的 `kAccent`/`kTextMain` 等**历史名字保留为编译期转发别名**
> （`const Color kAccent = TokC.accent;`），几十个调用点一行不用改，但值只有一份。

### 分层推进的边界（诚实说明）

- **已清零**：桌面壳四主文件 + `inspect_dialog` + `source_panel` + `right_panel`。
- **存量未动**：`dialogs.dart`（104 处）、`home_page.dart`（41 处）等移动端/对话框文件。
  这些是**存量**不是本轮引入，且改动面大、收益边际，留给后续按文件推进
  （`grep -rEc "fontSize: [0-9]" lib/` 可看剩余分布）。

---

## 4. 地图交互口径（flags）

`lib/ui/map/map_canvas.dart` → `defaultFlagsForCurrentPlatform()`

| 能力 | 移动 | 桌面 | 原因 |
|---|---|---|---|
| `drag` 平移 | ✅ | ✅ | 桌面为左键拖拽 |
| `scrollWheelZoom` 滚轮缩放 | — | ✅ | **桌面缩放的主力入口**，缺了滚轮就没反应 |
| `doubleTapZoom` 双击放大 | ✅ | ❌ | 见下方「250ms 代价」 |
| `pinchZoom` 双指缩放 | ✅ | ❌ | 桌面无多指；触控板双指滚动已由 `scrollWheelZoom` 覆盖 |
| `rotate` 旋转 | ✅ | ❌ | 出图要求正北朝上；且旋转会抢右键菜单 / 框选事件 |
| `flingAnimation` 惯性滑动 | ❌ | ❌ | 测绘要「停手即停」，惯性会让定点对不准 |

### 4.1 桌面为什么不启用双击缩放：单击会被延迟 250ms

flutter_map 的点击判定在 `PositionedTapDetector2`（`gestures/positioned_tap_detector_2.dart`）：

```dart
static const _defaultDelay = Duration(milliseconds: 250);   // 双击判定窗口
static const _doubleTapMaxOffset = 48.0;                    // 双击的最大像素偏移
...
void _onTapEvent() {
  if (widget.onDoubleTap == null) {
    _postCallback(pending, widget.onTap);   // 立刻回调：零延迟
  } else {
    _sink.add(pending);                     // 进流，等 250ms 超时才算「单击」
  }
}
```

而 `MapInteractiveViewer` 只在 flags 含 `doubleTapZoom` 时才给 `onDoubleTap` 传值
（`InteractiveFlag.hasDoubleTapZoom(flags) ? ... : null`）。

**结论：开双击缩放 = 每一次单击落点都要等 250ms 才发生。**

对本应用（现场打点，一条线要点几十上百下）这个延迟是硬伤。因此桌面端主动关闭双击缩放，
改用**四条缩放通道**：滚轮 / `Ctrl±`（含裸 `+` `-`）/ 工具栏缩放按钮 / 方向键微移。

移动端维持原有口径不动 —— 改它会牵动既有手感与整轮回归，收益不成正比。

### 4.2 与奥维「双击结束绘制」的有意差异

奥维的连续画线有「绘制中」状态机，双击是自然的收尾手势。本应用**没有**连续画线状态：
每次单击独立落点，杆路链是由点位自动串起来的。因此：

- 结束动作 = `Esc` / 提示栏「完成」按钮；
- 全部模式都**不需要**延迟单击去等待第二次点击，落点手感是即时的。

代价是少了奥维那一下双击；换来的是打点零延迟。这是一次刻意的取舍，不是缺项。

---

## 5. 快捷键

实现：`lib/ui/desktop/shortcuts.dart`（`Shortcuts` + `Actions` + `Intent`，零新依赖）。

| 键 | 作用 | 生效条件 |
|---|---|---|
| `Ctrl+S` / `⌘S` | 保存工程 | 始终 |
| `Ctrl+Z` / `⌘Z` | 撤销 | 始终 |
| `Ctrl+Y` / `Ctrl+Shift+Z` / `⌘⇧Z` | 重做 | 始终 |
| `Ctrl+E` / `⌘E` | 打开导出中心 | 始终 |
| `Ctrl+F` / `⌘F` | 聚焦左栏搜索 | 始终 |
| `Ctrl+O` / `⌘O` | 打开 `.ovimap` 工程 | 始终 |
| `Ctrl` + `=` / `+` 、`⌘±` | 放大一级 | 始终 |
| `Ctrl` + `-` 、`⌘−` | 缩小一级 | 始终 |
| `Ctrl+0` / `⌘0` | 复位到启动视图 | 始终 |
| `Alt+Ctrl+L` / `⌥⌘L` | 折叠 / 展开左栏 | 始终 |
| `Alt+Ctrl+R` / `⌥⌘R` | 折叠 / 展开右栏 | 始终 |
| `Alt+Ctrl+M` / `⌥⌘M` | 专注地图（两侧全收 / 再按还原） | 始终 |
| `+` `=` `-`（含小键盘） | 放大 / 缩小一级 | **非文本编辑态** |
| `0`（含小键盘） | 复位到启动视图 | 非文本编辑态 |
| `Esc` | 取消当前操作 / 结束模式 | 非文本编辑态 |
| `Backspace` | 退掉最后一个点 / 最后一条连线 | 非文本编辑态 |
| `Delete` | 删除选中点 | 非文本编辑态 |

### 5.1 为什么裸键要按「是否在编辑文本」开关

`Shortcuts` 沿焦点链**由内向外**冒泡，而 `DesktopShortcuts` 位于 `WidgetsApp` 的
`DefaultTextEditingShortcuts` **内侧**（更靠近焦点）。也就是说，只要无条件注册
`Delete` / `Backspace` / `+` / `-`，文本框内的「向后删除 / 退格 / 输入 +−」就会被这一层截胡 ——
左栏搜索框、属性对话框全都失灵。

所以裸键表随「当前主焦点是否落在 `EditableText` 子树内」动态开关
（`FocusManager` 是 `ChangeNotifier`，焦点变化时只 `setState` 本组件；
`child` 是同一个 Widget 实例，Element 复用，**不会**连地图一起重建）。
带修饰键的条目（Ctrl/⌘ 组合）不参与开关，始终生效。

---

## 6. 状态栏的「鼠标经纬度」为什么用 ValueNotifier

`onPointerHover` 在鼠标移动时按帧触发。若把它接到壳的 `setState`，
整个 `WorkspacePage`（含 `MapCanvas`）会跟着重建 —— 直接拖垮滚轮缩放和拖拽平移的手感。

做法（`workspace_page._onMouseGeo` → `status_bar`）：

1. `MapCanvas.onPointerGeo` 回传 **WGS-84**（显示基准的换算只做一次，且由壳负责）；
2. 壳把 WGS-84 换成当前显示基准并格式化，**只有格式化文本真的变化时**才写
   `ValueNotifier<LatLng?>`（按像素去重，避免每帧一次通知）；
3. `StatusBar` 内部用 `ValueListenableBuilder` 局部监听，只有那一个文本节点重建。

鼠标移出地图 → 回传 `(null, null)` → 状态栏显示「鼠标 ——」。

---

## 7. 模式提示栏的内容口径

`workspace_page._hintContent`，与移动端底部条同源同口径（同一套模式枚举、同一套统计），只是排布按桌面横屏重排。

| 模式 | 胶囊 | 操作提示 | 右侧实时数据 |
|---|---|---|---|
| 采集（edit） | 采集中·{当前符号} | 左键落点 · Backspace 退点 · Ctrl+Z 撤销 · Delete 删除选中 · Ctrl+S 保存 | n 点 · 已连 X / Y 段 |
| 待定放置 | 待定放置 | 点地图把该点放到新位置 · Esc 取消 | — |
| 测距 | 测距 | 左键加点 · Backspace 退点 · 完成 (Esc) 结束测量 | 总长 / n 点 |
| 测面积 | 测面积 | 左键加顶点 · Backspace 退点 · 完成 (Esc) 结束测量 | 面积 / n 点 |
| 拓扑连线 | 拓扑连线 | 点起点箱体 → 点终点箱体 · Backspace 退一条连线 · 完成 (Esc) 结束 | 已连 n / m 个箱体 |
| 框选 | 框选 | 在地图上拖出矩形选择点位 · 完成 (Esc) 退出框选 | 已选 n 点 |
| 普通（view） | 普通 | 左键点选点位（右栏看属性）· 平移/缩放/右键/快捷键提示 | 已选 n 点 |
| 轨迹中 | 轨迹中 | 桌面端无 GPS，请在移动端沿线走查录制 | — |

`Esc` 的优先级（从「最临时」到「最正式」）：
**待定点位编辑 → 清空选择 → 退出框选 / 测量 / 连线**。
`Esc` **不清空草稿** —— 误触丢几十个点是不可接受的，清空草稿有专门入口（菜单 / 右键）。

---

## 8. 已知差异与后续项

| 项 | 现状 | 若要完全对齐奥维 |
|---|---|---|
| 左栏显隐控件 | 眼睛图标按钮（`st.toggleVisible`） | 换成 `Checkbox` 即可，语义已一致，纯粹是视觉差异 |
| 改点位靠对话框 | 「右键 → 待点放置 → 左键落点」 | 奥维是点住手柄直接拖；需要新增屏幕手柄命中层 |
| 触控板双指捏合缩放 | 不支持（双指滚动已能缩放） | 加 `InteractiveFlag.pinchZoom`，需先验证与 `drag` 的事件竞争 |
| 桌面端轨迹录制 | 明确不支持（无 GPS） | 保持：桌面端本就不具备定位硬件 |
| 「界面太粗糙」的整体观感 | **v3.2.0 已完成尺度收敛**（见 §3.3）：全项目字号 11 档 → 6 档、桌面壳四主文件硬编码字号清零、圆角/间距/配色统一走 `design_tokens.dart` | 还剩两项可继续：图标线条粗细统一（现混用 15/16）、hover/active 态的过渡动画 |

> **macOS 权限提示**：应用把外观钉成深色（`AppDelegate` 的
> `NSApp.appearance = darkAqua`）。这是刻意的 —— Flutter 内容区本就强制深色，
> 若窗口装饰跟随系统浅色模式，就会出现「上白下黑」的割裂。

---

## 9. 验证清单（改桌面 UI 后必跑）

```bash
# 静态分析：0 error / 0 warning（info 允许）
flutter analyze --no-fatal-infos

# 测试（⚠️ 本机常开代理，必须绕开，否则 flutter_tester 的本地 WebSocket 会被代理吃掉）
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost flutter test -j 4

# 本地跑桌面壳
flutter run -d macos      # 或 -d windows
```

> `-j 4` 不是可有可无：本机 8GB，全套 74 个测试文件并发跑会把机器压满，
> 零星出现 `did not complete`（看着像挂，其实是被挤）。怀疑某个文件时先单跑它确认。

**菜单相关的专项测试**：`flutter test test/macos_native_menu_test.dart` ——
断言的是**实际交给 macOS 系统的那份菜单树**（顶层全中文、无 Edit/View/Window/Help、
应用菜单含 quit/hide、视图含竣工模式与专注地图），不是源码字符串。
`flutter test` 跑在宿主机上，所以 macOS 上 `PlatformMenuBar` 会走真实分支。

人工过一遍：滚轮缩放（以指针为锚）/ 左键拖动平移 / 右键菜单 / `Ctrl+0` 复位 /
`Esc` 结束模式 / `Backspace` 退点 / 状态栏鼠标经纬度随鼠标走动 /
文本框内退格与 `+-` 正常输入（第 5.1 节的回归点）/
**鼠标移到菜单标题上是否自动弹出、横扫是否直接切换** /
**系统浅色模式下顶部菜单栏与窗口标题栏是否仍为深色**。
