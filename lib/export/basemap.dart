import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../models/map_label.dart';
import '../services/amap.dart';
import '../services/store.dart';
import '../services/tianditu.dart';
import 'overpass.dart';

// ===================== 数据模型 =====================

/// 道路等级（分级制图依据）。
enum RoadGrade { trunk, primary, secondary, tertiary, residential, service, other }

/// 地名级别（注记字号依据）。
enum PlaceLevel { city, suburb, neighbourhood, town, village, hamlet, residential }

/// 数据集抓取状态（失败三态）。
enum FetchState { ok, cached, failed }

/// 道路要素：`pts = [[lat, lon], ...]`（WGS84）。
class RoadPoly {
  final List<List<double>> pts;
  final RoadGrade grade;
  final String name;
  const RoadPoly(this.pts, this.grade, this.name);
}

/// 建筑要素：`rings[0]` 为外环，其余为孔（内环）。
/// 每个环为 `[[lat, lon], ...]`（WGS84）。**每个外环对应一个 [BuildingPoly]**。
class BuildingPoly {
  final List<List<List<double>>> rings;
  final String name;
  const BuildingPoly(this.rings, this.name);

  /// 外环（rings[0]）；无环时返回空列表。
  List<List<double>> get outer => rings.isEmpty ? const [] : rings.first;

  /// 孔（内环）列表（rings[1..]）。
  List<List<List<double>>> get holes =>
      rings.length <= 1 ? const [] : rings.sublist(1);
}

/// 地名要素（点；`place=*` 或具名 `landuse=residential`）。
class PlaceFeature {
  final String name;
  final double lat;
  final double lon;
  final PlaceLevel level;
  final bool isArea;
  final List<List<double>>? ring;
  const PlaceFeature({
    required this.name,
    required this.lat,
    required this.lon,
    required this.level,
    this.isArea = false,
    this.ring,
  });
}

/// 单个数据集的抓取结果。
class DatasetReport {
  final FetchState state;
  final String source;
  final String? error;
  final int count;

  /// **数据源本身返回了空集**（`"elements": []`）——区别于"该范围确实没有数据"。
  ///
  /// 背景（第二十批 P0）：存在返回 `elements: []` 的故障镜像（如 `overpass.osm.ch`，
  /// 数据库时间戳为非法值 "34"），它 200 且最快，会让上层以为"抓取成功、范围没数据"，
  /// 实为**镜像故障**。置位后 UI 明确提示"疑似底图镜像故障，建议重试"，
  /// 不再误导用户是自己的线路范围选小了。
  final bool emptyAnswer;

  const DatasetReport(
    this.state, {
    this.source = '',
    this.error,
    this.count = 0,
    this.emptyAnswer = false,
  });
}

/// 底图抓取三态汇总 + 中文可操作指引。
class BasemapFetchReport {
  final DatasetReport roads;
  final DatasetReport buildings;
  final DatasetReport places;

  /// 周边要素（电力/水系）报告；不传视为「未抓取」，不参与成败判定。
  final DatasetReport extras;
  const BasemapFetchReport({
    required this.roads,
    required this.buildings,
    required this.places,
    this.extras = const DatasetReport(FetchState.failed, error: '未抓取'),
  });

  bool get anyFailed =>
      roads.state == FetchState.failed ||
      buildings.state == FetchState.failed ||
      places.state == FetchState.failed;

  bool get allFailed =>
      roads.state == FetchState.failed &&
      buildings.state == FetchState.failed &&
      places.state == FetchState.failed;

  bool get anyCached =>
      roads.state == FetchState.cached ||
      buildings.state == FetchState.cached ||
      places.state == FetchState.cached;

  /// 单条数据集的提示行（`null` = 无提示）。
  ///
  /// **降噪（O2）**：`cached` 命中属正常路径（同一范围复用、可离线出图），
  /// 仅当本次确实发生了降级（[degraded] = 存在 failed 数据集），才把"来自本地缓存"
  /// 作为解释性信息给出；纯正常缓存命中（无失败）不再产生 warning、不弹提示。
  /// `cached` 且带 [DatasetReport.error]（联网失败后回退旧缓存）仍属降级，照常提示。
  static String? _line(DatasetReport r, String label, {required bool degraded}) {
    switch (r.state) {
      case FetchState.ok:
        if (r.count > 0) return null;
        // "成功但空"必须说清是**范围无数据**还是**数据源返回空/疑似故障**（P1）
        return r.emptyAnswer
            ? '底图$label：数据源返回空（疑似底图镜像故障），请点「刷新底图」重试'
            : '底图$label：本次该范围内无$label';
      case FetchState.cached:
        if (!degraded && r.error == null) return null; // 正常缓存命中：降噪，不提示
        final base = '底图$label：使用本地缓存（可离线复用），${r.count} 项';
        return r.error == null ? base : '$base；本次联网失败：${r.error}';
      case FetchState.failed:
        return '底图$label：未获取（${r.error ?? '网络不可达且无本地缓存'}），'
            '本次图面缺$label';
    }
  }

