import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../geo/geo_convert.dart';
import '../geo/geo_util.dart';
import '../geo/route_layout.dart';
import '../geo/route_segments.dart';
import '../export/basemap_file_import.dart';
import '../export/kml_import.dart';
import '../models/diff_report.dart';
import '../models/label_type.dart';
import '../models/map_label.dart';
import '../models/map_source.dart';
import '../models/project_template.dart';
import '../services/amap.dart';
import '../services/loc.dart';
import '../services/store.dart';
import '../services/tianditu.dart';
import '../sync/sync_controller.dart';

/// 应用模式。
enum AppMode { view, edit, measureDist, measureArea, topoLink, boxSelect }

/// 全局状态：草稿编辑、地图源、定位、测量、轨迹、拓扑、收藏。
class AppState extends ChangeNotifier {
  /// [startupProjectPath] 非空时（T22 文件关联 / 命令行传入 `.ovimap` 路径），
  /// 在 [init] 完成后自动导入并打开该工程文件。
  AppState({this.startupProjectPath = ''});

  /// 启动参数里的 `.ovimap` 工程文件路径（空串表示无）。
  final String startupProjectPath;

  // ---- 常量与偏好键（与旧版一致，偏好无缝迁移） ----
  static const prefSrc = 'srcId';
  static const prefOverlay = 'overlayId';
  static const prefCustom = 'customSources';
  static const prefFmt = 'coordFmt';
  static const prefVisible = 'visibleCids';
  static const prefCam = 'camera';
  static const prefCompass = 'compassMode';
  static const prefAutoNum = 'autoNumber';
  static const prefNumPrefix = 'numPrefix';
  static const prefSegPrefix = 'segPrefix';
  static const prefTdtKey = 'tiandituKey';
  static const prefTplId = 'tplId';

  final LabelStore store = LabelStore.instance;

  /// 云同步编排器（架构文档 §12.9）。可为 null（未接入同步 / 测试环境）。
  ///
  /// 依赖方向 `AppState → SyncController` 单向；同步器反向通过 [SyncController.onRemoteApplied]
  /// 回调请求刷新，避免循环 import。
  SyncController? syncController;

  /// 接入同步器：保存/删除会经它触发上传；远端落盘后请它回调刷新本状态。
  void attachSyncController(SyncController sc) {
    syncController = sc;
    sc.onRemoteApplied = (cid) async {
      await refreshCollections();
      // 若该工程正在编辑器中打开，重载其点位（云端版本生效）。
      if (activeCollectionId == cid) {
        labels =
            (await store.loadCollection(cid)).map((e) => e.clone()).toList();
      }
      if (visibleCids.contains(cid)) {
        overlayLabels[cid] = await store.loadCollection(cid);
      }
      notifyListeners();
    };
  }

  SharedPreferences? _prefs;
  SharedPreferences get prefs => _prefs!;
  bool _inited = false;
  bool get inited => _inited;

  /// 测试专用：注入 SharedPreferences，绕过 init() 里的插件依赖
  /// （flutter_test 环境无 platform channel）。
  void setPrefsForTest(SharedPreferences p) {
    _prefs = p;
  }

  // ---- 草稿 ----
  List<MapLabel> labels = [];
  String projectName = '';
  String folderId = '';
  String editModeName = 'design'; // design | completion
  String activeCollectionId = '';

  // ---- 模式 ----
  AppMode mode = AppMode.view;
  LabelType curType = LabelType.pipe;

  // ---- 工程模板默认值（会话级 + prefs 持久化，仅作新增点默认值，不改字段语义） ----
  String defTypeId = 'pipe';
  int defSegKind = 0;
  String defSegCable = '';
  double defSlackM = 0;
  String? templateId;

  // ---- 选择集（批量编辑作用对象 = 草稿点 id，不跨收藏） ----
  final Set<String> selectedIds = {};

  // ---- 地图源 ----
  String? overlayId;
  int coordFmt = 0;

  List<MapSourceEntry> customSources = [];
  MapSourceEntry curSource = MapSources.sydtSatelliteAnn;

  List<MapSourceEntry> get allSources => [
        ...MapSources.presets(),
        ...MapSources.tianditu(tiandituKey),
        ...customSources,
      ];

  List<MapSourceEntry> get allOverlays => [
        ...MapSources.overlays(),
        ...MapSources.tianditu(tiandituKey).where((e) => e.overlay),
        ...customSources.where((e) => e.overlay),
      ];

  int get datum => curSource.datum;

  // ---- 定位 ----
  double? curLat, curLon, curAcc;
  double bearing = 0;
  bool hasFix = false;
  bool followUser = false;

  /// 地图随手机方向旋转（长按罗盘切换）。
  bool compassMode = false;

  // ---- 测量 ----
  List<MapLabel> measurePts = [];

  // ---- 轨迹记录 ----
  bool recording = false;
  bool recordPaused = false;
  List<MapLabel> recordPts = [];
  double recordDistance = 0;
  int recordStartMs = 0;

  // ---- 拓扑连线 ----
  String topoCid = '';
  List<MapLabel> topoColl = [];
  String? topoSelId;
  final List<String> topoUndoStack = [];

  // ---- 收藏 ----
  List<CollectionMeta> collections = [];
  List<Folder> folders = [];
  final Set<String> visibleCids = {};
  final Map<String, List<MapLabel>> overlayLabels = {};

  // ---- 相机 ----
  double initLat = 34.80;
  double initLon = 114.35;
  double initZoom = 5.0;

  // ================= 初始化 =================

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    coordFmt = prefs.getInt(prefFmt) ?? 0;
    compassMode = prefs.getBool(prefCompass) ?? false;

