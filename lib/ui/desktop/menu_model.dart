import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/app_state.dart';
import '../batch_edit.dart';
import '../dialogs.dart';
import '../export_center.dart';
import '../route_tools.dart';
import 'symbol_library.dart';

/// 桌面菜单的**单一真源**（菜单分组 + 快捷键 + 分发器）。
///
/// ## 为什么要有这个文件
///
/// 桌面壳原本把菜单写死在 `app_menu_bar.dart` 里（`PopupMenuButton` + 一个
/// 大 `switch`）。引入 macOS **原生菜单**（`PlatformMenuBar`）后，如果两处各写
/// 一份，必然出现「macOS 有、Windows 没有」的功能漂移 —— 这正是本项目此前
/// 踩过的坑（桌面壳缺符号库/模式切换，见 `docs/DESKTOP-UI.md`）。
/// 因此把「有哪些菜单项、点了干什么」抽到这里，两端只负责**渲染方式**：
///
/// | 平台 | 渲染器 | 落点 |
/// |---|---|---|
/// | macOS | `app_platform_menu_bar.dart` | 屏幕顶部系统菜单栏（原生、悬停展开、⌘ 原生） |
/// | Windows / Linux | `app_menu_bar.dart` | 窗口内自绘菜单栏（`Overlay` 悬停展开） |
///
/// ## 快捷键的“谁先吃到按键”
///
/// macOS 上 `NSMenu` 的 key equivalent **优先于**窗口内容处理按键事件
/// （`NSApplication.sendEvent:` 先走主菜单的 `performKeyEquivalent:`），
/// 所以原生菜单声明了快捷键后，事件不会再到 Flutter 的 `Shortcuts` 层 ——
/// 不会出现「同一次按键把动作触发两遍」。但**裸键**（如 `Delete`）绝不能
/// 声明为菜单快捷键：那会把按键从文本框里抢走（左栏搜索框里按 Delete 删不掉字）。
/// 需要裸键的动作（删除选中）在 `shortcuts.dart` 里按「非文本编辑态」条件注册。
class OviMenuItemDef {
  const OviMenuItemDef(
    this.id,
    this.label, {
    this.keys,
    this.activator,
    this.dividerBefore = false,
  });

  /// 分发用稳定 id（与 [dispatchOviMenuItem] 的 `switch` 一一对应）。
  final String id;

  /// 纯菜单文案（原生菜单直接用这个，不带快捷键提示）。
  final String label;

  /// 快捷键提示文案（应用内自绘菜单在右侧显示，如 `Ctrl+Z`）。
  final String? keys;

  /// macOS 原生菜单的快捷键。`null` 表示该动作不声明原生快捷键。
  final SingleActivator? activator;

  /// 本项之前是否画一条分隔线。
  final bool dividerBefore;
}

/// 一个顶层菜单（对应菜单栏上的一个可点标题）。
class OviMenuGroupDef {
  const OviMenuGroupDef(this.label, this.items);

  final String label;
  final List<OviMenuItemDef> items;
}

