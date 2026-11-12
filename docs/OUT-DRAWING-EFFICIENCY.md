# 出图效率专项（OUT-DRAWING）

> 视角：**线路设计人员**。从现场打完点回到电脑前，到交出一张能施工的图纸，中间哪些步骤在白白消耗时间。

---

## 0. 一句话结论

本轮把「打点 → 连杆路 → 段标 → 体检 → 出图」这条链上**三处口径**收敛成一份真源，
并补上出图前的**一键体检**、**批量设敷设方式**、**左栏段落表**，把原先"一档一档点着改"
的工作量压到几次操作。

---

## 1. 先问：时间到底消耗在哪

| 环节 | 改造前的实际动作 | 痛点性质 |
|---|---|---|
| 填敷设方式 | 点中一档 → 去右栏找「本段敷设方式」→ 点 chip → 点保存 → 回地图找下一档 | **重复劳动**（几十档 = 几十次） |
| 改某一档的段标 | 图上找那一档（缩放/平移）→ 点中 → 右栏改 → 保存 | **寻址成本**高于编辑成本 |
| 核对段距 | 切到地图找那一档看数字；想改还得再回右栏 | **屏/图之间来回切** |
| 出图前检查 | 肉眼一档一档扫：漏点、重名、忘了填方式 | **肉眼不可靠**，几十档必漏 |
| 一致性问题 | 屏幕写 42、图上写 42.0；屏幕写 1.05km、图上写 1050 | **出图事故**（拿去施工的图纸数字不一致） |

---

## 2. 关键设计：段标必须"推导"，不能"写死"

### 2.1 一个必须讲清的反面案例

最初实现的 `autoFillSegLabels` 是这样做的：把 `前缀 + 距离`（如 `架38`）作为**字符串写进
`MapLabel.distLabel`**。看着能用，实际埋着一颗雷：

> 设计人员出图后甲方要求挪一个点，段距从 38 变 55。
> 但 `distLabel` 里焊死的还是 `架38`，图上标着一个**错数字**，无人察觉。
> 这类图纸是拿去施工的，错一个数字就是现场返工。

所以**正确做法是让段标实时推导**：

```
段标文字 = distLabel（用户手填，优先级最高）
         ∪ kindPrefixOf(segKind) + 实测段距   ← 架空→架 / 埋地→埋 / 管道→管
         ∪ 全局 segPrefix + 实测段距
```

`MapLabel.segKind` 本来就存了敷设方式，前缀完全可以算出来，**不需要落地成字符串**。
距离一变，段标自动跟着变。

于是"省手工"的正确路径不是"批量生成段标"，而是：

> **框选一排点 → 批量设敷设方式 → 全线段标自动变成 `埋42.5`**

`autoFillSegLabels` 降级保留，仅用于"要把当前自动显示固化到纸质图纸"的场景，
且文档注释里明确写了它的代价（固化后不再跟随）。

### 2.2 唯一真源清单

| 真源 | 位置 | 覆盖 |
|---|---|---|
| 段落视图 | `lib/geo/route_segments.dart` → `RouteSegment.build()` | 复用既有 `buildLabelChains()`，段数恒等于 `Σ(链长-1)` |
| 段标文字 | `GeoUtil.segTextFor` / `segTextPreview` | 地图段标、DXF 标注、左栏段落表、右栏预览、编辑框补距 |
| 距离文字 | `GeoUtil.segDistText` | **一律用米**、整数不留 `.0`；禁止用 `fmtSegLen` 的 km 口径 |
| 段距 | `GeoUtil.segLenLabelFirst` | 标注优先口径（结算/里程）；`RouteSegment.lengthM` 是几何口径，两者分工见源码注释 |

> **为什么段标不用 km**：`fmtSegLen` 超过 1km 会切成 `1.05km`，而 DXF 标注图层单位就是米。
> 于是同一条长杆档在屏幕上写「埋1.05km」、在图上写「埋1050」——审图时对不上账。
> 通信线路的档距/段距行业口径本来就是米，统一用米既合规又不分叉。

---

## 3. 交付清单

### 3.1 出图体检（新增）

`lib/analysis/route_check.dart`（纯函数引擎）+ `lib/ui/desktop/inspect_dialog.dart`（面板）

| code | 级别 | 触发 |
|---|---|---|
| `seg_too_short` | 错误 | 段距 < 5 米（疑漏点） |
| `seg_too_long` | 警告 | 段距 > 200 米（超架空档距经验值） |
| `seg_no_kind` | 警告 | 未填敷设方式 |
| `seg_no_cable` | 警告 | 未填光缆型号（竣工模式） |
| `seg_slack_missing` | 警告 | 未填盘留（竣工模式） |
| `seg_label_drift` | 警告 | 手填标注与实测相对偏差 > 5% |
| `geo_jump` | 警告 | 段长 > 链内其余段均值×3 且 > 50 米（疑打点错位） |
| `label_dup_name` | 警告 | 点重名 |
| `label_unnamed` | 提示 | seq>1 且未命名 |
| `label_seq_gap` | 提示 | 链内相邻点序号不连续 |

