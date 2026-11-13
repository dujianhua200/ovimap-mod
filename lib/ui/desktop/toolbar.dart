import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../sync/sync_controller.dart';
import '../../sync/sync_models.dart';
import '../design_tokens.dart';
import '../dialogs.dart';
import 'symbol_library.dart';

/// 桌面工具栏（架构文档 §3.2 / T11）。
///
/// ## 与移动端的功能对齐（本轮修复）
///
/// 桌面壳此前**缺两个打点前必需的入口**，导致用户反馈「竣工模式没了、
/// 很多标签也都没了」：
///
/// | 能力 | 移动端 | 桌面壳（改造前） | 现在 |
/// |---|---|---|---|
/// | 选符号（16 种） | 底部符号行 | **无** | 工具栏「符号」按钮 → 符号库 |
/// | 设计/竣工模式 | 模式行两个 chip | **无** | 工具栏模式按钮 + 视图菜单 |
///
/// 两处都复用 `AppState` 既有能力（[AppState.setType] / [AppState.chooseEditMode]），
/// 不新增业务逻辑，保证两端行为一致。
class Toolbar extends StatelessWidget {
  const Toolbar({
    super.key,
    required this.st,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onTopo,
    required this.onTrack,
    required this.onLocate,
    required this.onSave,
    required this.onUndo,
    required this.onRedo,
    required this.onDeleteSelection,
    required this.onExport,
    required this.onSync,
    required this.onInspect,
    required this.leftCollapsed,
    required this.rightCollapsed,
    required this.onToggleLeft,
    required this.onToggleRight,
    this.sync,
  });

  final AppState st;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onTopo;
  final VoidCallback onTrack;
  final VoidCallback onLocate;
  final VoidCallback onSave;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onDeleteSelection;
  final VoidCallback onExport;
  final VoidCallback onSync;

  /// 出图体检（放在「导出成果」旁边：先体检、再出图）。
  final VoidCallback onInspect;
  final bool leftCollapsed;
  final bool rightCollapsed;
  final VoidCallback onToggleLeft;
  final VoidCallback onToggleRight;

  /// 云同步编排器（可为 null：未接入同步的环境 → 圆点显示「仅本地」）。
  final SyncController? sync;

  /// 工具栏高度。从 48 压到 42：桌面三栏壳里纵向每 6px 都是地图面积，
  /// 而图标本身 20px，42 仍是舒适点击区。
  static const double barHeight = 42;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: barHeight,
      decoration: const BoxDecoration(
        color: TokC.toolbar,
        border: Border(bottom: BorderSide(color: TokC.divider)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 6),
          _btn(Icons.pan_tool_alt,
              tooltip: st.mode == AppMode.edit ? '退出打点' : '打点（标记）',
              active: st.mode == AppMode.edit,
              onTap: () => st.setMode(
                  st.mode == AppMode.edit ? AppMode.view : AppMode.edit)),
          _symbolBtn(context),
          _modeBtn(context),
          _btn(Icons.push_pin_outlined,
              tooltip: '标记模式：点地图只放独立符号（不连线），每点一次自动存到收藏夹根目录「标记」',
              active: st.markMode,
              onTap: () {
                st.toggleMarkMode();
                toast(context,
                    st.markMode ? '标记模式：点地图即标记并自动保存；再点一次退出' : '已退出标记模式');
              }),
          _sep(),
          _btn(Icons.account_tree_outlined,
              tooltip: '连线路（拓扑）',
              active: st.mode == AppMode.topoLink,
              onTap: onTopo),
          _measureBtn(context),
          _btn(Icons.route, tooltip: '轨迹记录', onTap: onTrack),
          _btn(Icons.my_location, tooltip: '定位', onTap: onLocate),
          _sep(),
          _btn(Icons.save_outlined,
              tooltip: '保存到收藏夹 Ctrl+S',
              active: st.labels.isNotEmpty,
              onTap: onSave),
          _btn(Icons.undo, tooltip: '撤销 Ctrl+Z', onTap: onUndo),
          _btn(Icons.redo, tooltip: '重做 Ctrl+Y', onTap: onRedo),
          _btn(Icons.delete_outline,
              tooltip: '删除选中 Delete',
              enabled: st.selectedIds.isNotEmpty,
              onTap: onDeleteSelection),
          _sep(),
          _btn(Icons.add, tooltip: '放大', onTap: onZoomIn),
          _btn(Icons.remove, tooltip: '缩小', onTap: onZoomOut),
          _sep(),
          _btn(Icons.layers_outlined,
              tooltip: '图源 / 图层',
              onTap: () => showSourceDialog(context, st)),
          // 体检放在导出左侧：把"先查错、再出图"变成肌肉记忆。
          // 图标用 fact_check（清单打勾），比"放大镜"更像"逐项核对"而不是"搜索"。
          _btn(Icons.fact_check_outlined,
              tooltip: '出图体检 Alt+Ctrl+K（查段距/敷设方式/编号/标注一致性）',
              enabled: st.labels.isNotEmpty,
              onTap: onInspect),
          _btn(Icons.ios_share, tooltip: '导出成果 Ctrl+E', onTap: onExport),
          _syncBtn(context),
          const Spacer(),
          // 左栏收起按钮已删（v3.7）：收藏夹图标轨道本身就是收展入口，两个入口重复。
          _btn(
              rightCollapsed ? Icons.chevron_left : Icons.chevron_right,
              tooltip: rightCollapsed ? '展开右栏' : '收起右栏',
              onTap: onToggleRight),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  /// 符号按钮：显示当前符号的色块与符号字。
  ///
  /// 单击 → 打开符号库（选类型）；
  /// **长按 → 直接弹出颜色选择**（用户口径："打点的时候标签颜色可选，
  /// 只有黑色，看着太单调"）。选完立刻反映到按钮色块与地图上已打的点。
  Widget _symbolBtn(BuildContext context) {
    final t = st.curType;
    final glyph = t.symbol.isNotEmpty
        ? t.symbol
        : (t.name.isNotEmpty ? t.name.substring(0, 1) : '·');
    // 用户配的打点色优先（null = 跟随类型自带色）
    final shown = st.labelColorOrNull ?? t.color;
    return Tooltip(
      message: '符号库 · 当前「${t.name}」\n单击换符号，长按选颜色',
      child: InkWell(
        onTap: () => showSymbolLibrary(context, st),
        onLongPress: () => _pickDotColor(context),
        child: SizedBox(
          width: 44,
          height: barHeight,
          child: Center(
            child: Container(
              width: 26,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: shown.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(
                    t.shape == 'box' ? 3 : 999),
              ),
              child: Text(glyph,
                  style: const TextStyle(
                      color: Colors.white, fontSize: TokFs.small, height: 1.1)),
            ),
          ),
        ),
      ),
    );
  }