/// 顶层菜单分组定义。两端渲染器共用，顺序即菜单栏顺序。
const List<OviMenuGroupDef> oviMenuGroups = <OviMenuGroupDef>[
  OviMenuGroupDef('文件', <OviMenuItemDef>[
    OviMenuItemDef('new_project', '新建工程',
        keys: 'Ctrl+N', activator: SingleActivator(LogicalKeyboardKey.keyN, meta: true)),
    OviMenuItemDef('open_project', '打开工程文件(.ovimap)',
        keys: 'Ctrl+O', activator: SingleActivator(LogicalKeyboardKey.keyO, meta: true)),
    OviMenuItemDef('save', '保存收藏',
        keys: 'Ctrl+S', activator: SingleActivator(LogicalKeyboardKey.keyS, meta: true)),
    OviMenuItemDef('export_project', '导出工程文件(.ovimap)',
        keys: 'Shift+Ctrl+S',
        activator: SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true)),
    OviMenuItemDef('export', '导出成果',
        dividerBefore: true,
        keys: 'Ctrl+E',
        activator: SingleActivator(LogicalKeyboardKey.keyE, meta: true)),
    OviMenuItemDef('archive', '竣工资料一键成册'),
    OviMenuItemDef('import_kml', '导入 KML 到当前项目'),
  ]),
  OviMenuGroupDef('编辑', <OviMenuItemDef>[
    OviMenuItemDef('undo', '撤销',
        keys: 'Ctrl+Z', activator: SingleActivator(LogicalKeyboardKey.keyZ, meta: true)),
    OviMenuItemDef('redo', '重做',
        keys: 'Ctrl+Y',
        activator: SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true)),
    // 裸键不声明为菜单快捷键（会把 Delete 从文本框抢走），仅作提示。
    OviMenuItemDef('delete_sel', '删除选中', dividerBefore: true, keys: 'Delete'),
    OviMenuItemDef('batch_edit', '批量编辑…'),
    OviMenuItemDef('clear_draft', '清空草稿'),
    OviMenuItemDef('focus_search', '聚焦左栏搜索',
        dividerBefore: true,
        keys: 'Ctrl+F',
        activator: SingleActivator(LogicalKeyboardKey.keyF, meta: true)),
  ]),
  OviMenuGroupDef('工程', <OviMenuItemDef>[
    OviMenuItemDef('collection_settings', '采集设置（自动编号 / 段标前缀）'),
    OviMenuItemDef('template', '工程模板'),
    OviMenuItemDef('pole_table', '杆路点表'),
    OviMenuItemDef('track_check', '杆路轨迹核查'),
    // 出图体检放在"导出成果"之前的心智位置：先体检、再出图。
    // 快捷键 Alt+Ctrl+K（Check），与 Alt+Ctrl+L/R/M 同族，不与文本框裸键冲突。
    OviMenuItemDef('inspect', '出图体检（出图前查错）',
        dividerBefore: true,
        keys: 'Alt+Ctrl+K',
        activator:
            SingleActivator(LogicalKeyboardKey.keyK, meta: true, alt: true)),
    OviMenuItemDef('auto_seg_label', '按敷设方式生成段标（固化）'),
    OviMenuItemDef('topo_guide', '拓扑连线指引', dividerBefore: true),
    OviMenuItemDef('symbol_lib', '符号库…'),
  ]),
  OviMenuGroupDef('视图', <OviMenuItemDef>[
    OviMenuItemDef('toggle_left', '折叠 / 展开左栏',
        keys: 'Alt+Ctrl+L',
        activator: SingleActivator(LogicalKeyboardKey.keyL, meta: true, alt: true)),
    OviMenuItemDef('toggle_right', '折叠 / 展开右栏',
        keys: 'Alt+Ctrl+R',
        activator: SingleActivator(LogicalKeyboardKey.keyR, meta: true, alt: true)),
    OviMenuItemDef('focus_map', '专注地图（两侧全收）',
        dividerBefore: true,
        keys: 'Alt+Ctrl+M',
        activator: SingleActivator(LogicalKeyboardKey.keyM, meta: true, alt: true)),
    OviMenuItemDef('design_mode', '切到设计模式', dividerBefore: true),
    OviMenuItemDef('completion_mode', '切到竣工模式'),
    OviMenuItemDef('zoom_in', '放大', dividerBefore: true, keys: 'Ctrl+=',
        activator: SingleActivator(LogicalKeyboardKey.equal, meta: true)),
    OviMenuItemDef('zoom_out', '缩小', keys: 'Ctrl+-',
        activator: SingleActivator(LogicalKeyboardKey.minus, meta: true)),
    OviMenuItemDef('reset_view', '复位到启动视图', keys: 'Ctrl+0',
        activator: SingleActivator(LogicalKeyboardKey.digit0, meta: true)),
  ]),
  OviMenuGroupDef('底图', <OviMenuItemDef>[
    OviMenuItemDef('source', '图源 / 图层'),
    OviMenuItemDef('coord_fmt', '坐标格式（切换）'),
    OviMenuItemDef('offline', '离线地图（预下载）'),
    OviMenuItemDef('tianditu_key', '天地图 Key 设置', dividerBefore: true),
    OviMenuItemDef('amap_key', '高德 Key 设置'),
    OviMenuItemDef('overpass', 'Overpass 端点', dividerBefore: true),
    OviMenuItemDef('storage_cleanup', '存储清理'),
  ]),
  OviMenuGroupDef('同步', <OviMenuItemDef>[
    OviMenuItemDef('sync_panel', '云同步面板（立即同步 / 设置）'),
  ]),
  OviMenuGroupDef('帮助', <OviMenuItemDef>[
    OviMenuItemDef('datum_help', '坐标系说明'),
    OviMenuItemDef('about', '关于 滑洲云图'),
  ]),
];