  /// 一行汇总（导出前给用户的"抓到了什么"）：
  /// `道路 128 项 / 建筑 96 项 / 地名 12 项`。
  String get summaryLine =>
      '道路 ${roads.count} 项 / 建筑 ${buildings.count} 项 / 地名 ${places.count} 项';

  /// 道路或建筑任一有数据（DXF 矢量底图"有东西"的判据）。
  bool get hasVector => roads.count > 0 || buildings.count > 0;

  /// 存在"数据源返回空集"（疑似底图镜像故障）——UI 据此给出重试建议，
  /// 而不是让用户以为"这条线路周围真的没路没房"。
  bool get anyEmptyAnswer =>
      roads.emptyAnswer || buildings.emptyAnswer || places.emptyAnswer;

  /// 逐数据集状态行（含失败原因），供 DXF 导出选项对话框直接展示。
  ///
  /// 与 [toWarnings] 的区别：这里**无条件**给出三行（正常路径也展示），
  /// 便于用户在导出前确认"这次到底抓到了什么"，而不是导出后才发现是空的。
  List<String> statusLines() =>
      [_statusLine(roads, '道路'), _statusLine(buildings, '建筑'), _statusLine(places, '地名')];

  static String _statusLine(DatasetReport r, String label) {
    final reason = (r.error == null || r.error!.isEmpty)
        ? '网络不可达且无本地缓存'
        : r.error!;
    switch (r.state) {
      case FetchState.ok:
        if (r.count > 0) return '$label ${r.count} 项';
        // P1 语义修正：count=0 必须区分"范围没数据"与"数据源返回空（疑似镜像故障）"
        return r.emptyAnswer
            ? '$label 0 项（数据源返回空，疑似底图镜像故障，请点「重试抓取」）'
            : '$label 0 项（该范围内无数据）';
      case FetchState.cached:
        final base = '$label ${r.count} 项（本地缓存）';
        return r.error == null ? base : '$base；本次联网失败：$reason';
      case FetchState.failed:
        return '$label 未获取（$reason）';
    }
  }

  /// 结构化中文指引（供对话框展示；正常路径返回空列表 → 不弹提示）。
  ///
  /// 仅当存在失败（真正降级：部分失败/失败）时，才输出含"缓存解释"在内的完整三态说明；
  /// 全部 ok/cached 的正常路径不产生任何 warning（O2 降噪）。
  List<String> toWarnings() {
    final out = <String>[];
    final degraded = anyFailed;
    final l1 = _line(roads, '道路矢量', degraded: degraded);
    final l2 = _line(buildings, '建筑轮廓', degraded: degraded);
    final l3 = _line(places, '地名', degraded: degraded);
    if (l1 != null) out.add(l1);
    if (l2 != null) out.add(l2);
    if (l3 != null) out.add(l3);
    if (anyFailed) {
      out.add('提示：可先联网后点「刷新底图」重试；已成功的部分会自动长期缓存。');
    }
    return out;
  }
}

/// 底图数据集（道路 + 建筑 + 地名 + 报告）。
/// 周边要素（第二十八批新增）：电力线 / 水系沟渠。
///
/// 通信线路设计必须与**电力杆线**的相对关系一起看（交越、平行间距），
/// 过河过沟也要有参照——OSM 里这两类覆盖比建筑好得多，加上它们能显著
/// 缓解"导出的矢量数据太少"。
class ExtraPoly {
  final List<List<double>> pts;
  final String kind; // 'power' | 'water'
  final String name;
  const ExtraPoly(this.pts, this.kind, this.name);
}

class BasemapData {
  final List<RoadPoly> roads;
  final List<BuildingPoly> buildings;
  final List<PlaceFeature> places;

  /// 周边要素（电力线 / 水系）；老代码不传即为空，行为不变。
  final List<ExtraPoly> extras;
  final BasemapFetchReport report;
  const BasemapData({
    required this.roads,
    required this.buildings,
    required this.places,
    this.extras = const [],
    required this.report,
  });

  /// 空底图（未抓取）。
  static BasemapData empty() => const BasemapData(
        roads: [],
        buildings: [],
        places: [],
        extras: [],
        report: BasemapFetchReport(
          roads: DatasetReport(FetchState.failed, error: '未抓取底图'),
          buildings: DatasetReport(FetchState.failed, error: '未抓取底图'),
          places: DatasetReport(FetchState.failed, error: '未抓取底图'),
        ),
      );
}

// ===================== 项目级缓存 =====================