    // 自定义图源
    try {
      final raw = prefs.getString(prefCustom);
      if (raw != null && raw.isNotEmpty) {
        final arr = jsonDecode(raw) as List;
        customSources = arr
            .map((e) => MapSourceEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}

    // 图源恢复
    final srcId = prefs.getString(prefSrc);
    overlayId = prefs.getString(prefOverlay);
    curSource = MapSources.byId(allSources, srcId);

    // 可见收藏
    try {
      final vis = prefs.getString(prefVisible);
      if (vis != null && vis.isNotEmpty) {
        visibleCids.addAll(vis.split(','));
      }
    } catch (_) {}

    // 相机
    try {
      final cam = prefs.getString(prefCam);
      if (cam != null) {
        final p = cam.split(',');
        initLat = double.parse(p[0]);
        initLon = double.parse(p[1]);
        initZoom = double.parse(p[2]);
      }
    } catch (_) {}

    // 草稿
    final meta = await store.loadDraftMeta();
    projectName = meta.projectName;
    folderId = meta.folderId;
    editModeName = meta.editMode;
    labels = await store.loadDraft();

    // 工程模板默认值恢复（持久化，下次进入沿用）
    final tpl = ProjectTemplate.byId(prefs.getString(prefTplId));
    if (tpl != null) _applyTemplateSilently(tpl);

    await refreshCollections();
    await _loadVisibleOverlays();

    _inited = true;
    notifyListeners();

    // T22：命令行/文件关联传入的 `.ovimap` → 启动后自动导入并打开。
    if (startupProjectPath.trim().isNotEmpty) {
      await importProjectFile(startupProjectPath.trim());
    }
  }

  void saveCamera(double lat, double lon, double zoom) {
    prefs.setString(prefCam, '$lat,$lon,$zoom');
  }

  // ================= 坐标换算 =================

  List<double> toDisplay(double wgsLat, double wgsLon) =>
      GeoConvert.wgs84To(wgsLat, wgsLon, datum);

  List<double> toWgs(double dispLat, double dispLon) =>
      GeoConvert.toWgs84(dispLat, dispLon, datum);

  // ================= 图源管理 =================

  void applySource(MapSourceEntry e) {
    curSource = e;
    prefs.setString(prefSrc, e.id);
    notifyListeners();
  }

  void applyOverlay(String? id) {
    overlayId = id;
    if (id == null) {
      prefs.remove(prefOverlay);
    } else {
      prefs.setString(prefOverlay, id);
    }
    notifyListeners();
  }

  MapSourceEntry? currentOverlay() {
    if (overlayId == null) return null;
    for (final e in allOverlays) {
      if (e.id == overlayId) return e;
    }
    return null;
  }

  void addCustomSource(String name, String url, int datumSel, int maxZoom,
      {bool overlay = false}) {
    final id = 'custom-${DateTime.now().millisecondsSinceEpoch}';
    final e = MapSourceEntry(
        id: id,
        name: name.trim(),
        url: url.trim(),
        datum: datumSel,
        maxZoom: maxZoom,
        overlay: overlay,
        custom: true);
    customSources.add(e);
    _saveCustom();
    notifyListeners();
  }

  void removeCustomSource(String id) {
    customSources.removeWhere((e) => e.id == id);
    if (curSource.id == id) curSource = MapSources.sydtSatelliteAnn;
    if (overlayId == id) overlayId = null;
    _saveCustom();
    prefs.setString(prefSrc, curSource.id);
    notifyListeners();
  }

  void _saveCustom() {
    prefs.setString(
        prefCustom, jsonEncode(customSources.map((e) => e.toJson()).toList()));
  }

  /// 已配置的天地图开发者 key。用户没填时用内置默认 key 兜底（保证开箱即用）。
  /// 用户可在「更多→天地图 Key 设置」里改成自己的 key 覆盖内置值。
  /// 值单一来源：`lib/services/tianditu.dart` 的 [kBuiltinTiandituKey]。
  static const builtinTdtKey = kBuiltinTiandituKey;

  String get tiandituKey {
    final k = prefs.getString(prefTdtKey)?.trim() ?? '';
    return k.isEmpty ? builtinTdtKey : k;
  }

  void setTiandituKey(String key) {
    prefs.setString(prefTdtKey, key.trim());
    notifyListeners();
  }

  /// 天地图检索地名坐标系设置（第十九批新增）。
  /// 'gcj02'（默认，自动纠偏为 WGS84）/ 'wgs84'（不转换，保留原始返回坐标）。
  /// 用户为测绘出身，留开关便于对照验证。
  static const prefTdtCoordSys = 'tdtCoordSys';
  static const String tdtCoordGcj02 = 'gcj02';
  static const String tdtCoordWgs84 = 'wgs84';

  String get tdtCoordSys =>
      prefs.getString(prefTdtCoordSys) ?? tdtCoordGcj02;

  /// 是否对天地图检索结果做 GCJ-02→WGS-84 纠偏（默认 true）。
  bool get tdtConvertGcj => tdtCoordSys != tdtCoordWgs84;

  void setTdtCoordSys(String sys) {
    prefs.setString(prefTdtCoordSys, sys);
    notifyListeners();
  }

  /// 高德 Web 服务 key（第二十批新增，偏好键 `amapKey`）。
  ///
  /// **有内置 key（开箱即用）**：用户未配置自己的 key 时，[amapKey] 回退到
  /// 内置 [builtinAmapKey]；此时搜索自动「高德优先」，DXF 底图地名兜底亦优先走高德。
  /// 用户在「更多 → 高德 Key 设置」里填写自己的 key 后以用户值为优先。
  ///
  /// **无「停用高德」入口**：即使偏好值为空，[amapKey] 也回退内置值、**永不为空**，
  /// 故高德始终启用（仅在其网络失败时自动降级到天地图 / 境外源）。如需彻底停用高德，
  /// 需新增一个独立开关（当前无此入口）；[userAmapKey] 暴露用户原始（可能为空的）输入。
  /// 值单一来源：`lib/services/amap.dart` 的 [kBuiltinAmapKey]。
  static const prefAmapKey = 'amapKey';

  /// 内置高德 key 常量（单一来源：`lib/services/amap.dart` 的 [kBuiltinAmapKey]）。
  /// 用户可在「更多 → 高德 Key 设置」里覆盖。
  static const builtinAmapKey = kBuiltinAmapKey;

  /// 生效的高德 key：用户自配优先，未配置则回退内置 key（开箱即用）。
  String get amapKey {
    final k = prefs.getString(prefAmapKey)?.trim() ?? '';
    return k.isEmpty ? builtinAmapKey : k;
  }

  /// 用户**显式**配置的高德 key（可能为空串；不参与内置回退）。
  /// 供设置界面回显用户原始输入用（避免把内置 key 当成用户值展示）。
  String get userAmapKey => prefs.getString(prefAmapKey)?.trim() ?? '';

  void setAmapKey(String key) {
    prefs.setString(prefAmapKey, key.trim());
    notifyListeners();
  }

  /// 用户自定义 Overpass 端点（底图数据源）原文（偏好键 `overpassEndpoints`）。
  ///
  /// 背景：内置 Overpass 镜像全在境外，抓取建筑/道路慢且不稳。用户可用
  /// Cloudflare Worker / 自建服务器架反代，把地址填在这里——[overpassEndpoints]
  /// 会**优先于内置**被使用（内置退居兜底）。支持换行 / 逗号 / 分号分隔多个。
  ///
  /// **无内置兜底值**：留空即"全用内置 5 个境外镜像"，与既有行为完全一致。
  /// 值仅作原文存储，解析（去重/优先排序）交由 `OverpassEndpoints.resolve`。
  static const prefOverpassEndpoints = 'overpassEndpoints';

  /// 生效的自定义 Overpass 端点原文（可能为空串 = 未配置）。
  String get overpassEndpoints =>
      prefs.getString(prefOverpassEndpoints)?.trim() ?? '';

  /// 设置自定义 Overpass 端点（多分隔符原文；空串 = 恢复内置）。
  void setOverpassEndpoints(String v) {
    prefs.setString(prefOverpassEndpoints, v.trim());
    notifyListeners();
  }

  void resetMapSettings() {
    prefs.remove(prefSrc);
    prefs.remove(prefOverlay);
    prefs.remove(prefFmt);
    curSource = MapSources.sydtSatelliteAnn;
    overlayId = null;
    coordFmt = 0;
    notifyListeners();
  }

  // ================= 编辑 =================

  bool get autoNumber => prefs.getBool(prefAutoNum) ?? false;
  String get numPrefix => prefs.getString(prefNumPrefix) ?? 'GK';

  /// 段标前缀（如 埋／架）。默认空串 = 不改变既有行为（段标注仅显示数字）。
  /// 渲染/导出时若 [MapLabel.distLabel] 为空，会自动补成"前缀 + 段距"。
  String get segPrefix => prefs.getString(prefSegPrefix)?.trim() ?? '';

  /// 在显示坐标处添加标签（自动续线组、自动编号）。
  MapLabel addLabelAtDisp(double dispLat, double dispLon) {
    final w = toWgs(dispLat, dispLon);
    return addLabelAtWgs(w[0], w[1]);
  }

  MapLabel addLabelAtWgs(double lat, double lon) {
    final l = MapLabel(
      typeId: curType.id,
      seq: labels.length + 1,
      lat: lat,
      lon: lon,
    );
    final isText = curType.id == 'text';
    final lineType = curType.id == 'track' || curType.id == 'none';
    if (!isText && !curType.isStandalone && !_chainBroken) {
      // 统一连续绘制：延续上一个连线点的线组，切换类型不断线。
      // ⚠️ [_chainBroken] 打开收藏 / 新建工程后置位：**新工程的第一笔绝不许
      // 接在已打开工程的末端**（用户反馈「点击打点老是连接上一次工程的末端，
      // 怎么也取消不了」）；该笔落下后复位，后续点恢复连续绘制。
      final prev = lastLineLabel();
      if (prev != null) {
        if (prev.lineGroupId.isEmpty) {
          final g = MapLabel().id;
          prev.lineGroupId = g;
          l.lineGroupId = g;
        } else {
          l.lineGroupId = prev.lineGroupId;
        }
      }
    } else if (_chainBroken && !isText && !curType.isStandalone) {
      _chainBroken = false; // 断开后的第一笔已落，恢复连续绘制
    }
    // 模板默认值：仅当模板默认非"空"时给新点写入（不改字段语义，不影响自动编号）
    if (defSegKind != 0 || defSegCable.isNotEmpty || defSlackM > 0) {
      l.segKind = defSegKind;
      l.segCable = defSegCable;
      l.slackM = defSlackM;
    }
    // 逐点快照（用户反馈「撤销一次撤一大半」）：打点前先存快照，
    // Ctrl+Z 一次只回退一个点；栈深由 [_undoLimit] 兜底。
    pushUndoSnapshot();
    labels.add(l);
    // 自动编号（杆类点）
    if (autoNumber && !isText && !lineType) {
      final prefix = numPrefix;
      var n = 1;
      for (final e in labels) {
        if (identical(e, l)) continue;
        if (e.name.startsWith(prefix)) n++;
      }
      l.name = '$prefix-$n';
    }
    _saveDraft();
    notifyListeners();
    return l;
  }

  /// 上一个参与连线的点（跳过文字与独立个体）。
  MapLabel? lastLineLabel() {
    for (var i = labels.length - 1; i >= 0; i--) {
      final e = labels[i];
      if (e.typeId == 'text') continue;
      if (e.type.isStandalone) continue;
      return e;
    }
    return null;
  }

  /// 续画断路器：true 时下一笔连线型点**不接**任何已有线组。
  ///
  /// 置位时机：[openCollection] / [startNewDraft]（跨工程绝不续画）、
  /// 用户右键「断开续画」（[breakChain]）。新点落下后自动复位。
  bool _chainBroken = false;

  /// 手动断开续画：下一点另起新线（右键菜单入口）。
  void breakChain() {
    _chainBroken = true;
    notifyListeners();
  }

  // ================= 标记模式（独立打标，自动存根目录） =================

  /// 标记模式开关：开启后点地图**只落独立标记**（不连线、不进草稿），
  /// 每点一次自动追加到根目录收藏「标记」并实时落盘（用户需求：只标记
  /// 不连线、自动保存、符号来自符号库）。
  bool markMode = false;

  void toggleMarkMode() {
    markMode = !markMode;
    notifyListeners();
  }

  /// 标记模式下的落点：用当前符号（若为连线型则按独立点落），
  /// 自动编号「标记N」，追加进根目录「标记」收藏。
  Future<void> addMarkAtWgs(double lat, double lon) async {
    final l = MapLabel(
      typeId: curType.id,
      seq: 1,
      lat: lat,
      lon: lon,
      name: '标记${_markCount + 1}',
    );
    l.lineGroupId = ''; // 只标记不连线
    _markCount++;
    await _appendToMarkBook(l);
    // 用户指定：标记一次即自动退出标记模式，随后点击回到正常打点。
    markMode = false;
    notifyListeners();
  }

  /// 把某个标记点从原收藏移到目标文件夹（落到该层的「标记」收藏里；
  /// 目标层没有就新建一个）。用于「所有条目都可拖拽/移动到文件夹」。
  Future<void> moveMarkToFolder(String fromCid, MapLabel l, String toFolder) async {
    final from = await store.loadCollection(fromCid);
    from.removeWhere((e) => e.id == l.id);
    final fromMeta = collections.where((m) => m.id == fromCid).toList();
    if (fromMeta.isNotEmpty) {
      await store.finishCollection(
        existingId: fromCid,
        name: fromMeta.first.name,
        kind: fromMeta.first.kind,
        folderId: fromMeta.first.folder,
        editMode: fromMeta.first.editMode,
        labels: from,
      );
    }

    // 目标层的「标记」收藏（没有则建）。
    CollectionMeta? target;
    for (final m in collections) {
      final isMark = m.kind == 'mark' || m.name == kMarkBook;
      if (isMark && m.folder == toFolder) {
        target = m;
        break;
      }
    }
    String toCid;
    List<MapLabel> toLabels;
    if (target == null) {
      toLabels = [l..seq = 1];
      toCid = await store.finishCollection(
          name: kMarkBook,
          kind: 'mark',
          folderId: toFolder,
          editMode: 'design',
          labels: toLabels);
    } else {
      toCid = target.id;
      toLabels = await store.loadCollection(toCid);
      l.seq = toLabels.length + 1;
      toLabels.add(l);
      await store.finishCollection(
          existingId: toCid,
          name: kMarkBook,
          kind: 'mark',
          folderId: toFolder,
          editMode: 'design',
          labels: toLabels);
    }
    await refreshCollections();
    overlayLabels[toCid] = await store.loadCollection(toCid);
    if (visibleCids.contains(fromCid)) {
      overlayLabels[fromCid] = from;
    }
    if (!visibleCids.contains(toCid)) visibleCids.add(toCid);
    prefs.setString(prefVisible, visibleCids.join(','));
    notifyListeners();
  }

  static const String kMarkBook = '标记';
  int _markCount = 0;

  /// 把点追加进根目录「标记」收藏（没有则创建），并在地图上显示。
  Future<void> _appendToMarkBook(MapLabel l) async {
    CollectionMeta? meta;
    for (final m in collections) {
      final isMark = m.kind == 'mark' || (m.name == kMarkBook && m.folder.isEmpty);
      if (isMark && m.folder.isEmpty) {
        meta = m;
        break;
      }
    }
    List<MapLabel> ls;
    String cid;
    if (meta == null) {
      ls = [l];
      cid = await store.finishCollection(
          name: kMarkBook, kind: 'mark', folderId: '', editMode: 'design', labels: ls);
    } else {
      cid = meta.id;
      ls = await store.loadCollection(cid);
      l.seq = ls.length + 1;
      ls.add(l);
      await store.finishCollection(
          existingId: cid,
          name: kMarkBook,
          kind: 'mark',
          folderId: '',
          editMode: 'design',
          labels: ls);
    }
    await refreshCollections();
    // 自动在地图上显示（首点自动开显，后续保持）。
    if (!visibleCids.contains(cid)) visibleCids.add(cid);
    prefs.setString(prefVisible, visibleCids.join(','));
    overlayLabels[cid] = await store.loadCollection(cid);
  }

  /// 本点在所属线组上的上一个连线点（竣工段距确认的基准）。
  /// 竣工模式逐点弹窗时，"到上一点距离"必须取同线组上一杆——
  /// 旧逻辑取列表里紧邻的上一个点，箱体/文字插在中间时会算错段。
  MapLabel? previousChainLabel(MapLabel l) {
    final idx = labels.indexOf(l);
    for (var i = idx - 1; i >= 0; i--) {
      final e = labels[i];
      if (!isLineMember(e)) continue;
      if (l.lineGroupId.isEmpty || e.lineGroupId == l.lineGroupId) {
        return e;
      }
    }
    return null;
  }

  // ---- 快照撤销栈（奥维式全局撤销：删除/清空/拖动/插点/导入都可回退） ----
  final List<String> _undoSnapshots = [];
  static const int _undoLimit = 20;

  /// 重做栈（与撤销栈对偶；桌面快捷键 Ctrl+Y / Ctrl+Shift+Z 使用）。
  final List<String> _redoSnapshots = [];
  static const int _redoLimit = 20;

  /// 破坏性操作前调用：压入当前草稿快照（JSON 深拷贝，上限 20 步）。
  /// 新的编辑动作会清空重做栈（标准撤销/重做语义）。
  void pushUndoSnapshot() {
    _undoSnapshots
        .add(jsonEncode(labels.map((e) => e.toJson()).toList()));
    if (_undoSnapshots.length > _undoLimit) _undoSnapshots.removeAt(0);
    _redoSnapshots.clear();
  }

  bool get canUndoSnapshot => _undoSnapshots.isNotEmpty;

  /// 是否可重做。
  bool get canRedo => _redoSnapshots.isNotEmpty;

  void _pushRedo(String snap) {
    _redoSnapshots.add(snap);
    if (_redoSnapshots.length > _redoLimit) _redoSnapshots.removeAt(0);
  }

  void undoDraft() {
    // 优先回退快照（覆盖删除/清空/拖动/插点/导入），栈空时退化为撤销末点
    final currentSnapshot = jsonEncode(labels.map((e) => e.toJson()).toList());
    if (_undoSnapshots.isNotEmpty) {
      try {
        final arr = jsonDecode(_undoSnapshots.removeLast()) as List;
        _pushRedo(currentSnapshot);
        labels = arr
            .map((e) => MapLabel.fromJson(e as Map<String, dynamic>))
            .toList();
        _saveDraft();
        notifyListeners();
        return;
      } catch (_) {
        _undoSnapshots.clear(); // 快照损坏：清空防止反复失败
      }
    }
    if (labels.isEmpty) return;
    _pushRedo(currentSnapshot);
    labels.removeLast();
    _saveDraft();
    notifyListeners();
  }

  /// 重做上一次撤销（与 [undoDraft] 对偶）。
  void redo() {
    if (_redoSnapshots.isEmpty) return;
    final currentSnapshot = jsonEncode(labels.map((e) => e.toJson()).toList());
    final snap = _redoSnapshots.removeLast();
    _undoSnapshots.add(currentSnapshot);
    if (_undoSnapshots.length > _undoLimit) _undoSnapshots.removeAt(0);
    try {
      final arr = jsonDecode(snap) as List;
      labels = arr
          .map((e) => MapLabel.fromJson(e as Map<String, dynamic>))
          .toList();
      _saveDraft();
      notifyListeners();
    } catch (_) {
      // 快照损坏：忽略该次重做
    }
  }

  void clearDraft() {
    pushUndoSnapshot();
    labels.clear();
    _saveDraft();
    notifyListeners();
  }

  void markHere() {
    final lat = curLat ?? initLat;
    final lon = curLon ?? initLon;
    final l = MapLabel(
      typeId: curType.id,
      seq: labels.length + 1,
      lat: lat,
      lon: lon,
      name: '我在这',
    );
    labels.add(l);
    _saveDraft();
    notifyListeners();
  }

  /// 从已存点续画新杆路：复制该点为新线组起点。
  void startRouteFrom(MapLabel near) {
    _chainBroken = false; // 显式续画：恢复连续绘制
    String typeId;
    if (near.type.isStandalone) {
      typeId = (curType.isStandalone || curType.id == 'text')
          ? LabelType.concrete.id
          : curType.id;
    } else {
      typeId = near.typeId;
    }
    final first = MapLabel(
      typeId: typeId,
      seq: labels.length + 1,
      lat: near.lat,
      lon: near.lon,
      lineGroupId: MapLabel().id, // 直接开新线组
    );
    labels.add(first);
    _saveDraft();
    notifyListeners();
  }

  void setType(LabelType t) {
    curType = t;
    if (mode != AppMode.edit) mode = AppMode.edit;
    notifyListeners();
  }

  void setMode(AppMode m) {
    if (m == mode) return;
    if (m != AppMode.measureDist && m != AppMode.measureArea) {
      measurePts = [];
    }
    mode = m;
    notifyListeners();
  }

  void chooseEditMode(String em) {
    editModeName = em;
    _saveDraft();
    notifyListeners();
  }

  void setAutoNumber(bool v, String prefix) {
    prefs.setBool(prefAutoNum, v);
    prefs.setString(prefNumPrefix, prefix.trim().isEmpty ? 'GK' : prefix.trim());
    notifyListeners();
  }

  /// 段标前缀：trim 后存；空串即清除（等同"不自动加前缀"）。
  void setSegPrefix(String v) {
    prefs.setString(prefSegPrefix, v.trim());
    notifyListeners();
  }

  /// 段落单一真源视图：所有功能（连线/导出/属性面板）都读它，不再各自算段距。
  ///
  /// 在 [buildLabelChains] 之上由 [RouteSegment.build] 统一构建；段标前缀沿用
  /// [segPrefix]，保证与地图渲染 / 导出口径完全一致。这是本轮"段落单一真源"
  /// 的核心入口，任何需要段距 / 段标注的地方都应走这里，而不是自己分组计算。
  List<RouteSegment> get segments =>
      RouteSegment.build(labels, prefix: segPrefix);

  /// 持久化草稿；若当前是「打开收藏编辑」状态，**同步写回收藏文件**。
  ///
  /// ## 为什么两处都要写
  /// `openCollection` 之后草稿（`draft.json`）与收藏（`collection_<cid>.json`）
  /// 是同一份数据的两个落点：草稿管「重启后恢复现场」，收藏管「收藏夹里那一条」。
  /// 曾经只有 [updateLabel] 同步收藏——打点 / 删点 / 撤销重做 / 从此点续画全都只写
  /// 草稿，收藏文件停在打开时的旧内容，重启后这些改动全部丢失。
  /// 用户反馈「添加的轨迹和标签没有保存功能」的根因即在此。收敛到一处后，
  /// 任何改 `labels` 的路径只要调了本方法就不会再漏。
  ///
  /// [topoCid] 非空时由拓扑编辑流程自己落盘（见 [updateLabel] 的历史口径），不在这里抢。
  void _saveDraft() {
    store.saveDraft(labels, projectName, folderId, editModeName);
    if (activeCollectionId.isNotEmpty && topoCid.isEmpty) {
      store.saveCollectionLabels(activeCollectionId, labels);
    }
  }

  /// 新建空白工程：先脱离已打开的收藏，**再**清草稿。
  ///
  /// 顺序不能反——[_saveDraft] 现在会把草稿同步回收藏文件；若先清空再脱离，
  /// 空列表会被写进收藏，把整个工程内容清掉。桌面 `_newProject`、移动端
  /// 「新建」都必须走这里，不允许自己拼顺序。
  void startNewDraft() {
    activeCollectionId = '';
    _openedForEdit = false;
    _chainBroken = true; // 新建空白工程：从零开始画
    clearDraft();
    projectName = '';
    folderId = '';
    _saveDraft();
  }

  void updateLabel(MapLabel l) {
    _saveDraft();
    notifyListeners();
  }

  void removeLabel(MapLabel l) {
    pushUndoSnapshot();
    labels.remove(l);
    _saveDraft();
    notifyListeners();
  }

  /// 删除当前选择集（桌面快捷键 Delete / 各壳工具条）。
  ///
  /// 与 [removeLabel] 同口径，但**一次快照覆盖整批删除**（一次 Ctrl+Z 可还原）。
  /// 选择集为空时不做任何事。返回删除的点数。
  int deleteSelected() {
    if (selectedIds.isEmpty) return 0;
    final ids = selectedIds.toList();
    pushUndoSnapshot();
    labels.removeWhere((l) => ids.contains(l.id));
    selectedIds.clear();
    _saveDraft();
    notifyListeners();
    return ids.length;
  }

  /// 删除 [l] 所在的**整条连线**（同线组全部点）——「删除线太费劲」的
  /// 一键入口：以前只能逐点右键删。一次快照覆盖整批（Ctrl+Z 可整条还原）。
  ///
  /// [l] 不在线组里（lineGroupId 为空）时退化为删除单点。
  int deleteChain(MapLabel l) {
    final gid = l.lineGroupId;
    final targets = gid.isEmpty
        ? <MapLabel>[l]
        : labels.where((e) => e.lineGroupId == gid).toList();
    if (targets.isEmpty) return 0;
    pushUndoSnapshot();
    labels.removeWhere((e) => targets.contains(e));
    selectedIds.removeAll(targets.map((e) => e.id));
    _saveDraft();
    notifyListeners();
    return targets.length;
  }

  /// 更新某个可见收藏工程里的一个点（普通模式点选编辑保存时调用）。
  Future<void> updateOverlayLabel(String cid, MapLabel l) async {
    final list = overlayLabels[cid];
    if (list == null) return;
    final i = list.indexWhere((e) => e.id == l.id);
    if (i < 0) return;
    list[i] = l;
    await store.saveCollectionLabels(cid, list);
    notifyListeners();
  }

  /// 从某个可见收藏工程里删除一个点。
  Future<void> removeOverlayLabel(String cid, MapLabel l) async {
    final list = overlayLabels[cid];
    if (list == null) return;
    list.removeWhere((e) => e.id == l.id);
    await store.saveCollectionLabels(cid, list);
    await store.setCollectionCount(cid, list.length);
    notifyListeners();
  }

  // ---- 待定编辑：拖动点位（奥维/Bigemap 顶点编辑式交互） ----

  /// 非 null 时处于"拖动点位"状态：地图上点一下，该点移到点击处。
  String? draggingLabelId;

  bool get hasPendingEdit => draggingLabelId != null;

  void cancelPendingEdit() {
    draggingLabelId = null;
    notifyListeners();
  }

  MapLabel? labelById(String id) {
    for (final l in labels) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// 把已有点移到新位置（WGS84），相邻同链点的段距改为自动重算。
  void moveLabelToWgs(MapLabel l, double lat, double lon) {
    pushUndoSnapshot();
    l.lat = lat;
    l.lon = lon;
    _invalidateNeighborDist(l);
    _saveDraft();
    notifyListeners();
  }

  /// 相邻同链点的实测段距改为自动（haversine）；段标注文字保留，如需修正点开属性改。
  void _invalidateNeighborDist(MapLabel l) {
    final idx = labels.indexOf(l);
    for (final d in const [-1, 1]) {
      final i = idx + d;
      if (i < 0 || i >= labels.length) continue;
      final n = labels[i];
      if (n.lineGroupId.isNotEmpty && n.lineGroupId == l.lineGroupId) {
        n.distanceM = null;
      }
    }
  }

  // ================= 批量编辑 / 工程模板 / 自动布杆 =================

  /// 套用工程模板：只设置"默认值"（此后新增点沿用），并持久化。
  void applyTemplate(ProjectTemplate t) {
    _applyTemplateSilently(t);
    prefs.setString(prefTplId, t.id);
    notifyListeners();
  }

  void _applyTemplateSilently(ProjectTemplate t) {
    templateId = t.id;
    defTypeId = t.defTypeId;
    defSegKind = t.defSegKind;
    defSegCable = t.defSegCable;
    defSlackM = t.defSlackM;
    curType = LabelType.fromId(t.defTypeId);
  }

  /// 选中一条线组的全部点（复用 [buildLabelChains] 的链口径）。
  void selectChain(String lineGroupId) {
    selectedIds.clear();
    for (final l in labels) {
      if (l.lineGroupId == lineGroupId) selectedIds.add(l.id);
    }
    notifyListeners();
  }

  /// 清空选择集。
  void clearSelection() {
    if (selectedIds.isEmpty) return;
    selectedIds.clear();
    notifyListeners();
  }

  /// 框选：按"显示坐标系"矩形范围选入草稿点（仅草稿，不跨收藏）。
  void selectInDisplayBounds(double minDispLat, double minDispLon,
      double maxDispLat, double maxDispLon) {
    selectedIds.clear();
    for (final l in labels) {
      final d = toDisplay(l.lat, l.lon);
      if (d[0] >= minDispLat &&
          d[0] <= maxDispLat &&
          d[1] >= minDispLon &&
          d[1] <= maxDispLon) {
        selectedIds.add(l.id);
      }
    }
    notifyListeners();
  }

  /// 对选中集批量赋值。**先压一次快照**，故整批修改可一次撤销。返回实际改动点数。
  int applyBatch(BatchEdit e) {
    if (e.isEmpty && !e.renumber) return 0;
    final hit = labels.where((l) => selectedIds.contains(l.id)).toList();
    if (hit.isEmpty) return 0;
    pushUndoSnapshot(); // ① 一次撤销：整批改动共享一个快照
    var n = 0;
    for (var i = 0; i < hit.length; i++) {
      final l = hit[i];
      if (e.segKind != null) l.segKind = e.segKind!;
      if (e.segCable != null) l.segCable = e.segCable!;
      if (e.slackM != null) l.slackM = e.slackM!;
      if (e.namePrefix != null) {
        if (e.renumber) {
          final pf = e.namePrefix!;
          l.name = pf.isEmpty ? '${i + 1}' : '$pf-${i + 1}';
        } else {
          l.name = _replacePrefix(l.name, e.namePrefix!);
        }
      }
      if (e.distLabelPrefix != null) {
        final pf = e.distLabelPrefix!;
        final m = RegExp(r'[\d.]+').firstMatch(l.distLabel);
        l.distLabel = pf + (m?.group(0) ?? '');
      }
      n++;
    }
    _saveDraft();
    notifyListeners();
    return n;
  }

  /// 仅换命名前缀、保留原编号：`GK-12` → `新前缀-12`；无编号则整体设为前缀。
  String _replacePrefix(String name, String prefix) {
    final m = RegExp(r'(\d+)\s*$').firstMatch(name.trim());
    if (m != null) {
      final num = m.group(1)!;
      return prefix.isEmpty ? num : '$prefix-$num';
    }
    return prefix;
  }

  /// 批量生成段标注（**固化**用途，非日常主力）：把当前自动显示写死成静态文字。
  ///
  /// ⚠️ 代价与用途：本方法把"前缀+距离"作为硬字符串写入 [MapLabel.distLabel]。
  /// 固化后段距变化**不会**再自动跟随——挪一个点，图上仍标着旧数字，可能造成
  /// 与实际不符。因此日常请改用「批量设置敷设方式」，让段标经 [GeoUtil.segTextFor]
  /// 从 [MapLabel.segKind] 实时带前缀、随段距自动变化；本方法仅在需要给纸质图纸
  /// 写死数字时使用。
  ///
  /// 写入值 = 前缀 + [GeoUtil.segDistText](段距)：
  /// · 本段敷设方式经 [GeoUtil.kindPrefixOf](从 [MapLabel.segKind] 实时推导，如架空→"架"）
  ///   优先；否则用全局段标前缀 [segPrefix]；两者都空则只写距离纯数字；整数去 ".0" 毛刺。
  ///
  /// [overwrite]=false（默认）只填 [MapLabel.distLabel] 为空的段，已有标注不动；
  /// [overwrite]=true 全部重写。
  ///
  /// **必须**先压一次撤销快照（对齐 [applyBatch] 风格），使整批可一次撤销；
  /// 无实际改动时不压快照、返回 0。
  ///
  /// 返回实际改动条数。
  int autoFillSegLabels({bool overwrite = false}) {
    final segs = segments; // 复用唯一真源，避免重复分组
    // 先算出要写哪些（不改动草稿），以便"无改动则不压快照"。
    final edits = <MapLabel, String>{};
    for (final s in segs) {
      final cur = s.to.distLabel.trim();
      if (!overwrite && cur.isNotEmpty) continue; // 只填空白段
      // 前缀实时从敷设方式推导（kindPrefixOf），全局段标前缀 segPrefix 作回退；
      // 两者皆空则只写距离纯数字。距离用 segDistText 去 ".0" 毛刺。
      final prefix = GeoUtil.kindPrefixOf(s.kind) ?? segPrefix;
      final value = prefix.isEmpty
          ? GeoUtil.segDistText(s.lengthM)
          : '$prefix${GeoUtil.segDistText(s.lengthM)}';
      if (cur == value) continue; // 已是目标值，跳过（避免无谓改动 / 误触快照）
      edits[s.to] = value;
    }
    if (edits.isEmpty) return 0; // 无改动：不压快照、返回 0
    pushUndoSnapshot(); // ① 一次撤销：整批共享一个快照
    for (final e in edits.entries) {
      e.key.distLabel = e.value;
    }
    _saveDraft();
    notifyListeners();
    return edits.length;
  }

  /// 批量清空段标：把段标注回退为「实时距离 + 自动前缀」。
  ///
  /// 用途：出图体检报出「标注数字与实测段距偏差过大」时，一键把可疑的手填标注清掉，
  /// 让段标重新由 [GeoUtil.segTextFor] 依据敷设方式与实测段距**实时**生成。
  /// 留着一个与几何不符的数字，审图会直接判错——清掉它比留着更安全。
  ///
  /// 只对 [distLabel] 非空的目标生效；一次快照覆盖整批，可一次撤销。
  /// 返回实际清掉的段数（本来就没标的不计）。
  int clearSegLabels(List<MapLabel> targets) {
    final hit = targets.where((l) => l.distLabel.trim().isNotEmpty).toList();
    if (hit.isEmpty) return 0;
    pushUndoSnapshot();
    for (final l in hit) {
      l.distLabel = '';
    }
    _saveDraft();
    notifyListeners();
    return hit.length;
  }

  /// 设置某一段的段标文字（左栏段落表就地编辑、属性面板共用）。
  ///
  /// 语义：空串 = 清除手填标注，段标随即回退为「敷设方式前缀 + 实测距离」的**实时**
  /// 生成结果（这正是希望的行为——手填只是覆盖，撤掉覆盖就回到自动）。
  ///
  /// 为什么不用 [updateLabel]：那个方法不压快照。段标是审图重点，用户打错一个数字
  /// 必须能 Ctrl+Z 退回，所以这里**先压快照**。
  ///
  /// 返回是否真的产生了改动（同值写入不压快照、不脏化草稿）。
  bool setSegLabel(MapLabel to, String text) {
    final v = text.trim();
    if (to.distLabel.trim() == v) return false;
    pushUndoSnapshot();
    to.distLabel = v;
    _saveDraft();
    notifyListeners();
    return true;
  }

  /// 常用档距自动布杆：两点直线等距落杆（含起点与终点），结果可一次撤销。
  /// 命名接续现有自动编号口径（`前缀-n`），落点可后续拖动微调。返回杆数。
  int autoPlacePoles({
    required double sLat,
    required double sLon,
    required double eLat,
    required double eLon,
    required double spacingM,
    required String typeId,
    required String prefix,
  }) {
    final pts = RouteLayout.autoPoles(
      startLat: sLat,
      startLon: sLon,
      endLat: eLat,
      endLon: eLon,
      // 防御 NaN / Infinity / 非正档距，兜底为默认 50m。
      spacingM: (spacingM.isFinite && spacingM > 0) ? spacingM : 50,
    );
    if (pts.isEmpty) return 0;
    pushUndoSnapshot(); // 布杆 = 破坏性操作，先压快照（一次撤销）
    final gid = MapLabel().id; // 本次布杆独立成一条新线组
    final pfx = prefix.trim().isEmpty ? numPrefix : prefix.trim();
    // 接续现有同名编号
    var startNo = 1;
    for (final e in labels) {
      if (e.name.startsWith(pfx)) startNo++;
    }
    final base = labels.length;
    for (var i = 0; i < pts.length; i++) {
      final l = MapLabel(
        typeId: typeId,
        seq: base + i + 1,
        lat: pts[i][0],
        lon: pts[i][1],
        lineGroupId: gid,
      );
      if (defSegKind != 0 || defSegCable.isNotEmpty || defSlackM > 0) {
        l.segKind = defSegKind;
        l.segCable = defSegCable;
        l.slackM = defSlackM;
      }
      l.name = '$pfx-${startNo + i}';
      labels.add(l);
    }
    _saveDraft();
    notifyListeners();
    return pts.length;
  }

  // ================= 收藏 =================

  Future<void> refreshCollections() async {
    collections = await store.loadIndex();
    folders = await store.loadFolders();
    notifyListeners();
  }

  Future<void> _loadVisibleOverlays() async {
    for (final cid in visibleCids.toList()) {
      if (!overlayLabels.containsKey(cid)) {
        overlayLabels[cid] = await store.loadCollection(cid);
      }
    }
    for (final cid in overlayLabels.keys.toList()) {
      if (!visibleCids.contains(cid)) overlayLabels.remove(cid);
    }
  }

  void toggleVisible(String cid) {
    if (visibleCids.contains(cid)) {
      visibleCids.remove(cid);
      overlayLabels.remove(cid);
    } else {
      visibleCids.add(cid);
      store.loadCollection(cid).then((ls) {
        overlayLabels[cid] = ls;
        notifyListeners();
      });
    }
    prefs.setString(prefVisible, visibleCids.join(','));
    notifyListeners();
  }

  /// 文件夹级批量显隐（奥维图层管理式）：把 [cids] 全部设为可见/隐藏。
  Future<void> setVisibleBulk(Iterable<String> cids, bool visible) async {
    var changed = false;
    for (final cid in cids) {
      if (visible && !visibleCids.contains(cid)) {
        visibleCids.add(cid);
        changed = true;
      } else if (!visible && visibleCids.contains(cid)) {
        visibleCids.remove(cid);
        overlayLabels.remove(cid);
        changed = true;
      }
    }
    if (!changed) return;
    prefs.setString(prefVisible, visibleCids.join(','));
    if (visible) await _loadVisibleOverlays();
    notifyListeners();
  }

  /// 打开收藏到编辑器。
  Future<void> openCollection(CollectionMeta meta) async {
    final ls = await store.loadCollection(meta.id);
    labels = ls.map((e) => e.clone()).toList();
    projectName = meta.name;
    folderId = meta.folder;
    editModeName = meta.editMode;
    activeCollectionId = meta.id;
    _openedForEdit = true;
    _chainBroken = true; // 打开收藏：新打的第一笔绝不接在收藏末端
    mode = AppMode.edit;
    // 收藏打开即作为草稿继续编辑（保存时覆盖原收藏）
    await store.saveDraft(labels, projectName, folderId, editModeName);
    notifyListeners();
    // 打开工程时拉取该工程最新（若服务端 rev 更新，落盘后经 onRemoteApplied 重载）。
    unawaited(syncController?.pullProject(meta.id) ?? Future<void>.value());
  }

  /// 保存收藏。默认总是新建；重名自动追加 (2)/(3)…，绝不覆盖旧工程。
  /// 仅当从收藏夹显式打开编辑（openedForEdit=true）时保存才更新原工程。
  Future<String> finishCollection({String kind = 'label'}) async {
    var name = projectName.isEmpty ? '未命名项目' : projectName;
    final updating = _openedForEdit && activeCollectionId.isNotEmpty;
    if (!updating) {
      name = await _uniqueName(name);
    }
    projectName = name;
    final cid = await store.finishCollection(
      existingId: updating ? activeCollectionId : '',
      name: name,
      kind: kind,
      folderId: folderId,
      editMode: editModeName,
      labels: labels,
    );
    // 保存后复位：下一次保存是全新工程，不会误覆盖
    activeCollectionId = '';
    _openedForEdit = false;
    labels = [];
    mode = AppMode.view;
    await refreshCollections();
    if (updating) {
      // 编辑已有工程：只有它本来就在显示列表里才刷新数据；
      // 用户之前主动隐藏的尊重选择，保持隐藏。
      if (visibleCids.contains(cid)) {
        overlayLabels[cid] = await store.loadCollection(cid);
      }
    } else {
      // 新建保存：默认自动在地图上显示。
      // （修复：此前新建工程的 cid 不可能在 visibleCids 里，
      // 保存后 overlayLabels 为空 → 用户看到的不是"自动隐藏"，而是"从未显示"。）
      if (!visibleCids.contains(cid)) visibleCids.add(cid);
      prefs.setString(prefVisible, visibleCids.join(','));
      overlayLabels[cid] = await store.loadCollection(cid);
    }
    notifyListeners();
    // 云同步：本地保存后触发（debounce 上传，架构文档 §4.5）。未接入时为 no-op。
    syncController?.onLocalSaved(cid);
    return cid;
  }

  bool _openedForEdit = false;

  /// 删除收藏工程（统一入口，含软删除同步通知）。
  ///
  /// 与直接调用 `store.deleteCollection` 相比，额外：清理可见集合、刷新列表、
  /// 通知同步器（服务端软删除 rev+1）。业务语义不变，仅集中收口。
  Future<void> deleteCollection(String cid) async {
    await store.deleteCollection(cid);
    visibleCids.remove(cid);
    overlayLabels.remove(cid);
    await refreshCollections();
    syncController?.onLocalDeleted(cid);
    notifyListeners();
  }

  // ================= 外部文件（拖入 / 命令行 / 文件关联）T21·T22 =================

  /// 处理「外部传入的文件」：按扩展名分派。返回**面向用户的中文结果**（多行）。
  ///
  /// - `.ovimap` → 导入工程文件并打开（[importProjectFile]）；
  /// - `.geojson`/`.json` → 导入本地开源矢量底图（复用 [BasemapFileImporter]）；
  /// - `.dxf` / `.csv` → 明确中文提示（暂不支持导入，不假装成功）；
  /// - 其它 → 不支持类型提示。
  Future<String> openExternalFiles(List<String> paths) async {
    final msgs = <String>[];
    for (final p in paths) {
      msgs.add(await _openExternalFile(p));
    }
    notifyListeners();
    return msgs.join('\n');
  }

  Future<String> _openExternalFile(String path) async {
    final norm = path.replaceAll('\\', '/');
    final i = norm.lastIndexOf('/');
    final name = i >= 0 ? norm.substring(i + 1) : norm;
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
    switch (ext) {
      case 'ovimap':
        return importProjectFile(path);
      case 'geojson':
      case 'json':
        try {
          final bm = await BasemapFileImporter.importFromPath(path,
              sourceName: name);
          return '已导入底图「$name」：道路 ${bm.roads.length} · '
              '建筑 ${bm.buildings.length} · 地名 ${bm.places.length}（项目级离线复用）';
        } on BasemapImportException catch (e) {
          return e.message;
        } catch (e) {
          return '导入底图失败「$name」：$e';
        }
      case 'dxf':
        return '「$name」：DXF 导入暂不支持，可用 CAD 打开该文件';
      case 'csv':
        return '「$name」：CSV 导入暂不支持（可在标注里粘贴坐标）';
      default:
        return '「$name」：不支持的文件类型（支持 .ovimap / .geojson / .json）';
    }
  }

  /// 导入 `.ovimap` 工程文件（= `collection_<id>.json` 原文，格式见 docs/BUILD-windows.md）。
  ///
  /// 总是**新建**一个工程（不覆盖同 id 的既有工程；重名自动追加 (2)/(3)…），
  /// 导入成功后**自动打开**。返回中文结果消息（失败不抛）。
  Future<String> importProjectFile(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return '工程文件不存在：$path';
      final raw = await f.readAsString();
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return '工程文件格式不正确（应为 JSON 对象）';
      final o = Map<String, dynamic>.from(decoded);
      final rawLabels = o['labels'];
      if (rawLabels is! List) return '工程文件缺少 labels 字段';
      final labels = <MapLabel>[];
      for (final e in rawLabels) {
        if (e is Map) {
          labels.add(MapLabel.fromJson(Map<String, dynamic>.from(e)));
        }
      }
      if (labels.isEmpty) return '工程文件没有点位';
      final baseName = (o['name'] as String?)?.trim() ?? '';
      final name = await _uniqueName(baseName.isEmpty ? '导入工程' : baseName);
      final kind = (o['kind'] as String?) ?? 'label';
      final folder =
          (o['folderId'] as String?) ?? (o['folder'] as String?) ?? '';
      final editMode = (o['editMode'] as String?) ?? 'design';
      final cid = await store.finishCollection(
        existingId: '',
        name: name,
        kind: kind,
        folderId: folder,
        editMode: editMode,
        labels: labels,
        clearDraftNow: false,
      );
      await refreshCollections();
      final meta = collections.firstWhere(
        (m) => m.id == cid,
        orElse: () => CollectionMeta(id: cid, name: name, kind: kind),
      );
      await openCollection(meta);
      return '已导入并打开工程「$name」（${labels.length} 点）';
    } catch (e) {
      return '导入工程失败：$e';
    }
  }

  /// 生成 `.ovimap` 工程文件（原文 = `collection_<cid>.json`），写入导出目录。
  ///
  /// 返回 [File]（供 [ExportSaver] 交付）；工程不存在 → `null`。
  Future<File?> buildProjectFile(String cid) async {
    final raw = await store.readCollectionRaw(cid);
    if (raw == null) return null;
    final nm = await store.loadCollectionName(cid);
    final dir = await store.exportDir();
    final f = File(
        '${dir.path}/${sanitizeName(nm.isEmpty ? '未命名工程' : nm)}.ovimap');
    await robustWriteAsString(f, raw);
    return f;
  }

  /// 把一个临时点直接保存为独立收藏工程（R4 搜索临时标记「加入收藏」用）。
  ///
  /// - 不进草稿、不打断当前编辑（草稿原样保留，撤销栈不受影响）；
  /// - 名字重名自动追加 (2)/(3)…（与手动保存同一规则）；
  /// - 保存后该收藏自动在地图上显示（与新建保存后的默认显示一致）。
  ///
  /// 返回新收藏的 id。[note] 可选，存点备注（搜索结果地址等）。
  Future<String> savePointAsCollection(String name, double lat, double lon,
      {String kind = 'label', String note = ''}) async {
    final clean = name.trim().isEmpty ? '收藏点' : name.trim();
    final finalName = await _uniqueName(clean);
    final pt = MapLabel(
      typeId: 'pipe', // 固定用 pin 类符号，保证地图上可见
      seq: 1,
      lat: lat,
      lon: lon,
      name: finalName,
    );
    if (note.trim().isNotEmpty) pt.note = note.trim();
    final cid = await store.finishCollection(
      existingId: '',
      name: finalName,
      kind: kind,
      folderId: '',
      editMode: 'design',
      labels: [pt],
      clearDraftNow: false, // 关键：不清草稿，不打断当前编辑
    );
    if (!visibleCids.contains(cid)) visibleCids.add(cid);
    prefs.setString(prefVisible, visibleCids.join(','));
    overlayLabels[cid] = await store.loadCollection(cid);
    await refreshCollections();
    notifyListeners();
    return cid;
  }

  /// 重名时自动追加 (2)、(3)…，返回不冲突的名称。
  Future<String> _uniqueName(String name) async {
    final items = await store.loadIndex();
    final names = {for (final m in items) m.name};
    if (!names.contains(name)) return name;
    var i = 2;
    while (names.contains('$name($i)')) {
      i++;
    }
    return '$name($i)';
  }

  /// 把来源工程里的箱体节点（光交/分光器箱/分纤盒/ONU箱/机房/基站/引上）
  /// 导入并合并进目标工程，导入后与目标工程一体。返回实际导入数量。
  /// [overwriteSame] 如果为 true，则当目标工程中存在同坐标同类型的点时，使用来源点的属性覆盖目标点的属性（不改变 id、seq、typeId、lat、lon、lineGroupId）。
  /// 如果为 false（默认），则跳过与目标工程中坐标和类型都相同的点。
  Future<int> importBoxesToCollection(
      String targetCid, String sourceCid, {
      bool overwriteSame = false,
  }) async {
    final target = await store.loadCollection(targetCid);
    final source = await store.loadCollection(sourceCid);
    final boxes = source
        .where((l) => l.type.isTopoLinkable)
        .map((e) => e.clone())
        .toList();
    if (boxes.isEmpty) return 0;

    final toAdd = _mergeBoxes(target, boxes, overwriteSame);

    final merged = [...target, ...toAdd];
    await store.saveCollectionLabels(targetCid, merged);
    await store.setCollectionCount(targetCid, merged.length);
    if (visibleCids.contains(targetCid)) {
      overlayLabels[targetCid] = await store.loadCollection(targetCid);
    }
    // 若目标工程正打开在编辑器中，同步刷新草稿
    if (activeCollectionId == targetCid) {
      labels = merged.map((e) => e.clone()).toList();
      await store.saveDraft(labels, projectName, folderId, editModeName);
    }
    await refreshCollections();
    notifyListeners();
    // 返回实际导入的数量（新增点的数量）
    return toAdd.length;
  }

  /// 把来源工程里的箱体节点导入当前正在编辑的草稿项目
  /// （相当于本项目直接增加箱体节点，草稿为空时也可导入，快速建项目）。
  /// 同坐标同类型的已有点按 [overwriteSame] 决定覆盖属性或跳过；
  /// 其余克隆加入 labels 并续 seq。返回实际新增数量。
  Future<int> importBoxesToDraft(String sourceCid,
      {bool overwriteSame = false}) async {
    final source = await store.loadCollection(sourceCid);
    final boxes = source
        .where((l) => l.type.isTopoLinkable)
        .map((e) => e.clone())
        .toList();
    if (boxes.isEmpty) return 0;

    pushUndoSnapshot();
    final toAdd = _mergeBoxes(labels, boxes, overwriteSame);
    if (toAdd.isNotEmpty) {
      labels.addAll(toAdd);
    }
    // 即使只发生属性覆盖（新增为 0），也要把草稿落盘
    _saveDraft();
    notifyListeners();
    return toAdd.length;
  }

  /// 把 KML 文本导入当前草稿（奥维式双向：吃进别人给的 KML）。
  /// 返回 null=解析失败/无有效要素；否则返回 "X 点 · Y 条线"。
  String? importKmlText(String xml) {
    final r = KmlImporter.parse(xml);
    if (r == null) return null;
    pushUndoSnapshot();
    final base = labels.length;
    for (var i = 0; i < r.labels.length; i++) {
      r.labels[i].seq = base + i + 1;
    }
    labels.addAll(r.labels);
    _saveDraft();
    notifyListeners();
    return '${r.pointCount} 点 · ${r.lineCount} 条线';
  }

  /// 公共合并逻辑：把来源箱体并入目标点列表。
  /// "同位置同类型"判定：同类型 + 距离 ≤5 米（GPS 两次打点不可能逐位相同，
  /// 旧的 6 位小数全等判定几乎永远不命中，会导致重复导入一堆重叠点）。
  /// 命中且 [overwriteSame] 时原地覆盖属性（不改变 id、seq、typeId、lat、lon、
  /// lineGroupId）；否则该目标点视为已存在、跳过；未命中的箱体克隆后续 seq 返回。
  List<MapLabel> _mergeBoxes(
      List<MapLabel> target, List<MapLabel> boxes, bool overwriteSame) {
    const samePosMeters = 5.0;
    final toAdd = <MapLabel>[];
    var updatedCount = 0;

    for (final box in boxes) {
      MapLabel? hit;
      for (final t in target) {
        if (t.typeId != box.typeId) continue;
        if (LocService.distanceM(t.lat, t.lon, box.lat, box.lon) <=
            samePosMeters) {
          hit = t;
          break;
        }
      }
      if (hit != null) {
        if (overwriteSame) {
          // 覆盖属性（不改变 id、seq、typeId、lat、lon、lineGroupId）
          hit.name = box.name;
          hit.note = box.note;
          hit.holes = box.holes;
          hit.usedHoles = box.usedHoles;
          hit.splitterRatio = box.splitterRatio;
          hit.cableSpec = box.cableSpec;
          hit.cableCores = box.cableCores;
          hit.distLabel = box.distLabel;
          hit.distanceM = box.distanceM;
          hit.segKind = box.segKind;
          hit.styleColor = box.styleColor;
          hit.styleWidth = box.styleWidth;
          // 注意：不覆盖 closedArea，因为箱体通常不设置此属性
          updatedCount++;
        }
        // 如果不覆盖，则跳过（不添加新点）
      } else {
        // 没有同位置同类型的点，准备添加新点
        toAdd.add(box);
      }
    }

    // 为新点分配 seq
    for (var i = 0; i < toAdd.length; i++) {
      toAdd[i].seq = target.length + updatedCount + i + 1;
    }
    return toAdd;
  }

  // ================= 测量 =================

  void addMeasurePoint(double dispLat, double dispLon) {
    final w = toWgs(dispLat, dispLon);
    measurePts.add(MapLabel(
      typeId: 'none',
      seq: measurePts.length + 1,
      lat: w[0],
      lon: w[1],
    ));
    notifyListeners();
  }

  void undoMeasure() {
    if (measurePts.isNotEmpty) {
      measurePts.removeLast();
      notifyListeners();
    }
  }

  double measureTotal() {
    var t = 0.0;
    for (var i = 1; i < measurePts.length; i++) {
      t += LocService.distanceM(measurePts[i - 1].lat, measurePts[i - 1].lon,
          measurePts[i].lat, measurePts[i].lon);
    }
    return t;
  }

  Future<void> saveMeasureAsCollection() async {
    if (measurePts.length < 2) return;
    final isArea = mode == AppMode.measureArea;
    await store.finishCollection(
      name: '测量-${DateTime.now().toIso8601String().substring(0, 16).replaceAll('T', ' ')}',
      kind: isArea ? LabelStore.kindData : LabelStore.kindLabel,
      folderId: '',
      editMode: editModeName,
      labels: measurePts,
    );
    measurePts = [];
    await refreshCollections();
    notifyListeners();
  }

  // ================= 轨迹记录 =================

  void startRecord() {
    recording = true;
    recordPaused = false;
    recordPts = [];
    recordDistance = 0;
    recordStartMs = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  void toggleRecordPause() {
    if (!hasFix) return;
    recordPaused = !recordPaused;
    notifyListeners();
  }

  /// 定位流回调喂入：按距离阈值追加点。
  void feedRecordPoint(double lat, double lon) {
    if (!recording || recordPaused) return;
    if (recordPts.isNotEmpty) {
      final last = recordPts.last;
      final d = LocService.distanceM(last.lat, last.lon, lat, lon);
      if (d < 1.5) return; // 抖动过滤
      recordDistance += d;
    }
    recordPts.add(MapLabel(
      typeId: 'track',
      seq: recordPts.length + 1,
      lat: lat,
      lon: lon,
    ));
    notifyListeners();
  }

  Future<String?> stopRecordAndSave() async {
    if (recordPts.length < 2) {
      recording = false;
      notifyListeners();
      return null;
    }
    final name =
        '轨迹-${DateTime.now().toIso8601String().substring(0, 16).replaceAll('T', ' ')}';
    // 轨迹点串成一条线组
    final gid = MapLabel().id;
    for (final p in recordPts) {
      p.lineGroupId = gid;
    }
    final cid = await store.finishCollection(
      name: name,
      kind: LabelStore.kindTrack,
      folderId: '',
      editMode: editModeName,
      labels: recordPts,
    );
    recording = false;
    recordPaused = false;
    recordPts = [];
    recordDistance = 0;
    await refreshCollections();
    notifyListeners();
    return cid;
  }

  // ================= 拓扑连线 =================

  Future<bool> startTopoLink(CollectionMeta meta) async {
    final ls = await store.loadCollection(meta.id);
    var hasBox = false;
    for (final l in ls) {
      if (l.type.isTopoLinkable) {
        hasBox = true;
        break;
      }
    }
    if (!hasBox) return false;
    topoCid = meta.id;
    topoColl = ls;
    topoSelId = null;
    topoUndoStack.clear();
    mode = AppMode.topoLink;
    notifyListeners();
    return true;
  }

  /// 拓扑模式下点击节点：返回提示信息（供界面提示）。
  String topoTap(MapLabel target) {
    if (!target.type.isTopoLinkable) return '';
    if (topoSelId == null) {
      topoSelId = target.id;
      notifyListeners();
      return '起点已选：${target.name.isNotEmpty ? target.name : target.type.name}，再点终点箱体';
    }
    if (topoSelId == target.id) {
      topoSelId = null;
      notifyListeners();
      return '已取消起点选择';
    }
    final src = topoColl.firstWhere((e) => e.id == topoSelId,
        orElse: () => MapLabel());
    topoUndoStack.add('${target.id}|${target.topoParentId}');
    target.topoParentId = topoSelId!;
    topoSelId = null;
    store.saveCollectionLabels(topoCid, topoColl);
    notifyListeners();
    return '已连接：${src.name.isNotEmpty ? src.name : src.type.name} → '
        '${target.name.isNotEmpty ? target.name : target.type.name}';
  }

  void undoTopoLink() {
    if (topoUndoStack.isEmpty) return;
    final rec = topoUndoStack.removeLast();
    final i = rec.indexOf('|');
    final id = rec.substring(0, i);
    final oldParent = rec.substring(i + 1);
    for (final l in topoColl) {
      if (l.id == id) {
        l.topoParentId = oldParent;
        break;
      }
    }
    store.saveCollectionLabels(topoCid, topoColl);
    notifyListeners();
  }

  void endTopoLink() {
    topoCid = '';
    topoColl = [];
    topoSelId = null;
    mode = AppMode.view;
    refreshCollections();
    notifyListeners();
  }

  // ================= 其它 =================

  void setCoordFmt(int f) {
    coordFmt = f % 3;
    prefs.setInt(prefFmt, coordFmt);
    notifyListeners();
  }

  void setCompassMode(bool v) {
    compassMode = v;
    prefs.setBool(prefCompass, v);
    notifyListeners();
  }

  void setFollow(bool v) {
    followUser = v;
    notifyListeners();
  }

  /// 供 UI 层显式触发重建（文件夹选择等轻量状态）。
  void refreshUi() => notifyListeners();
}