设计取舍：

- **不自动改图**。唯一的"一键修"是「清除漂移段标」——它只是把手填的、与几何不符的数字清掉，
  让段标回到自动生成，无副作用。出图是责任行为，机器不该替设计人员判断"这档 3 米是不是漏点"。
- 每条都带**具体数字 + 人话 + 可执行建议**，不写"存在异常"这种没法行动的话。
- 点「定位」**先关面板再跳图**，否则遮罩挡住地图，用户看不到"跳过去了"。

### 3.2 左栏段落表（新增）

`lib/ui/desktop/left_panel.dart` → 「本工程 / 段落 / 点位」

把全线的段按顺序铺出来，**在哪一档改哪一档**，一眼看到整条线路的段距分布。
内联编辑含 `架/埋/管` 前缀 chip：点一下就把前缀套到已有数字前，没数字则自动补本段实测距离
——这就是用户说的「42 改为 埋42」一步到位。

> ⚠️ 实现坑：输入框上的 `onTapOutside` 会在**指针按下时**就提交并关闭编辑态。
> 若不把这排 chip 用 `TextFieldTapRegion` 标成输入框的**同组区域**，用户点「埋」
> 会被当成"点到框外"——先提交半截文字、编辑器随即消失，chip 永远点不中。

### 3.3 右栏属性面板（重做）

- **段标实时预览**：输入框下方直接显示「图上显示：埋42」。改前用户看不到图上会写成什么，
  要切回地图找那一档才能确认。预览读的是**编辑态**（输入框里的字 + 刚点的 chip），
  走 `GeoUtil.segTextPreview` 同一份规则。
- **未保存可见 + 切换自动落盘**：8 个字段共用一个保存键，改完忘点、或改完直接去点另一个点，
  改动就静默丢了。现在标题栏出「未保存」橙标、保存键点亮，且**切换到别的点时先自动写回**
  （走 `st.updateLabel` / `updateOverlayLabel`，含 `_saveDraft`——只改内存对象等于重启还原）。
- 敷设方式 chip 的选中色改用 `TokC.kind(k)`：选「架空」就是左栏/图例上的那根绿线，
  不再是又一个蓝按钮。

### 3.4 图源 / 图层面板（定宽 + 卡片网格）

`lib/ui/desktop/source_panel.dart`

改前 `showSourceDialog` 用了 `width: double.maxFinite`，把这个只有一列单选的对话框
撑到接近整窗宽（1600px 窗口 ≈ 1520px 宽），每行只有一个 `RadioListTile` —— 大量空白、
视线横扫距离过长。现固定 **480px**，主图源改 **2 列卡片网格**（坐标系徽标 + 最大级别前置可见），
当前源强调边框 + ✓。

顺带修掉一个真实缺陷：「注记叠加层」原用 `CheckboxListTile` 承载**互斥**语义
（`onChanged` 里做的是 `applyOverlay(v ? id : null)`），用户会以为能多选。已改回 `Radio`。

---

## 4. 验证方式

```bash
cd <项目根>
# 门禁（⚠️ 必须绕开本机代理，否则 flutter_tester 的本地 WebSocket 被吃掉、全红）
flutter analyze                                   # 0 error / 0 warning
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost flutter test -j 4

# 本轮新增的护栏
flutter test test/route_segments_test.dart         # 段落真源
flutter test test/route_check_test.dart            # 体检引擎（每 code 正/反例）
flutter test test/auto_fill_seg_labels_test.dart   # 固化用途（降级后）
flutter test test/left_panel_draft_test.dart       # 左栏段落表 + 就地改段标
flutter test test/right_panel_test.dart            # 右栏预览 + 防丢保存
flutter test test/inspect_dialog_test.dart         # 体检面板
flutter test test/source_panel_test.dart           # 图源面板定宽
flutter test test/out_drawing_workflow_test.dart   # ★ 跨环节端到端（含"挪点后图上不留旧数字"）
```

`test/out_drawing_workflow_test.dart` 是本专项最关键的一条：它**跨环节**验证
「屏幕段标 == 体检报告数字 == DXF 图纸文字」，并锁住两个曾经出过错的行为——
挪点后段标自动跟随、长杆档（≥1km）屏图不分叉。

---

## 5. 遗留与后续

| 项 | 说明 |
|---|---|
| 体检项可配置 | 目前下限/上限/阈值写在 `RouteCheckOptions` 默认值里，尚未开放到 UI 设置 |
| `applyBatch` 返回值语义 | 返回的是**受影响点数**而非段数（历史语义，未改）；UI 文案上若要显示"N 段"需另算 |
| 图标线条统一 | 现混用 15/16px，属视觉打磨剩余项 |
| hover/active 过渡 | 面板与按钮的交互态切换仍是硬切，无过渡 |
| 存量硬编码字号 | `dialogs.dart` 104 处、`home_page.dart` 41 处等，按文件逐步推进 |
