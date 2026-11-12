import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../geo/geo_util.dart';
import '../../models/map_label.dart';
import '../../services/export_saver.dart';
import '../../services/file_drop.dart';
import '../../services/photos.dart';
import '../../services/platform_caps.dart';
import '../../services/tile_cache.dart';
import '../../services/track_check.dart';
import '../../state/app_state.dart';
import '../../sync/sync_controller.dart';
import '../design_tokens.dart';
import '../dialogs.dart';
import '../export_center.dart';
import '../map/map_canvas.dart';
import '../sync/sync_panel.dart';
import 'app_menu_bar.dart';
import 'app_platform_menu_bar.dart';
import 'context_menu.dart';
import 'inspect_dialog.dart';
import 'left_panel.dart';
import 'menu_model.dart';
import 'right_panel.dart';
import 'shortcuts.dart';
import 'status_bar.dart';
import 'toolbar.dart';

/// 桌面外壳（Windows）：菜单栏 + 工具栏 + 三栏（左栏 / 地图 / 右栏）+ 状态栏 +
/// 快捷键（架构文档 §3.1 / §3.2 / T08）。
///
/// 地图渲染与交互复用共享核心 [MapCanvas]（`openDetailOnTap=false`，点选结果经
/// [MapCanvas.onSelect] 交给右栏展示）；本壳只承载桌面 Chrome 与桌面态。
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key});

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  final MapController _mc = MapController();
  final FocusNode _searchFocus = FocusNode();

  CacheTileProvider? _baseProvider;
  CacheTileProvider? _overlayProvider;
  String? _baseProviderFor;
  String? _overlayProviderFor;

  bool _mapReady = false;
  MapCamera? _cam;

  /// 鼠标所在经纬度（WGS-84），供状态栏显示（奥维桌面版的状态栏口径）。
  ///
  /// 用 [ValueNotifier] 而非 `setState`：悬停回调每秒触发几十次，
  /// 走 setState 会连地图一起重建，直接拖累滚轮缩放与平移的手感。
  /// 交给 [StatusBar] 内部局部监听，只有那一个文本节点重建。
  final ValueNotifier<LatLng?> _mouseGeo = ValueNotifier<LatLng?>(null);

  /// 最近一次写入状态栏的鼠标坐标文本（变化去重用，见 [_onMouseGeo]）。
  String _lastMouseText = '';

  // ---- 布局（v3.4.0 重排） ----
  //
  // 用户反馈：「右侧栏很鸡肋」「左侧栏可以做个图标，名字为收藏夹，点击打开
  // 就是收藏夹」。口径：
  //   · 左栏不再常驻，换成一条 52px 的**图标轨道**；点「收藏夹」图标时以
  //     **悬浮面板**叠加在地图上（不挤压地图宽度），再点或 Esc 收起；
  //   · 右栏保持默认收起，且选中点**不再自动展开**——要看属性时从工具栏手动开；
  //   · 默认视口 1440 下地图占 (1440-52-0)/1440 ≈ 96%。
  double _leftW = 300;
  double _rightW = 280;
  bool _rightCollapsed = true;

  /// 收藏夹面板开关。**默认打开**（奥维桌面版收藏夹常驻停靠，用户截图定版）；
  /// 收起后只留 52px 图标轨道，点「收藏夹」再展开。
  bool _favOpen = true;

  /// 「专注地图」进入前的面板状态（再按一次还原，而不是盲目全展开）。
  bool _prevLeftOpen = true;
  bool _prevRightOpen = false;

  // ---- 选中（右栏展示） ----
  MapLabel? _selLabel;
  String _selCid = '';

  @override
  void initState() {
    super.initState();
    // T21：注册 Windows 资源管理器文件拖放（WM_DROPFILES → MethodChannel）。
    // 非 Windows 平台该通道永不触发，注册无副作用。
    FileDrop.register(_onFilesDropped);
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    _mouseGeo.dispose();
    super.dispose();
  }

  // ================= 外部文件（拖入 / 打开）T21·T22 =================

  void _onFilesDropped(List<String> paths) {
    unawaited(_handleExternalFiles(paths));
  }

  Future<void> _handleExternalFiles(List<String> paths) async {
    final st = _st;
    final msg = await st.openExternalFiles(paths);
    if (!mounted) return;
    toast(context, msg);
  }

  /// 「打开工程文件」（文件菜单 / Ctrl+O）：选 `.ovimap` → 导入并打开。
  Future<void> _openProjectFile() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['ovimap'],
        withData: false,
      );
    } catch (e) {
      if (mounted) toast(context, '打开文件选择器失败：$e');
      return;
    }
    if (picked == null || picked.files.isEmpty) return; // 用户取消：静默
    final p = picked.files.first.path;
    if (p == null || p.isEmpty) {
      if (mounted) toast(context, '无法获取所选文件的内容');
      return;
    }
    final msg = await _st.openExternalFiles(<String>[p]);
    if (mounted) toast(context, msg);
  }

  /// 「导出工程文件 (.ovimap)」（文件菜单）：把当前打开的工程另存为 `.ovimap`。
  Future<void> _exportProjectFile() async {
    final st = _st;
    final cid = st.activeCollectionId;
    if (cid.isEmpty) {
      toast(context, '请先打开一个已保存的工程，再导出工程文件');
      return;
    }
    final f = await st.buildProjectFile(cid);
    if (!mounted) return;
    if (f == null) {
      toast(context, '导出工程文件失败：找不到该工程的原始文件');
      return;
    }
    await ExportSaver.saveOrShare(context, f,
        suggestedName: f.uri.pathSegments.last);
  }

  // ================= 回调 =================

  AppState get _st => context.read<AppState>();

  void _newProject() {
    final st = _st;
    // startNewDraft 内部先脱离收藏再清草稿——顺序反了会把空列表写回收藏文件。
    st.startNewDraft();
    st.setMode(AppMode.edit);
    setState(() {
      _selLabel = null;
      _selCid = '';
    });
    st.refreshUi();
    toast(context, '已新建空白工程：直接在地图上打点，Ctrl+S 保存到收藏夹根目录');
  }

  void _save() => showFinishDialog(context, _st);

  void _undo() {
    _st.undoDraft();
    setState(() {
      _selLabel = null;
      _selCid = '';
    });
  }

  void _redo() {
    _st.redo();
    setState(() {
      _selLabel = null;
      _selCid = '';
    });
  }

  void _deleteSelection() {
    final st = _st;
    if (st.selectedIds.isEmpty) {
      toast(context, '未选中点（可框选或在线组里选中）');
      return;
    }
    final n = st.deleteSelected();
    setState(() => _selLabel = null);
    toast(context, '已删除 $n 个点（Ctrl+Z 可撤销）');
  }

  void _export() => openExportCenter(context, _st);

  void _focusSearch() => _searchFocus.requestFocus();

  Future<void> _topo() async {
    final st = _st;
    if (st.mode == AppMode.topoLink) {
      st.endTopoLink();
      return;
    }
    for (final m in st.collections) {
      final ok = await st.startTopoLink(m);
      if (!mounted) return;
      if (ok) {
        toast(context, '拓扑连线：点起点箱体 → 点终点箱体');
        return;
      }
    }
    toast(context, '没有含可连线箱体（光交/分纤盒/分光器箱/ONU/机房/基站/引上）的收藏工程');
  }

  void _track() {
    final st = _st;
    if (st.recording) {
      st.toggleRecordPause();
      return;
    }
    toast(context, '桌面端无 GPS 定位，不支持轨迹记录；请在移动端沿线走查录制');
  }

  void _locateMe() {
    final st = _st;
    if (!st.hasFix || st.curLat == null || st.curLon == null) {
      toast(context, '桌面端无 GPS 定位；可右键「粘贴坐标点」或搜索定位到目标');
      return;
    }
    final d = st.toDisplay(st.curLat!, st.curLon!);
    _mc.moveAndRotate(LatLng(d[0], d[1]),
        _mc.camera.zoom < 16 ? 17.5 : _mc.camera.zoom, _mc.camera.rotation);
    st.setFollow(true);
    toast(context, '已定位到当前位置');
  }

  void _zoomIn() {
    if (!_mapReady) return;
    final c = _mc.camera;
    _mc.moveAndRotate(c.center, c.zoom + 1, c.rotation);
  }

  void _zoomOut() {
    if (!_mapReady) return;
    final c = _mc.camera;
    _mc.moveAndRotate(c.center, c.zoom - 1, c.rotation);
  }

  /// Ctrl+0 / `0`：复位到**启动视图**（上次退出时的中心与级别）。
  ///
  /// 用启动视图而不是「草稿包络」：用户按复位时想要的是一个可预期的落点，
  /// 而不是随草稿增长而变化的结果；草稿定位请用左栏「点表」或搜索。
  void _resetView() {
    if (!_mapReady) return;
    final st = _st;
    final d = st.toDisplay(st.initLat, st.initLon);
    st.setFollow(false);
    _mc.moveAndRotate(LatLng(d[0], d[1]), st.initZoom, 0);
    toast(context, '已复位到启动视图（缩放 ${st.initZoom.toStringAsFixed(1)}）');
  }

  /// 视图 → 专注地图（⌥⌘M）：一键收掉收藏夹面板与右栏把地图铺满；
  /// 再按一次**还原**右栏到进入前的状态（收藏夹面板不自动弹回，需要时再点图标）。
  void _focusMap() {
    setState(() {
      final anyOpen = _favOpen || !_rightCollapsed;
      if (anyOpen) {
        _prevLeftOpen = _favOpen;
        _prevRightOpen = !_rightCollapsed;
        _favOpen = false;
        _rightCollapsed = true;
      } else {
        _favOpen = _prevLeftOpen;
        _rightCollapsed = !_prevRightOpen;
      }
    });
  }

  /// 鼠标悬停经纬度：转成显示基准的文本交给状态栏（奥维桌面版状态栏口径）。
  ///
  /// 只在「格式化后的文本真的变了」时更新 [ValueNotifier]：悬停事件按像素触发，
  /// 不设闸门会让状态栏每帧重建一次。
  void _onMouseGeo(double? lat, double? lon) {
    if (lat == null || lon == null) {
      _lastMouseText = '';
      if (_mouseGeo.value != null) _mouseGeo.value = null;
      return;
    }
    final st = _st;
    final d = st.toDisplay(lat, lon);
    final s = GeoUtil.formatCoord(d[0], d[1], st.coordFmt);
    if (s == _lastMouseText) return;
    _lastMouseText = s;
    _mouseGeo.value = LatLng(lat, lon);
  }

  /// Esc：取消当前操作（奥维桌面版 `Esc` 语义）。
  ///
  /// 优先级从「最临时」到「最正式」：待定点位编辑 → 框选 → 测量/连线 → 视图。
  /// **普通/采集模式不清空草稿** —— 误触 Esc 丢掉几十个点是不可接受的，
  /// 清空草稿有专门入口（右键菜单 / 左栏）。
  void _escape() {
    final st = _st;
    // Esc 第一优先：收起收藏夹悬浮面板（临时 UI 最先退场）。
    if (_favOpen) {
      setState(() => _favOpen = false);
      return;
    }
    if (st.draggingLabelId != null) {
      st.cancelPendingEdit();
      toast(context, '已取消「待点地图放置」');
      return;
    }
    if (st.selectedIds.isNotEmpty) {
      st.clearSelection();
      toast(context, '已清空选择（${st.selectedIds.length} 个点）');
      return;
    }
    switch (st.mode) {
      case AppMode.boxSelect:
        st.setMode(AppMode.view);
        toast(context, '已退出框选');
      case AppMode.measureDist:
      case AppMode.measureArea:
        final n = st.measurePts.length;
        st.setMode(AppMode.view);
        toast(context, n >= 2 ? '已结束测量（未保存，如需留档请先用「保存」）' : '已退出测量');
      case AppMode.topoLink:
        st.endTopoLink();
        toast(context, '已结束拓扑连线');
      case AppMode.edit:
      case AppMode.view:
        toast(context, '当前没有可取消的操作（Esc 可退出测量/连线/框选、取消待定点位）');
    }
  }

  /// Backspace：退掉最后一个点 / 最后一条连线（奥维桌面版的退点键）。
  void _undoPoint() {
    final st = _st;
    switch (st.mode) {
      case AppMode.measureDist:
      case AppMode.measureArea:
        if (st.measurePts.isEmpty) {
          toast(context, '没有可退的测量点');
          return;
        }
        st.undoMeasure();
        toast(context, '已退掉 1 个测量点（剩 ${st.measurePts.length} 个）');
      case AppMode.topoLink:
        if (st.topoUndoStack.isEmpty) {
          toast(context, '没有可退的连线');
          return;
        }
        st.undoTopoLink();
        toast(context, '已退掉最后一条拓扑连线');
      case AppMode.edit:
        if (st.labels.isEmpty) {
          toast(context, '草稿里没有点');
          return;
        }
        final n = st.labels.length;
        _undo();
        toast(context, '已退掉最后 1 个点（$n → ${st.labels.length}）');
      case AppMode.boxSelect:
      case AppMode.view:
        toast(context, '普通/框选模式没有点位可退（采集、测距、连线模式可用）');
    }
  }

  Future<void> _onOffline() async {
    final st = _st;
    await showOfflineDialog(context, st, _mc, _baseProvider!);
  }

  /// 存储清理：清图源缓存 + 清未引用照片（与移动端同一口径）。
  Future<void> _storageCleanup() async {
    final st = _st;
    final n = await _baseProvider?.clearDiskCache() ?? 0;
    _baseProviderFor = null; // 强制重建 provider
    if (mounted) setState(() {});
    final refs = <String>{};
    void eat(List<MapLabel> ls) {
      for (final e in ls) {
        refs.addAll(e.photoPaths);
      }
    }

    eat(st.labels);
    for (final m in st.collections) {
      eat(await st.store.loadCollection(m.id));
    }
    final p = await PhotoService.purgeOrphans([refs]);
    if (!mounted) return;
    toast(context,
        '存储清理完成：图源缓存${n > 0 ? '已清' : '无'} · 未引用照片${p > 0 ? '已清 $p 个' : '无'}');
  }

  void _showSyncInfo() {
    // 打开同步面板（T17）。sync 以可空方式取得，未接入时面板退化为「本地模式」。
    showSyncPanel(context, context.read<SyncController?>(), _st);
  }

  // ---- 工具：杆路点表 / 轨迹核查（桌面精简版，复用共享逻辑） ----

  /// 出图体检（Alt+Ctrl+K）。
  ///
  /// 「定位」回调用到了地图相机 —— 这正是体检结果必须由**壳**来打开的原因：
  /// 引擎（route_check）与面板（inspect_dialog）都不持有 `MapController`，
  /// 保持"纯逻辑 / 纯呈现 / 相机归壳"的分层。
  Future<void> _inspect() async {
    final st = _st;
    if (st.labels.isEmpty) {
      toast(context, '当前项目没有点，无需体检');
      return;
    }
    await showRouteInspectDialog(
      context,
      st,
      onLocate: _locateLabels,
    );
  }

  /// 把体检报出的点选中并把地图移过去。
  ///
  /// 取所有相关点的重心作为落点（段级问题给的是两个端点，看重心才能同时看到两端），
  /// 并把缩放抬到 18 以上 —— 出图体检关心的是"这一档"，级别太低看不见细节。
  void _locateLabels(List<String> ids) {
    final hits = labelsByIds(_st, ids);
    if (hits.isEmpty) return;
    _st.selectedIds
      ..clear()
      ..addAll(ids);
    var lat = 0.0, lon = 0.0;
    for (final l in hits) {
      lat += l.lat;
      lon += l.lon;
    }
    lat /= hits.length;
    lon /= hits.length;
    final d = _st.toDisplay(lat, lon);
    if (_mapReady) {
      _mc.move(LatLng(d[0], d[1]),
          _mc.camera.zoom < 18 ? 18.0 : _mc.camera.zoom);
    }
    setState(() {
      _selLabel = hits.first;
      _selCid = ''; // 体检针对草稿点；收藏点不在这里编辑
      _rightCollapsed = false; // 让属性面板出来，用户可立刻改
    });
    toast(context, '已定位到选中点（${hits.length} 个），可直接在右栏修改');
  }

  Future<void> _showPoleTable() async {
    final st = _st;
    if (st.labels.isEmpty) {
      toast(context, '当前项目没有点');
      return;
    }
    final chains = buildLabelChains(st.labels);
    await showDarkDialog(
      context,
      title: '杆路点表',
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: chains.isEmpty
            ? const Center(
                child: Text('没有参与连线的点（箱体请从地图上直接点选）',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kTextSub, fontSize: TokFs.body)))
            : ListView(
                children: [
                  for (var ci = 0; ci < chains.length; ci++) ...[
                    Builder(builder: (ctx) {
                      var len = 0.0;
                      for (var i = 1; i < chains[ci].length; i++) {
                        final p = chains[ci][i];
                        len += p.distanceM ??
                            GeoUtil.haversine(chains[ci][i - 1].lat,
                                chains[ci][i - 1].lon, p.lat, p.lon);
                      }
                      return Container(
                        color: TokC.field,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        child: Text(
                            '链 ${ci + 1} · ${chains[ci].length} 点 · 全长 ${_fmtChainLen(len)}',
                            style: const TextStyle(
                                color: kAccent, fontSize: TokFs.body)),
                      );
                    }),
                    for (final l in chains[ci])
                      ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 11,
                          backgroundColor: l.type.color,
                          child: Text(
                              l.name.trim().isNotEmpty
                                  ? l.name.trim().substring(0, 1)
                                  : (l.type.symbol.isEmpty
                                      ? l.type.name.substring(0, 1)
                                      : l.type.symbol),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: TokFs.caption)),
                        ),
                        title: Text(
                            l.name.trim().isNotEmpty ? l.name.trim() : l.type.name,
                            style: const TextStyle(
                                color: kTextMain, fontSize: TokFs.title)),
                        subtitle: Text(_poleSub(l, chains[ci]),
                            style: const TextStyle(
                                color: kTextSub, fontSize: TokFs.caption)),
                        onTap: () {
                          Navigator.pop(context);
                          final d = st.toDisplay(l.lat, l.lon);
                          _mc.move(LatLng(d[0], d[1]), _mc.camera.zoom);
                          setState(() {
                            _selLabel = l;
                            _selCid = '';
                          });
                        },
                      ),
                  ],
                ],
              ),
      ),
      actions: [
        darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
      ],
    );
  }

  String _poleSub(MapLabel l, List<MapLabel> chain) {
    final parts = <String>[];
    final i = chain.indexOf(l);
    if (i > 0) {
      final d = l.distanceM ??
          GeoUtil.haversine(chain[i - 1].lat, chain[i - 1].lon, l.lat, l.lon);
      parts.add('距上点 ${GeoUtil.fmtDist(d)}');
    }
    if (l.slackM > 0) {
      parts.add(
          '盘留${l.slackM == l.slackM.roundToDouble() ? l.slackM.toStringAsFixed(0) : l.slackM.toStringAsFixed(1)}m');
    }
    if (l.segCable.trim().isNotEmpty) parts.add(l.segCable.trim());
    if (l.photoPaths.isNotEmpty) parts.add('${l.photoPaths.length}图');
    return parts.isEmpty ? l.type.name : parts.join(' · ');
  }

  Future<void> _showTrackCheck() async {
    final st = _st;
    final tracks = st.collections.where((m) => m.kind == 'track').toList();
    if (tracks.isEmpty) {
      toast(context, '没有轨迹：先在线走查一遍并记录轨迹，再来核查');
      return;
    }
    final poles = [
      for (final chain in buildLabelChains(st.labels)) ...chain,
    ];
    if (poles.isEmpty) {
      toast(context, '当前项目没有杆路点，无法核查');
      return;
    }
    await showDarkDialog(
      context,
      title: '选择一条轨迹核查',
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final m in tracks)
              ListTile(
                dense: true,
                title: Text(m.name.isEmpty ? '未命名轨迹' : m.name,
                    style: const TextStyle(color: kTextMain, fontSize: TokFs.title)),
                subtitle: Text('${m.count} 点',
                    style: const TextStyle(color: kTextSub, fontSize: TokFs.caption)),
                onTap: () async {
                  Navigator.pop(context);
                  final trackPts = await st.store.loadCollection(m.id);
                  final r = TrackChecker.check(trackPts, poles);
                  if (!mounted) return;
                  _showTrackReport(m.name, r);
                },
              ),
          ],
        ),
      ),
      actions: [
        darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      ],
    );
  }

  void _showTrackReport(String trackName, TrackCheckResult r) {
    showDarkDialog(
      context,
      title: '轨迹核查报告',
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('轨迹：$trackName',
                style: const TextStyle(color: kTextSub, fontSize: TokFs.small)),
            const SizedBox(height: 6),
            Text(
                '杆数 ${r.poleCount} · 轨迹全长 ${_fmtChainLen(r.trackLen)}\n'
                '平均偏移 ${r.avgOffset.toStringAsFixed(0)} 米（阈值 ${r.threshold.toStringAsFixed(0)} 米）',
                style: const TextStyle(color: kTextMain, fontSize: TokFs.body)),
            const SizedBox(height: 10),
            Text(
                r.outliers.isEmpty
                    ? '✓ 全部杆位偏移在阈值内，没有漏杆/错位迹象'
                    : '⚠ ${r.outliers.length} 根杆偏移超阈值，按偏移从大到小：',
                style: TextStyle(
                    color: r.outliers.isEmpty
                        ? TokC.ok
                        : TokC.warn,
                    fontSize: TokFs.body)),
            for (final (pole, off) in r.outliers.take(10))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                    '· ${pole.name.trim().isNotEmpty ? pole.name.trim() : pole.type.name}：偏移 ${off.toStringAsFixed(0)} 米',
                    style: const TextStyle(
                        color: TokC.warn, fontSize: TokFs.body)),
              ),
          ],
        ),
      ),
      actions: [
        darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
      ],
    );
  }

  String _fmtChainLen(double m) => m < 1000
      ? '${m.toStringAsFixed(0)}m'
      : '${(m / 1000).toStringAsFixed(2)}km';

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    // 同步编排器以**可空**方式获取（未接入同步时返回 null，不抛异常）。
    final sync = context.watch<SyncController?>();
    if (!st.inited) {
      return const Scaffold(
        backgroundColor: TokC.panelSolid,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: kAccent),
              SizedBox(height: 14),
              Text('滑洲云图 启动中…',
                  style: TextStyle(color: kTextSub, fontSize: TokFs.body)),
            ],
          ),
        ),
      );
    }

    // 图源变化时重建 provider（与移动端一致）。
    if (_baseProviderFor != st.curSource.id || _baseProvider == null) {
      _baseProvider = CacheTileProvider(
          sourceId: st.curSource.id,
          urlTemplate: st.curSource.normalizedUrl);
      _baseProviderFor = st.curSource.id;
    }
    final ovl = st.currentOverlay();
    if (ovl != null && _overlayProviderFor != ovl.id) {
      _overlayProvider = CacheTileProvider(
          sourceId: ovl.id, urlTemplate: ovl.normalizedUrl);
      _overlayProviderFor = ovl.id;
    } else if (ovl == null) {
      _overlayProvider = null;
      _overlayProviderFor = null;
    }

    return DesktopShortcuts(
      onSave: _save,
      onUndo: _undo,
      onRedo: _redo,
      onDeleteSelection: _deleteSelection,
      onExport: _export,
      onFocusSearch: _focusSearch,
      onOpenProject: _openProjectFile,
      onZoomIn: _zoomIn,
      onZoomOut: _zoomOut,
      onResetView: _resetView,
      onEscape: _escape,
      onUndoPoint: _undoPoint,
      onToggleLeft: () => setState(() => _favOpen = !_favOpen),
      onToggleRight: () => setState(() => _rightCollapsed = !_rightCollapsed),
      onFocusMap: _focusMap,
      onInspect: _inspect,
      // macOS：把菜单交给**系统菜单栏**（`PlatformMenuBar`）。它不占窗口面积、
      // 悬停即展开、⌘ 快捷键由系统绘制，并且**整体接管主菜单** —— 屏幕顶部
      // 那排英文菜单（App / Edit / View / Window / Help）由这份中文菜单取代。
      // 非 macOS 时该组件原样透传 child（见 AppPlatformMenuBar.build）。
      child: AppPlatformMenuBar(
        st: st,
        actions: _menuActions,
        child: Scaffold(
          backgroundColor: TokC.panelSolid,
          body: Column(
            children: [
              // Windows / Linux 没有系统菜单栏，继续用窗口内自绘菜单栏。
              // macOS 下**不画这一行** —— 这就是「上面一排英文菜单、下面还有一排
              // 中文菜单」的修复点：macOS 只保留系统那一排（且已换成中文）。
              if (!PlatformCaps.isMacOS)
                AppMenuBar(st: st, actions: _menuActions),
              Toolbar(
                st: st,
                sync: sync,
                onZoomIn: _zoomIn,
                onZoomOut: _zoomOut,
                onTopo: _topo,
                onTrack: _track,
                onLocate: _locateMe,
                onSave: _save,
                onUndo: _undo,
                onRedo: _redo,
                onDeleteSelection: _deleteSelection,
                onExport: _export,
                onSync: _showSyncInfo,
                onInspect: _inspect,
                leftCollapsed: !_favOpen,
                rightCollapsed: _rightCollapsed,
                onToggleLeft: () =>
                    setState(() => _favOpen = !_favOpen),
                onToggleRight: () =>
                    setState(() => _rightCollapsed = !_rightCollapsed),
              ),
              Expanded(child: _body(st)),
              // 模式提示栏（奥维桌面版的「提示栏」位）：模式 / 可用操作 / 实时数据。
              _hintBar(st),
              StatusBar(
                st: st,
                sync: sync,
                centerText: _centerText(st),
                zoom: _cam?.zoom ?? st.initZoom,
                selectedCount: st.selectedIds.length,
                mouseGeo: _mouseGeo,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 菜单动作表 —— `menu_model.dart` 那份单一真源的入口。
  ///
  /// macOS 原生菜单与 Windows 自绘菜单**共用这一份**，不会出现
  /// 「macOS 有这一项、Windows 没有」的平台漂移（默认值/模式切换曾正是这样丢的）。
  OviMenuActions get _menuActions => OviMenuActions(
        onNewProject: _newProject,
        onOpenProject: _openProjectFile,
        onExportProject: _exportProjectFile,
        onSave: _save,
        onExport: _export,
        onUndo: _undo,
        onRedo: _redo,
        onDeleteSelection: _deleteSelection,
        onPoleTable: _showPoleTable,
        onTrackCheck: _showTrackCheck,
        onInspect: _inspect,
        onOffline: _onOffline,
        onStorageCleanup: _storageCleanup,
        onSync: _showSyncInfo,
        onToggleLeft: () => setState(() => _favOpen = !_favOpen),
        onToggleRight: () => setState(() => _rightCollapsed = !_rightCollapsed),
        onFocusMap: _focusMap,
        onZoomIn: _zoomIn,
        onZoomOut: _zoomOut,
        onResetView: _resetView,
        onFocusSearch: _focusSearch,
      );

  Widget _body(AppState st) {
    return LayoutBuilder(
      builder: (ctx, c) {
        // 右栏的显隐口径：
        //   · 用户手动开了才显示（选中点**不再自动展开**，v3.4.0）；
        //   · 窗口 < 1180（放不下）→ 不显示。
        // 收藏夹不再占常驻宽度：图标轨道 52px + 悬浮面板叠加在地图上。
        final showRight = !_rightCollapsed && c.maxWidth >= 1180;
        return Row(
          children: [
            _favRail(st),
            // 收藏夹停靠面板（奥维桌面版同款布局：常驻左侧、可拖宽、可收起）。
            if (_favOpen) ...[
              SizedBox(width: _leftW, child: _leftPanel(st)),
              _dragDivider((dx) => setState(
                  () => _leftW = (_leftW + dx).clamp(220.0, 460.0))),
            ],
            Expanded(child: _mapStack(st)),
            if (showRight)
              _dragDivider((dx) => setState(
                  () => _rightW = (_rightW - dx).clamp(240.0, 460.0))),
            if (showRight)
              SizedBox(width: _rightW, child: _rightPanel(st)),
          ],
        );
      },
    );
  }

  /// 最左侧图标轨道：目前只有「收藏夹」一个入口，后续同类入口（如体检、
  /// 导出中心）可以继续往下加，形成奥维桌面版左侧工具条的布局。
  Widget _favRail(AppState st) {
    Widget railBtn(IconData icon, String label, bool active, VoidCallback onTap) {
      final color = active ? kAccent : kTextSub;
      return InkWell(
        onTap: onTap,
        child: Container(
          width: 52,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(
                    fontSize: TokFs.micro, color: color, height: 1.1)),
          ]),
        ),
      );
    }

    return Container(
      width: 52,
      decoration: const BoxDecoration(
        color: TokC.panelSolid,
        border: Border(right: BorderSide(color: TokC.divider)),
      ),
      child: Column(children: [
        railBtn(Icons.bookmarks, '收藏夹', _favOpen,
            () => setState(() => _favOpen = !_favOpen)),
        railBtn(Icons.note_add, '新建', false, _newProject),
        const Spacer(),
      ]),
    );
  }

  Widget _leftPanel(AppState st) => LeftPanel(
        st: st,
        searchFocus: _searchFocus,
        onNewProject: _newProject,
        // 段落/点位行点击 → 与体检「定位」同一条路径（相机归壳）。
        onLocate: (l) => _locateLabels([l.id]),
        // 悬浮面板标题栏的「收起」按钮。
        onClose: () => setState(() => _favOpen = false),
      );

  Widget _rightPanel(AppState st) => RightPanel(
        st: st,
        label: _selLabel,
        sourceCid: _selCid,
        onCleared: () => setState(() {
          _selLabel = null;
          _selCid = '';
        }),
      );

  Widget _mapStack(AppState st) {
    return Stack(
      children: [
        MapCanvas(
          st: st,
          controller: _mc,
          baseProvider: _baseProvider!,
          overlayProvider: _overlayProvider,
          heading: 0,
          hasHeading: false,
          // 桌面：点选交给右栏（不直接弹对话框）。
          openDetailOnTap: false,
          // 交互开关**刻意不传**：走 [defaultFlagsForCurrentPlatform] 的桌面口径
          // （drag + scrollWheelZoom）。旧代码传的是 `InteractiveFlag.all` ——
          // 它虽然含滚轮缩放，但同时打开了旋转与惯性滑动，还会打开双击缩放，
          // 使每次单击落点都背上 250ms 的双击判定延迟（详见该方法注释）。
          onPointerGeo: _onMouseGeo,
          onSelect: (label, cid) => setState(() {
            _selLabel = label;
            _selCid = cid;
            // 选中一个点 → 自动展开右栏（右栏是属性检查器，此时才"有东西可看"，
            // 这正是它默认收起的前提）。取消选中时**不自动收起**：用户往往在
            // 连续核对多个点，频繁开合反而打断操作。
            if (label != null && _rightCollapsed) _rightCollapsed = false;
          }),
          onMapReady: () {
            _mapReady = true;
          },
          onCameraChanged: (cam) => setState(() => _cam = cam),
          onSecondaryTap: (tap, point) => showMapContextMenu(
            context,
            st,
            globalPosition: tap.global,
            point: point,
            controller: _mc,
            onLocate: _locateMe,
          ),
          extraLayers: [
            MarkerLayer(
              // 相机取自 [_cam]（onCameraChanged 回传），**不可**用 `_mc.camera`：
              // 后者在首帧前会抛异常，且会在 release AOT 中触发整棵 UI 子树被裁。
              markers: _cam == null
                  ? const <Marker>[]
                  : buildBusinessMarkers(st, _cam!, mapReady: _mapReady),
            ),
          ],
        ),
        // 比例尺（左下）
        Positioned(
          left: 12,
          bottom: 12,
          child: _mapReady
              ? ScaleBar(camera: _mc.camera)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  // ================= 模式提示栏 =================

  /// 奥维式模式提示栏：左边「现在是什么模式」，中间「能做什么、怎么退出」，
  /// 右边「这一模式下最该盯的实时数字」。
  ///
  /// 与移动端底部条**同源同口径**（同一套模式枚举、同一套统计），只是排布按
  /// 桌面横屏重排：移动端是「HUD + 一排芯片按钮」，桌面端是「模式胶囊 + 键盘提示
  /// + 数据 + 单个结束按钮」——后者在 1024px 起步的窗口里不会按钮换行，
  /// 也才放得下键盘提示（桌面端的主要操作入口是键盘 + 鼠标）。
  Widget _hintBar(AppState st) {
    final (tag, color, hint, stat) = _hintContent(st);
    final closable = st.mode == AppMode.measureDist ||
        st.mode == AppMode.measureArea ||
        st.mode == AppMode.topoLink ||
        st.mode == AppMode.boxSelect;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: TokC.toolbar,
        border: Border(top: BorderSide(color: TokC.divider)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(TokR.s),
              border: Border.all(color: color.withValues(alpha: 0.55)),
            ),
            child: Text(tag,
                style: TextStyle(
                    color: color, fontSize: TokFs.small, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kTextSub, fontSize: TokFs.small)),
          ),
          if (stat.isNotEmpty)
            Text(stat, style: const TextStyle(color: kAccent, fontSize: TokFs.small)),
          if (closable) ...[
            const SizedBox(width: 10),
            _hintBtn('完成 (Esc)', _escape),
          ],
        ],
      ),
    );
  }

  Widget _hintBtn(String text, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(TokR.s),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: TokC.divider,
            borderRadius: BorderRadius.circular(TokR.s),
          ),
          child: Text(text,
              style: const TextStyle(color: Color(0xFFD6DEE6), fontSize: TokFs.caption)),
        ),
      );

  /// 各模式的「标签 / 标签色 / 操作提示 / 实时数据」四元组。
  (String, Color, String, String) _hintContent(AppState st) {
    const panHint = '左键拖动平移 · 滚轮缩放 · Ctrl± 缩放 · Ctrl+0 复位 · 右键菜单';
    switch (st.mode) {
      case AppMode.edit:
        // 待定放置优先：此时落点语义与常规采集不同，必须换提示。
        if (st.draggingLabelId != null) {
          return ('待定放置', const Color(0xFFFFD54F),
              '点地图把该点放到新位置 · Esc 取消', '');
        }
        var total = 0.0;
        var seg = 0;
        for (final chain in buildLabelChains(st.labels)) {
          for (var i = 1; i < chain.length; i++) {
            total += chain[i].distanceM ??
                GeoUtil.haversine(chain[i - 1].lat, chain[i - 1].lon,
                    chain[i].lat, chain[i].lon);
            seg++;
          }
        }
        return (
          '采集中·${st.curType.name}',
          kAccent,
          '左键落点 · Backspace 退点 · Ctrl+Z 撤销 · Delete 删除选中 · Ctrl+S 保存',
          '${st.labels.length} 点'
              '${seg > 0 ? ' · 已连 ${_fmtChainLen(total)} / $seg 段' : ''}',
        );
      case AppMode.measureDist:
        return (
          '测距',
          const Color(0xFFFFCC80),
          '左键加点 · Backspace 退点 · 完成 (Esc) 结束测量',
          st.measurePts.length >= 2
              ? '总长 ${GeoUtil.fmtDist(st.measureTotal())} · ${st.measurePts.length} 点'
              : '${st.measurePts.length} 点（至少 2 点）',
        );
      case AppMode.measureArea:
        final n = st.measurePts.length;
        return (
          '测面积',
          const Color(0xFFAB47BC),
          '左键加顶点 · Backspace 退点 · 完成 (Esc) 结束测量',
          n >= 3
              ? '面积 ${GeoUtil.fmtArea(GeoUtil.polygonArea(st.measurePts.map((e) => e.lat).toList(), st.measurePts.map((e) => e.lon).toList(), n))} · $n 点'
              : '$n 点（至少 3 点）',
        );
      case AppMode.topoLink:
        final linked =
            st.topoColl.where((l) => l.topoParentId.isNotEmpty).length;
        return (
          '拓扑连线',
          const Color(0xFFFFCC80),
          '点起点箱体 → 点终点箱体 · Backspace 退一条连线 · 完成 (Esc) 结束',
          '已连 $linked / ${st.topoColl.length} 个箱体',
        );
      case AppMode.boxSelect:
        return (
          '框选',
          const Color(0xFF80D8FF),
          '在地图上拖出矩形选择点位 · 完成 (Esc) 退出框选',
          '已选 ${st.selectedIds.length} 点',
        );
      case AppMode.view:
        return (
          st.recording ? '轨迹中' : '普通',
          st.recording ? TokC.danger : const Color(0xFF9E9E9E),
          st.recording
              ? '轨迹录制中 · 桌面端无 GPS，请在移动端沿线走查录制'
              : '左键点选点位（右栏看属性） · $panHint',
          st.selectedIds.isEmpty ? '' : '已选 ${st.selectedIds.length} 点',
        );
    }
  }

  Widget _dragDivider(void Function(double dx) onDrag) => MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
          child: Container(
            width: 6,
            color: TokC.divider,
            child: Center(
              child: Container(width: 1, color: TokC.divider),
            ),
          ),
        ),
      );

  String _centerText(AppState st) {
    final c = _cam?.center ??
        LatLng(st.toDisplay(st.initLat, st.initLon)[0],
            st.toDisplay(st.initLat, st.initLon)[1]);
    return GeoUtil.formatCoord(c.latitude, c.longitude, st.coordFmt);
  }
}