/// 菜单动作的调度回调集合。
///
/// 这些回调全部由壳（`WorkspacePage`）提供 —— 菜单只负责「翻译成一次点击」，
/// 业务逻辑仍归壳，避免菜单层反向持有地图/相机控制权。
class OviMenuActions {
  const OviMenuActions({
    required this.onNewProject,
    required this.onOpenProject,
    required this.onExportProject,
    required this.onSave,
    required this.onExport,
    required this.onUndo,
    required this.onRedo,
    required this.onDeleteSelection,
    required this.onPoleTable,
    required this.onTrackCheck,
    required this.onInspect,
    required this.onOffline,
    required this.onStorageCleanup,
    required this.onSync,
    required this.onToggleLeft,
    required this.onToggleRight,
    required this.onFocusMap,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onResetView,
    required this.onFocusSearch,
  });

  final VoidCallback onNewProject;
  final VoidCallback onOpenProject;
  final VoidCallback onExportProject;
  final VoidCallback onSave;
  final VoidCallback onExport;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onDeleteSelection;
  final VoidCallback onPoleTable;
  final VoidCallback onTrackCheck;

  /// 出图体检：由壳注入，因为"定位到某一档"需要地图相机控制权（菜单层不持相机）。
  final VoidCallback onInspect;
  final VoidCallback onOffline;
  final VoidCallback onStorageCleanup;
  final VoidCallback onSync;
  final VoidCallback onToggleLeft;
  final VoidCallback onToggleRight;
  final VoidCallback onFocusMap;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onResetView;
  final VoidCallback onFocusSearch;
}

/// 执行一个菜单项。两端渲染器共用的唯一分发点。
///
/// 需要 `context` 的项（弹对话框）在这里直接调既有对话框函数，
/// 不重复实现业务逻辑 —— 与改造前的行为逐项等价。
Future<void> dispatchOviMenuItem(
  BuildContext context,
  AppState st,
  String id,
  OviMenuActions a,
) async {
  switch (id) {
    // ---- 文件 ----
    case 'new_project':
      a.onNewProject();
      break;
    case 'open_project':
      a.onOpenProject();
      break;
    case 'export_project':
      a.onExportProject();
      break;
    case 'save':
      a.onSave();
      break;
    case 'export':
      a.onExport();
      break;
    case 'archive':
      await showArchiveBookDialog(context, st);
      break;
    case 'import_kml':
      await showKmlImportDialog(context, st);
      break;

    // ---- 编辑 ----
    case 'undo':
      a.onUndo();
      break;
    case 'redo':
      a.onRedo();
      break;
    case 'delete_sel':
      a.onDeleteSelection();
      break;
    case 'batch_edit':
      if (st.selectedIds.isEmpty) {
        toast(context, '请先框选或在线组里选中点');
      } else {
        await showBatchEditDialog(context, st);
      }
      break;
    case 'clear_draft':
      await _confirmClearDraft(context, st);
      break;
    case 'focus_search':
      a.onFocusSearch();
      break;

    // ---- 工程 ----
    case 'collection_settings':
      await showCollectionSettings(context, st);
      break;
    case 'template':
      await showTemplateDialog(context, st);
      break;
    case 'pole_table':
      a.onPoleTable();
      break;
    case 'track_check':
      a.onTrackCheck();
      break;
    case 'inspect':
      a.onInspect();
      break;
    case 'auto_seg_label':
      await _autoSegLabels(context, st);
      break;
    case 'topo_guide':
      await showTopoGuide(context);
      break;
    case 'symbol_lib':
      await showSymbolLibrary(context, st);
      break;

    // ---- 视图 ----
    case 'toggle_left':
      a.onToggleLeft();
      break;
    case 'toggle_right':
      a.onToggleRight();
      break;
    case 'focus_map':
      a.onFocusMap();
      break;
    case 'design_mode':
      st.chooseEditMode('design');
      break;
    case 'completion_mode':
      st.chooseEditMode('completion');
      break;
    case 'zoom_in':
      a.onZoomIn();
      break;
    case 'zoom_out':
      a.onZoomOut();
      break;
    case 'reset_view':
      a.onResetView();
      break;

    // ---- 底图 ----
    case 'source':
      await showSourceDialog(context, st);
      break;
    case 'coord_fmt':
      st.setCoordFmt(st.coordFmt + 1);
      if (context.mounted) toast(context, '坐标格式已切换（下次重开沿用）');
      break;
    case 'offline':
      a.onOffline();
      break;
    case 'tianditu_key':
      await showTiandituKeyDialog(context, st);
      break;
    case 'amap_key':
      await showAmapKeyDialog(context, st);
      break;
    case 'overpass':
      await showOverpassEndpointsDialog(context, st);
      break;
    case 'storage_cleanup':
      a.onStorageCleanup();
      break;

    // ---- 同步 ----
    case 'sync_panel':
      a.onSync();
      break;

    // ---- 帮助 ----
    case 'datum_help':
      await showDatumHelp(context, st);
      break;
    case 'about':
      await showAbout(context);
      break;
  }
}