/// 项目级底图缓存：一次抓取、跨草稿/跨次长期复用（离线可出图）。
///
/// 目录：`${labelsDir}/basemap/`（`roads/ buildings/ places/` + `index.json`）。
/// 命中：请求 bbox **被某条已缓存 bbox 包含**且 `age < [defaultMaxAgeDays]`（近乎永久）
/// （或 [read] 指定上限）。
class BasemapCache {
  /// 缓存根目录。
  final Directory root;

  BasemapCache(this.root);

  /// 打开默认缓存目录（`LabelStore.basemapDir()`）。
  static Future<BasemapCache> open() async {
    final d = await LabelStore.instance.basemapDir();
    return BasemapCache(d);
  }

  /// 默认有效期：**项目级、近乎永久复用**（100 年），不随 7 天过期。
  /// 一次抓取后长期离线可出图；仅「刷新底图」才主动失效。
  static const int defaultMaxAgeDays = 36500;

  File get _indexFile => File('${root.path}/index.json');

  Directory _kindDir(String kind) {
    final d = Directory('${root.path}/$kind');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  List<Map<String, dynamic>> _loadIndex() {
    try {
      if (!_indexFile.existsSync()) return [];
      final s = _indexFile.readAsStringSync().trim();
      if (s.isEmpty) return [];
      final decoded = jsonDecode(s);
      if (decoded is List) {
        return decoded
            .cast<Map<String, dynamic>>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (_) {}
    return [];
  }

  void _saveIndex(List<Map<String, dynamic>> items) {
    try {
      if (!root.existsSync()) root.createSync(recursive: true);
      _indexFile.writeAsStringSync(jsonEncode(items), flush: true);
    } catch (_) {}
  }

  /// 稳定缓存键：FNV-1a 64bit（无需 crypto 依赖）。
  static String fnv1a(String s) {
    var hash = 0xcbf29ce484222325;
    for (final c in utf8.encode(s)) {
      hash ^= c;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static String _keyOf(String kind, List<double> bbox) {
    final q = bbox.map((v) => (v * 10000).round()).join('_');
    return fnv1a('$kind|$q');
  }

  static bool _covers(List<double> a, List<double> b) =>
      a[0] <= b[0] + 1e-9 &&
      a[1] <= b[1] + 1e-9 &&
      a[2] >= b[2] - 1e-9 &&
      a[3] >= b[3] - 1e-9;

  /// 命中复用：返回被缓存覆盖的 JSON 原文；未命中返回 null。
  Future<String?> read(
    String kind,
    List<double> bbox, {
    int maxAgeDays = defaultMaxAgeDays,
  }) async {
    final now = DateTime.now();
    for (final e in _loadIndex()) {
      if ((e['dataset'] as String?) != kind) continue;
      final minLat = (e['minLat'] as num?)?.toDouble();
      final minLon = (e['minLon'] as num?)?.toDouble();
      final maxLat = (e['maxLat'] as num?)?.toDouble();
      final maxLon = (e['maxLon'] as num?)?.toDouble();
      if (minLat == null || minLon == null || maxLat == null || maxLon == null) {
        continue;
      }
      if (!_covers([minLat, minLon, maxLat, maxLon], bbox)) continue;
      final savedAt = (e['savedAt'] as num?)?.toInt() ?? 0;
      if (savedAt > 0) {
        final age = now.difference(DateTime.fromMillisecondsSinceEpoch(savedAt));
        if (age.inDays > maxAgeDays) continue;
      }
      final file = (e['file'] as String?) ?? '';
      if (file.isEmpty) continue;
      final f = File('${_kindDir(kind).path}/$file');
      if (!f.existsSync()) continue;
      try {
        return f.readAsStringSync();
      } catch (_) {}
    }
    return null;
  }

  /// 写入数据集原文，并更新索引。
  Future<void> write(String kind, List<double> bbox, String json) async {
    final key = _keyOf(kind, bbox);
    final fileName = '$key.json';
    final dir = _kindDir(kind);
    final f = File('${dir.path}/$fileName');
    try {
      f.writeAsStringSync(json, flush: true);
    } catch (_) {
      return;
    }
    final items = _loadIndex();
    items.removeWhere(
        (e) => (e['dataset'] as String?) == kind && (e['file'] as String?) == fileName);
    items.add({
      'dataset': kind,
      'minLat': bbox[0],
      'minLon': bbox[1],
      'maxLat': bbox[2],
      'maxLon': bbox[3],
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'file': fileName,
    });
    _saveIndex(items);
  }

  /// 刷新底图：删除覆盖该 bbox 的全部条目与文件。
  Future<void> invalidate(List<double> bbox) async {
    final items = _loadIndex();
    final kept = <Map<String, dynamic>>[];
    for (final e in items) {
      final minLat = (e['minLat'] as num?)?.toDouble();
      final minLon = (e['minLon'] as num?)?.toDouble();
      final maxLat = (e['maxLat'] as num?)?.toDouble();
      final maxLon = (e['maxLon'] as num?)?.toDouble();
      if (minLat == null || minLon == null || maxLat == null || maxLon == null) {
        continue;
      }
      if (_covers([minLat, minLon, maxLat, maxLon], bbox)) {
        final kind = (e['dataset'] as String?) ?? '';
        final file = (e['file'] as String?) ?? '';
        if (kind.isNotEmpty && file.isNotEmpty) {
          try {
            final f = File('${root.path}/$kind/$file');
            if (f.existsSync()) f.deleteSync();
          } catch (_) {}
        }
        continue;
      }
      kept.add(e);
    }
    _saveIndex(kept);
  }
}

// ===================== 抓取编排 =====================

/// 泛型抓取结果（内部用）。
class _LoadResult<T> {
  final DatasetReport report;
  final List<T> items;
  _LoadResult(this.report, this.items);
}

/// 底图抓取编排：缓存优先 → Overpass 竞速（仅未命中/刷新时）→ 失败乐观降级到旧缓存。
class BasemapFetcher {
  BasemapFetcher._();

  /// 天地图兜底关键词枚举（OSM 地名为空或过少时）。
  static const List<String> tdtKeywords = ['小区', '村', '社区', '花园', '苑'];

  /// 按线路范围计算外扩 bbox `[minLat, minLon, maxLat, maxLon]`（±[rangeM] 米，纬度自适应）。
  static List<double> boundsOf(List<MapLabel> labels, double rangeM) {
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final l in labels) {
      if (l.lat < minLat) minLat = l.lat;
      if (l.lat > maxLat) maxLat = l.lat;
      if (l.lon < minLon) minLon = l.lon;
      if (l.lon > maxLon) maxLon = l.lon;
    }
    final midLat = (minLat + maxLat) / 2;
    final cosLat = math.cos(midLat * math.pi / 180).abs().clamp(0.05, 1.0);
    final padLat = rangeM / 110540.0;
    final padLon = rangeM / (111320.0 * cosLat);
    return [minLat - padLat, minLon - padLon, maxLat + padLat, maxLon + padLon];
  }

  /// 抓取底图（幂等、可离线复用）。

  /// 道路按 bbox **几何截断**：把折线切成落在框内的若干连续段，跨边界处用
  /// 插值交点收口（不过度外溢）。
  ///
  /// 为什么必须这样：旧实现"任一点在框内就保留整条"，于是横穿县城的国道
  /// 只要蹭到 100m 范围就被整条（可达数十公里）写进 DXF——用户反馈
  /// "导出的矢量图路超级长"。现在只留线路附近那一段。
  /// **点到线路的最短距离（米）**——沿线路缓冲裁剪的基础。
  ///
  /// 为什么不用矩形包围盒：线路常是 L 形/斜向/折返的，包围盒会把离线路很远的
  /// 角落也框进来（用户反馈"导出的矢量还是太广"）。做线路设计要的是
  /// **沿轨迹附近 N 米**，所以按到折线的距离判定。
  static double distToRouteM(List<MapLabel> labels, double lat, double lon) {
    final segs = _routeSegments(labels);
    if (segs.isEmpty) return 0;
    var best = double.infinity;
    for (final seg in segs) {
      final d = _distToSegM(lat, lon, seg[0], seg[1], seg[2], seg[3]);
      if (d < best) best = d;
    }
    return best;
  }

  /// 把点按线组串成折线段 `[lat1, lon1, lat2, lon2]`（同组按 seq；无组则整条）。
  static List<List<double>> _routeSegments(List<MapLabel> labels) {
    final groups = <String, List<MapLabel>>{};
    for (final l in labels) {
      groups.putIfAbsent(l.lineGroupId, () => <MapLabel>[]).add(l);
    }
    final out = <List<double>>[];
    for (final g in groups.values) {
      final pts = List<MapLabel>.from(g)
        ..sort((a, b) => a.seq.compareTo(b.seq));
      for (var i = 1; i < pts.length; i++) {
        out.add([pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon]);
      }
    }
    return out;
  }

  /// 点到线段的最短距离（米，局部平面近似，50m~1km 量级足够准）。
  static double _distToSegM(double lat, double lon, double aLat, double aLon,
      double bLat, double bLon) {
    final cosLat = math.cos(lat * math.pi / 180).abs().clamp(0.05, 1.0);
    final ax = (aLon - lon) * 111320.0 * cosLat;
    final ay = (aLat - lat) * 110540.0;
    final bx = (bLon - lon) * 111320.0 * cosLat;
    final by = (bLat - lat) * 110540.0;
    final dx = bx - ax, dy = by - ay;
    final l2 = dx * dx + dy * dy;
    double t = 0;
    if (l2 > 0) t = ((-ax) * dx + (-ay) * dy) / l2;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    final px = ax + dx * t, py = ay + dy * t;
    return math.sqrt(px * px + py * py);
  }

  /// 周边要素（电力/水系）按**沿线路缓冲**裁剪，与道路同口径。
  static List<ExtraPoly> cropExtrasToRoute(
      List<ExtraPoly> items, List<MapLabel> labels, double rangeM) {
    bool inside(double la, double lo) => distToRouteM(labels, la, lo) <= rangeM;
    final out = <ExtraPoly>[];
    for (final e in items) {
      var cur = <List<double>>[];
      for (var i = 0; i < e.pts.length; i++) {
        final p = e.pts[i];
        if (inside(p[0], p[1])) {
          if (cur.isEmpty && i > 0) {
            final q = e.pts[i - 1];
            cur.add(_clipSegWith(q[0], q[1], p[0], p[1], inside) ?? p);
          }
          cur.add(p);
        } else if (cur.isNotEmpty) {
          final q = e.pts[i - 1];
          cur.add(_clipSegWith(q[0], q[1], p[0], p[1], inside) ?? q);
          if (cur.length >= 2) out.add(ExtraPoly(cur, e.kind, e.name));
          cur = <List<double>>[];
        }
      }
      if (cur.length >= 2) out.add(ExtraPoly(cur, e.kind, e.name));
    }
    return out;
  }

  /// 道路按**到线路的距离**裁剪（缓冲带），保留落到带内的连续段，边界插值收口。
  static List<RoadPoly> cropRoadsToRoute(
      List<RoadPoly> items, List<MapLabel> labels, double rangeM) {
    bool inside(double la, double lo) => distToRouteM(labels, la, lo) <= rangeM;
    final out = <RoadPoly>[];
    for (final r in items) {
      var cur = <List<double>>[];
      for (var i = 0; i < r.pts.length; i++) {
        final p = r.pts[i];
        if (inside(p[0], p[1])) {
          if (cur.isEmpty && i > 0) {
            final q = r.pts[i - 1];
            cur.add(_clipSegWith(q[0], q[1], p[0], p[1], inside) ?? p);
          }
          cur.add(p);
        } else if (cur.isNotEmpty) {
          final q = r.pts[i - 1];
          cur.add(_clipSegWith(q[0], q[1], p[0], p[1], inside) ?? q);
          if (cur.length >= 2) out.add(RoadPoly(cur, r.grade, r.name));
          cur = <List<double>>[];
        }
      }
      if (cur.length >= 2) out.add(RoadPoly(cur, r.grade, r.name));
    }
    return out;
  }

  /// 段与「inside 区域」的交点（两端须分处内外），二分逼近。
  static List<double>? _clipSegWith(double aLat, double aLon, double bLat,
      double bLon, bool Function(double, double) inside) {
    final inA = inside(aLat, aLon);
    final inB = inside(bLat, bLon);
    if (inA == inB) return null;
    var xLat = aLat, xLon = aLon, yLat = bLat, yLon = bLon;
    if (inA) {
      xLat = bLat; xLon = bLon; yLat = aLat; yLon = aLon;
    }
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 20; i++) {
      final t = (lo + hi) / 2;
      if (inside(xLat + (yLat - xLat) * t, xLon + (yLon - xLon) * t)) {
        hi = t;
      } else {
        lo = t;
      }
    }
    return [xLat + (yLat - xLat) * hi, xLon + (yLon - xLon) * hi];
  }

  static List<RoadPoly> cropRoadsToBbox(List<RoadPoly> items, List<double> bbox) {
    final out = <RoadPoly>[];
    for (final r in items) {
      var cur = <List<double>>[];
      for (var i = 0; i < r.pts.length; i++) {
        final p = r.pts[i];
        if (_inBbox(p[0], p[1], bbox)) {
          if (cur.isEmpty && i > 0) {
            final q = r.pts[i - 1];
            cur.add(clipSegToBbox(q[0], q[1], p[0], p[1], bbox) ?? p);
          }
          cur.add(p);
        } else if (cur.isNotEmpty) {
          final q = r.pts[i - 1];
          cur.add(clipSegToBbox(q[0], q[1], p[0], p[1], bbox) ?? q);
          if (cur.length >= 2) out.add(RoadPoly(cur, r.grade, r.name));
          cur = <List<double>>[];
        }
      }
      if (cur.length >= 2) out.add(RoadPoly(cur, r.grade, r.name));
    }
    return out;
  }

  /// 线段 (aLat,aLon)-(bLat,bLon) 与 bbox 的边界交点（两端须分处框内外），
  /// 二分逼近。方向自适应：无论"入框"还是"出框"都能取到边界点。
  static List<double>? clipSegToBbox(
      double aLat, double aLon, double bLat, double bLon, List<double> bbox) {
    final inA = _inBbox(aLat, aLon, bbox);
    final inB = _inBbox(bLat, bLon, bbox);
    if (inA == inB) return null; // 同侧：无边界交点（调用方已按进出分好情况）
    // 统一为「x 在框外 → y 在框内」，二分求最后一个框外点之后的边界。
    var xLat = aLat, xLon = aLon, yLat = bLat, yLon = bLon;
    if (inA) {
      xLat = bLat; xLon = bLon; yLat = aLat; yLon = aLon;
    }
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 20; i++) {
      final t = (lo + hi) / 2;
      if (_inBbox(xLat + (yLat - xLat) * t, xLon + (yLon - xLon) * t, bbox)) {
        hi = t;
      } else {
        lo = t;
      }
    }
    return [xLat + (yLat - xLat) * hi, xLon + (yLon - xLon) * hi];
  }

  static Future<BasemapData> fetchFor(
    List<MapLabel> labels, {
    double rangeM = 50,
    String tdtKey = '',
    String amapKey = '',
    String overpassEndpoints = '', // 用户自定义 Overpass 端点原文（多分隔符；空=用内置）
    bool useTdt = true,
    bool convertGcj = true, // 高德/天地图检索 POI 为 GCJ-02，默认纠偏为 WGS84
    bool refresh = false,
    bool includeExtras = true, // 电力线 / 水系（导出面板可关）
    BasemapCache? cache,
  }) async {
    if (labels.isEmpty) return BasemapData.empty();
    final bbox = boundsOf(labels, rangeM);
    final bboxStr = '${bbox[0]},${bbox[1]},${bbox[2]},${bbox[3]}';
    final c = cache ?? await BasemapCache.open();

    // Overpass 端点：用户自定义优先、内置兜底（未配置时等价 builtin()，行为不变）。
    final overpassEps = OverpassEndpoints.resolve(overpassEndpoints);

    final roadsF = _load<RoadPoly>(
      kind: 'roads',
      query: OverpassClient.buildRoadsQuery(bboxStr),
      bbox: bbox,
      cache: c,
      refresh: refresh,
      endpoints: overpassEps,
      parse: OverpassClient.parseRoads,
      // ⚠️ 关键修复（v3.9.2）：道路必须**沿边界几何截断**，不是"点中即保留整条"。
      // 沿线路缓冲裁剪（不是矩形包围盒）：只留轨迹附近 rangeM 米内的路。
      crop: (items) => cropRoadsToRoute(items, labels, rangeM),
    );
    final bldF = _load<BuildingPoly>(
      kind: 'buildings',
      query: OverpassClient.buildBuildingsQuery(bboxStr),
      bbox: bbox,
      cache: c,
      refresh: refresh,
      endpoints: overpassEps,
      parse: OverpassClient.parseBuildings,
      crop: (items) => items
          .where((b) => b.outer.any(
              (p) => distToRouteM(labels, p[0], p[1]) <= rangeM))
          .toList(),
    );
    final plcF = _load<PlaceFeature>(
      kind: 'places',
      query: OverpassClient.buildPlacesQuery(bboxStr),
      bbox: bbox,
      cache: c,
      refresh: refresh,
      endpoints: overpassEps,
      parse: OverpassClient.parsePlaces,
      crop: (items) => items
          .where((p) => distToRouteM(labels, p.lat, p.lon) <= rangeM)
          .toList(),
    );

    final extrasF = includeExtras
        ? _load<ExtraPoly>(
            kind: 'extras',
            query: OverpassClient.buildExtrasQuery(bboxStr),
            bbox: bbox,
            cache: c,
            refresh: refresh,
            endpoints: overpassEps,
            parse: OverpassClient.parseExtras,
            crop: (items) => cropExtrasToRoute(items, labels, rangeM),
          )
        : Future.value(_LoadResult<ExtraPoly>(
            const DatasetReport(FetchState.failed, error: '未开启'),
            const [],
          ));

    final roads = await roadsF;
    final buildings = await bldF;
    var places = await plcF;
    final extras = await extrasF;

    var placesReport = places.report;
    // 地名兜底：OSM 地名过少时按关键词枚举补名（仅补点/地名，不参与几何）。
    // **优先级（第二十批）**：高德（已配 key）> 天地图（已配 key）——
    // 高德 POI 覆盖与准确率更好；高德取不到（未配 key / 失败 / 无结果）
    // 才回落天地图，未配高德 key 时行为与第十九批完全一致。
    // [useTdt] 为导出对话框的「地名兜底」总开关：关掉则两源都不兜底（与旧版一致）。
    if (useTdt && places.items.length < 3) {
      final extra = <PlaceFeature>[];
      String suffix = '';
      if (amapKey.isNotEmpty) {
        extra.addAll(await _poiByKeywords(
            bbox, (kw) => AmapClient.poiInBounds(bbox, kw, amapKey,
                convertGcj: convertGcj)));
        if (extra.isNotEmpty) suffix = '+amap';
      }
      if (extra.isEmpty && useTdt && tdtKey.isNotEmpty) {
        extra.addAll(await _poiByKeywords(bbox,
            (kw) => TiandituClient.poiInBounds(bbox, kw, tdtKey,
                convertGcj: convertGcj)));
        if (extra.isNotEmpty) suffix = '+tdt';
      }
      final merged = _mergePlaces(places.items, extra);
      if (merged.length > places.items.length) {
        places = _LoadResult(
          DatasetReport(
            placesReport.state == FetchState.failed
                ? FetchState.ok
                : placesReport.state,
            source: '${placesReport.source}$suffix',
            error: placesReport.error,
            count: merged.length,
          ),
          merged,
        );
        placesReport = places.report;
      }
    }

    // **使用层兜底裁剪（关键，双重防线之 2）**：不论地名来自 OSM 缓存 / 网络 /
    // 天地图 / 高德兜底，出口统一按本次 bbox 再裁一次。即使命中"污染期"写入的
    // 旧地名缓存（项目级近乎永久），也不会把范围外的地名带进 DXF
    // （用户复现的"矢量图外侧很远处密密麻麻的名字"）。count 同步修正，口径一致。
    // 出口再按**沿线路缓冲**兜底裁一次（含容差），矩形包围盒不再作为最终口径。
    final finalPlaces = cropPlacesToRoute(
        places.items, labels, rangeM + placeCropTolM);
    if (finalPlaces.length != places.items.length) {
      places = _LoadResult(
        DatasetReport(
          placesReport.state,
          source: placesReport.source,
          error: placesReport.error,
          count: finalPlaces.length,
          emptyAnswer: placesReport.emptyAnswer,
        ),
        finalPlaces,
      );
      placesReport = places.report;
    }

    return BasemapData(
      roads: roads.items,
      buildings: buildings.items,
      extras: extras.items,
      places: places.items,
      report: BasemapFetchReport(
        roads: roads.report,
        buildings: buildings.report,
        places: placesReport,
        extras: extras.report,
      ),
    );
  }

  /// 按 [tdtKeywords] 枚举取 POI；单个关键词失败不影响其它关键词。
  ///
  /// **范围硬裁剪（关键修复）**：天地图 v2/search 的 `mapBound` **不是硬过滤**
  /// （实测信阳小范围搜「小区」8 条有 5 条落在几十公里外的息县/光山/罗山/潢川/商城），
  /// 高德 polygon 虽严格限范围但同走一遍裁剪更稳妥。故对**每个关键词的每条返回**
  /// 都按本次导出 [bbox]（含 [placeCropTolM] 容差）过滤，绝不把范围外的地名
  /// 塞进 DXF（用户复现的「矢量图外侧很远处密密麻麻的名字」根因）。
  static Future<List<PlaceFeature>> _poiByKeywords(List<double> bbox,
      Future<List<SearchResult>> Function(String kw) query) async {
    final extra = <PlaceFeature>[];
    for (final kw in tdtKeywords) {
      try {
        final res = await query(kw);
        for (final r in res) {
          if (!_inBboxTol(r.lat, r.lon, bbox, placeCropTolM)) continue;
          extra.add(PlaceFeature(
            name: r.name,
            lat: r.lat,
            lon: r.lon,
            level: PlaceLevel.residential,
          ));
        }
      } catch (_) {
        // 单个关键词失败不影响其它关键词
      }
    }
    return extra;
  }

  static Future<_LoadResult<T>> _load<T>({
    required String kind,
    required String query,
    required List<double> bbox,
    required BasemapCache cache,
    required bool refresh,
    required List<String> endpoints,
    required List<T> Function(String json) parse,
    required List<T> Function(List<T> items) crop,
  }) async {
    if (!refresh) {
      final cached = await cache.read(kind, bbox);
      if (cached != null) {
        try {
          final items = crop(parse(cached));
          return _LoadResult(
            DatasetReport(FetchState.cached,
                source: 'cache', count: items.length),
            items,
          );
        } catch (_) {}
      }
    }
    try {
      // 端点列表：用户自定义优先、内置兜底（[BasemapFetcher.fetchFor] 已由
      // [OverpassEndpoints.resolve] 解析好）；空答案闸门/重试/竞速语义均不变。
      final got =
          await OverpassClient.fetchRawDetailed(query, endpoints: endpoints);
      final raw = got.body;
      final items = crop(parse(raw));
      // **空结果不落缓存**（第二十批关键修复）：
      // 镜像偶发返回 200 但 `elements` 为空（数据滞后/限流/区域未覆盖），若把空结果
      // 写进"近乎永久"的项目级缓存，后续导出会一直复用这份空底图——这正是
      // "建筑/道路怎么都导不出来"的隐形元凶。空结果不写盘，下次导出自动重抓。
      if (items.isNotEmpty) {
        await cache.write(kind, bbox, raw);
      }
      return _LoadResult(
        DatasetReport(
          FetchState.ok,
          source: 'overpass',
          count: items.length,
          // 所有端点都返回空集（非"范围无数据"）→ 标记，UI 提示疑似镜像故障
          emptyAnswer: got.emptyFallback && items.isEmpty,
        ),
        items,
      );
    } catch (e) {
      // 乐观降级：联网失败时用更旧的缓存（离线可出图）。
      final cached =
          await cache.read(kind, bbox, maxAgeDays: 3650);
      if (cached != null) {
        try {
          final items = crop(parse(cached));
          return _LoadResult(
            DatasetReport(FetchState.cached,
                source: 'cache(offline)', error: '$e', count: items.length),
            items,
          );
        } catch (_) {}
      }
      return _LoadResult(
        DatasetReport(FetchState.failed,
            source: 'overpass', error: '$e', count: 0),
        <T>[],
      );
    }
  }

  static 
bool _inBbox(double lat, double lon, List<double> bbox) =>
      lat >= bbox[0] && lat <= bbox[2] && lon >= bbox[1] && lon <= bbox[3];

  /// 地名裁剪容差（米）。
  ///
  /// 裁剪比较发生在**纠偏之后**——`TiandituClient` / `AmapClient` 出口已把 POI 从
  /// GCJ-02 纠偏为 **WGS-84** 才装入 `SearchResult.lat/lon`，故 `_inBboxTol` 拿到的是
  /// WGS-84 与 WGS-84 bbox 的**同系比较**（纠偏器残差为米级）。本容差仅作
  /// **边界/量化余量**（避免恰在 bbox 线上、浮点量化后的正常 POI 被误杀）。
  /// 用户复现的「几十公里外」地名与线路相距 3~4 个数量级，必被剔除
  /// （如信阳 bbox 外的息县/光山/罗山/潢川/商城，直线 20~80km）。
  static const double placeCropTolM = 100.0;

  /// 带容差的范围判定（WGS84）。
  ///
  /// 经度方向按中心纬度做 cos 修正（与 [boundsOf] 同口径），保证 [tolM] 容差
  /// 在地理意义上各方向近似等距。
  static bool _inBboxTol(
      double lat, double lon, List<double> bbox, double tolM) {
    final midLat = (bbox[0] + bbox[2]) / 2;
    final cosLat = math.cos(midLat * math.pi / 180).abs().clamp(0.05, 1.0);
    final dLat = tolM / 110540.0;
    final dLon = tolM / (111320.0 * cosLat);
    return lat >= bbox[0] - dLat &&
        lat <= bbox[2] + dLat &&
        lon >= bbox[1] - dLon &&
        lon <= bbox[3] + dLon;
  }

  /// 按 [bbox]（含 [placeCropTolM] 容差）裁剪地名列表（**纯函数**，供各来源统一调用）。
  ///
  /// 用于「使用层兜底」：无论地名来自 OSM 缓存 / 网络 / 天地图 / 高德兜底，
  /// 出口再裁一次，确保即使命中污染期写入的旧缓存，范围外的地名也不进 DXF。
  static List<PlaceFeature> cropPlaces(
          List<PlaceFeature> places, List<double> bbox) =>
      places
          .where((p) => _inBboxTol(p.lat, p.lon, bbox, placeCropTolM))
          .toList();

  /// 按**沿线路缓冲**（米）裁剪地名（纯函数，出口兜底用）。
  static List<PlaceFeature> cropPlacesToRoute(
          List<PlaceFeature> places, List<MapLabel> labels, double rangeM) =>
      places
          .where((p) => distToRouteM(labels, p.lat, p.lon) <= rangeM)
          .toList();

  /// 合并 OSM 与天地图地名，按「名称相同 + 50m 内」去重（OSM 优先）。
  static List<PlaceFeature> _mergePlaces(
      List<PlaceFeature> osm, List<PlaceFeature> extra) {
    final out = List<PlaceFeature>.from(osm);
    for (final p in extra) {
      var dup = false;
      for (final q in out) {
        if (q.name == p.name && _haversineM(p.lat, p.lon, q.lat, q.lon) < 50) {
          dup = true;
          break;
        }
      }
      if (!dup) out.add(p);
    }
    return out;
  }

  static double _haversineM(double la1, double lo1, double la2, double lo2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(la2 - la1);
    final dLon = rad(lo2 - lo1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(la1)) *
            math.cos(rad(la2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}