  /// 打点颜色选择（工具栏长按弹出）。
  ///
  /// 与「设置 → 地图标签颜色」共用同一个 `AppState.labelColor`，
  /// 所以选完之后地图上已打的点、后打的点、导出预览都是同一个颜色。
  Future<void> _pickDotColor(BuildContext context) async {
    const presets = <String, int>{
      '跟随类型': 0,
      '纯黑': 0xFF000000,
      '大红': 0xFFD32F2F,
      '橙色': 0xFFEF6C00,
      '金黄': 0xFFF9A825,
      '草绿': 0xFF2E7D32,
      '青色': 0xFF00838F,
      '宝蓝': 0xFF1565C0,
      '紫色': 0xFF6A1B9A,
      '玫红': 0xFFAD1457,
      '纯白': 0xFFFFFFFF,
    };
    final picked = await showMenu<int>(
      context: context,
      position: const RelativeRect.fromLTRB(120, 90, 0, 0),
      items: [
        for (final e in presets.entries)
          PopupMenuItem<int>(
            value: e.value,
            height: 38,
            child: Row(children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: e.value == 0
                      ? const Color(0xFF8A8A8A)
                      : Color(e.value),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0x44000000)),
                ),
              ),
              const SizedBox(width: 9),
              Text(e.key, style: const TextStyle(fontSize: 13)),
              if (e.value == st.labelColor) ...[
                const Spacer(),
                const Icon(Icons.check, size: 15, color: kAccent),
              ],
            ]),
          ),
      ],
    );
    if (picked != null) st.setLabelColor(picked);
  }

  /// 设计 / 竣工模式切换（对齐移动端模式行，竣工用橙色警示）。
  Widget _modeBtn(BuildContext context) {
    final completion = st.editModeName == 'completion';
    final color = completion ? TokC.warn : kAccent;
    return Tooltip(
      message: completion
          ? '当前：竣工模式（落点会弹竣工距离确认）— 点击切回设计模式'
          : '当前：设计模式 — 点击切到竣工模式',
      child: InkWell(
        onTap: () => st.chooseEditMode(completion ? 'design' : 'completion'),
        child: SizedBox(
          width: 62,
          height: barHeight,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(TokR.m),
                border: Border.all(color: color.withValues(alpha: 0.7)),
              ),
              child: Text(completion ? '竣工' : '设计',
                  style: TextStyle(color: color, fontSize: TokFs.small)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _measureBtn(BuildContext context) {
    final active =
        st.mode == AppMode.measureDist || st.mode == AppMode.measureArea;
    return PopupMenuButton<String>(
      tooltip: '测距 / 测面积',
      color: kPanelBg,
      position: PopupMenuPosition.under,
      onSelected: (v) {
        st.setMode(v == 'area' ? AppMode.measureArea : AppMode.measureDist);
      },
      itemBuilder: (ctx) => const [
        PopupMenuItem(
            value: 'dist',
            child: Text('测距', style: TextStyle(color: kTextMain))),
        PopupMenuItem(
            value: 'area',
            child: Text('测面积', style: TextStyle(color: kTextMain))),
      ],
      child: SizedBox(
        width: 40,
        height: barHeight,
        child: Center(
          child: Icon(Icons.straighten,
              size: 20, color: active ? kAccent : kTextMain),
        ),
      ),
    );
  }

  Widget _syncBtn(BuildContext context) {
    // 状态取自可空快照（无 `?? throw` getter）；未接入同步时显示「仅本地」灰点。
    final status = sync?.aggregateStatus ?? SyncStatus.localOnly;
    final dot = Color(status.argb);
    final pending = sync?.pendingCount ?? 0;
    final tip = '云同步 · ${status.label}'
        '${pending > 0 ? ' · 待上传 $pending' : ''}';
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onSync,
        child: SizedBox(
          width: 40,
          height: barHeight,
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Icon(Icons.sync, size: 20, color: kTextMain),
                Positioned(
                  right: 6,
                  bottom: 10,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _btn(IconData icon,
      {required String tooltip,
      required VoidCallback onTap,
      bool active = false,
      bool enabled = true}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 40,
          height: barHeight,
          child: Center(
            child: Icon(icon,
                size: 20,
                color: !enabled
                    ? TokC.divider
                    : active
                        ? kAccent
                        : kTextMain),
          ),
        ),
      ),
    );
  }

  Widget _sep() => Container(
      width: 1,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: TokC.divider);
}