/// 批量生成段标（**固化**）。必须先讲清代价再动手 —— 这个动作会把"前缀+距离"
/// 写成静态文字，之后挪点不再自动跟随，属于"为纸质图纸写死数字"的手段，
/// 不是日常省事的办法（日常请用批量设置敷设方式，让段标实时带前缀）。
Future<void> _autoSegLabels(BuildContext context, AppState st) async {
  final segs = st.segments;
  if (segs.isEmpty) {
    toast(context, '当前工程还没有连线段落（至少两个同线组的点）');
    return;
  }
  final blank = segs.where((s) => s.to.distLabel.trim().isEmpty).length;
  var overwrite = false;

  await showDarkDialog(
    context,
    title: '按敷设方式生成段标（固化）',
    width: 460,
    content: StatefulBuilder(
      builder: (ctx, setSt) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '全线共 ${segs.length} 段，其中 $blank 段还没有标注。\n'
            '生成后的文字形如「架38」「埋42.5」——前缀取自每段的敷设方式，'
            '距离取实测段距。',
            style: const TextStyle(
                color: kTextMain, fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: kWarn.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kWarn.withValues(alpha: 0.5), width: 0.5),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, size: 15, color: kWarn),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '固化后段距变化不会再自动跟随：日后挪动一个点，图上仍标着旧数字。'
                    '想省事又不出错，请改用「编辑 → 批量编辑 → 敷设方式」，'
                    '让段标由敷设方式自动带前缀。',
                    style: TextStyle(
                        color: kTextSub, fontSize: 11.5, height: 1.55),
                  ),
                ),
              ],
            ),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('覆盖已有标注（连手填的也重写）',
                style: TextStyle(color: kTextMain, fontSize: 13)),
            value: overwrite,
            activeColor: kAccent,
            onChanged: (v) => setSt(() => overwrite = v ?? false),
          ),
          if (blank == 0 && !overwrite)
            const Text('当前没有空白段可填；如需重写请勾选上面的选项。',
                style: TextStyle(color: kTextHint, fontSize: 11.5)),
        ],
      ),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn(overwrite ? '覆盖生成' : '只填空白段', () {
        Navigator.pop(context);
        final n = st.autoFillSegLabels(overwrite: overwrite);
        toast(context,
            n > 0 ? '已固化 $n 段标注（Ctrl+Z 可整批撤销）' : '没有需要处理的段');
      }),
    ],
  );
}

Future<void> _confirmClearDraft(BuildContext context, AppState st) async {
  if (st.labels.isEmpty) {
    toast(context, '草稿为空');
    return;
  }
  // 打开收藏编辑时，草稿即收藏内容——清空会同步写回收藏文件，文案必须如实。
  final editing = st.activeCollectionId.isNotEmpty;
  await showDarkDialog(context,
      title: editing ? '清空收藏内容' : '清空草稿',
      content: Text(
          editing
              ? '「${st.projectName}」的 ${st.labels.length} 个点将被清空，'
                  '并同步写回收藏（误清可 Ctrl+Z 撤销）。'
              : '确定删除当前 ${st.labels.length} 个未保存的点？',
          style: const TextStyle(color: kTextMain, fontSize: 13)),
      actions: [
        darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
        darkTextBtn('清空', () {
          st.clearDraft();
          Navigator.pop(context);
        }, color: kDanger),
      ]);
}
