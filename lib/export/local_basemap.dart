import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../services/store.dart';
import 'basemap.dart';
import 'overpass.dart';

/// 本地开源矢量底图：把用户自行下载的开源数据（GeoJSON / OSM XML）解析成
/// 与在线抓取同构的 [BasemapData]，从而**在无网环境也能出带底图的图**。
///
/// 映射约定（GeoJSON 坐标顺序为 `[lon, lat]`，本仓库内部统一 `[lat, lon]`）：
/// - `Polygon` / `MultiPolygon` → 建筑 [BuildingPoly]（外环为 rings[0]，其余为孔）；
/// - `LineString` / `MultiLineString` → 道路 [RoadPoly]（按 `highway` 标签分级）；
/// - `Point` / `MultiPoint` → 地名 [PlaceFeature]（按 `place` 标签分级别）；
/// - `properties.name` 作名称；`highway` 映射道路等级；`place`/`landuse=residential`
///   映射地名级别。其它几何类型（如 GeometryCollection）递归展开，无法映射者忽略。
///
/// **回答「难道没有开源的矢量数据」**：有。用户可用 Overpass/Geofabrik 等下载
/// 目标区域的 GeoJSON，导入后本项目**长期离线复用**（见 [LocalBasemapStore]）。
class GeoJsonImporter {
  GeoJsonImporter._();

  /// 解析 GeoJSON 文本 → [BasemapData]；无法识别任何要素时抛 [FormatException]。
  static BasemapData parse(String text) {
    final dynamic root;
    try {
      root = jsonDecode(text);
    } catch (e) {
      throw FormatException('不是合法 JSON：$e');
    }
    final buildings = <BuildingPoly>[];
    final roads = <RoadPoly>[];
    final places = <PlaceFeature>[];

    final features = <Map<String, dynamic>>[];
    if (root is Map<String, dynamic> && root['type'] == 'FeatureCollection') {
      final arr = root['features'];
      if (arr is List) {
        for (final f in arr) {
          if (f is Map<String, dynamic>) features.add(f);
        }
      }
    } else if (root is Map<String, dynamic> && root['type'] == 'Feature') {
      features.add(root);
    } else if (root is Map<String, dynamic> && root['type'] is String) {
      // 裸几何对象
      features.add({'type': 'Feature', 'geometry': root, 'properties': {}});
    } else {
      throw const FormatException('不是 GeoJSON（需 FeatureCollection/Feature/几何对象）');
    }

    for (final f in features) {
      final props = (f['properties'] is Map)
          ? Map<String, dynamic>.from(f['properties'] as Map)
          : <String, dynamic>{};
      final name = (props['name'] as String?)?.trim() ?? '';
      _consumeGeometry(f['geometry'], props, name, buildings, roads, places);
    }

    if (buildings.isEmpty && roads.isEmpty && places.isEmpty) {
      throw const FormatException('GeoJSON 中未找到可用的建筑/道路/地名要素');
    }

    return BasemapData(
      roads: roads,
      buildings: buildings,
      places: places,
      report: BasemapFetchReport(
        roads: DatasetReport(FetchState.ok,
            source: 'local', count: roads.length),
        buildings: DatasetReport(FetchState.ok,
            source: 'local', count: buildings.length),
        places: DatasetReport(FetchState.ok,
            source: 'local', count: places.length),
      ),
    );
  }

  /// 按 bbox `[minLat, minLon, maxLat, maxLon]` 裁剪。
  ///
  /// 使「范围档位」对本地底图真正生效——**只导出范围内**的矢量：
  /// - **道路**：按 bbox **裁剪几何**——每条 polyline 只保留落在框内的点段，
  ///   一条路可能被裁成**多段**（各自一个 [RoadPoly]，等级/名称保留）；完全在框外的
  ///   丢弃。旧实现「任一点在框内即保留整条」会把一条横穿 50m 范围的 20km 国道
  ///   **整条**（数百顶点、跑到框外几十公里）导出，违背「只导出范围内」。
  ///   框边界按 [toleranceM] 适度外扩，避免路口被切断得太碎（默认 0 = 严格按框）。
  /// - **建筑**：任一点在框内则保留**整栋**（封闭面裁几何会变形，故不裁）。
  /// - **地名**：保持点判断（框内保留）。
  static BasemapData cropTo(
    BasemapData bm,
    List<double> bbox, {
    double toleranceM = 0,
  }) {
    bool inB(double lat, double lon) =>
        lat >= bbox[0] && lat <= bbox[2] && lon >= bbox[1] && lon <= bbox[3];

    // 道路：按框裁剪几何（可拆成多段；框按 toleranceM 适度外扩）。
    final roads = <RoadPoly>[];
    for (final r in bm.roads) {
      final segments = _clipRoadToBox(
          r.pts, bbox[0], bbox[1], bbox[2], bbox[3], toleranceM);
      for (final seg in segments) {
        if (seg.length >= 2) roads.add(RoadPoly(seg, r.grade, r.name));
      }
    }

    final buildings = bm.buildings
        .where((b) => b.rings.any((ring) => ring.any((p) => inB(p[0], p[1]))))
        .toList();
    final places = bm.places.where((p) => inB(p.lat, p.lon)).toList();
    return BasemapData(
      roads: roads,
      buildings: buildings,
      places: places,
      report: BasemapFetchReport(
        roads: DatasetReport(FetchState.ok,
            source: 'local', count: roads.length),
        buildings: DatasetReport(FetchState.ok,
            source: 'local', count: buildings.length),
        places: DatasetReport(FetchState.ok,
            source: 'local', count: places.length),
      ),
    );
  }

  /// 把一条道路 polyline（`[[lat, lon], ...]`）按轴对齐 bbox 裁剪成若干「框内段」。
  ///
  /// 返回的每段至少 2 点；完全在框外的道路返回空。框按 [toleranceM] 米适度外扩
  /// （经度方向按中心纬度做 cos 修正，与 [BasemapFetcher.boundsOf] 同口径），
  /// 避免路口被边界切得过碎。使用 Liang–Barsky 线段裁剪，逐段拼接为连续段。
  static List<List<List<double>>> _clipRoadToBox(
    List<List<double>> pts,
    double minLat,
    double minLon,
    double maxLat,
    double maxLon,
    double toleranceM,
  ) {
    if (pts.length < 2) return const [];
    final midLat = (minLat + maxLat) / 2;
    final cosLat = math.cos(midLat * math.pi / 180).abs().clamp(0.05, 1.0);
    final dLat = toleranceM / 110540.0;
    final dLon = toleranceM / (111320.0 * cosLat);
    final b0 = minLat - dLat, b1 = minLon - dLon;
    final b2 = maxLat + dLat, b3 = maxLon + dLon;

    final out = <List<List<double>>>[];
    var current = <List<double>>[];
    void flush() {
      if (current.length >= 2) out.add(current);
      current = <List<double>>[];
    }

    for (var i = 1; i < pts.length; i++) {
      final seg = _clipSegmentToBox(pts[i - 1], pts[i], b0, b1, b2, b3);
      if (seg == null) {
        // 该段完全在框外 → 断开当前段（框外几何被丢弃）。
        flush();
        continue;
      }
      final s = seg[0], e = seg[1];
      if (_approxEq(s, e)) continue; // 退化点（仅相切/擦边），忽略
      if (current.isEmpty) {
        current = [s, e];
      } else if (_approxEq(current.last, s)) {
        current.add(e); // 与前一段首尾相接 → 继续同一条链
      } else {
        flush(); // 中间有框外缺口 → 另起一段
        current = [s, e];
      }
    }
    flush();
    return out;
  }

  /// Liang–Barsky 线段裁剪：线段 `[a, b]`（`[lat, lon]`）按轴对齐框裁剪，
  /// 返回裁剪后线段 `[起点, 终点]`（均在框内/框上）；完全在框外返回 null。
  static List<List<double>>? _clipSegmentToBox(List<double> a, List<double> b,
      double minLat, double minLon, double maxLat, double maxLon) {
    var t0 = 0.0, t1 = 1.0;
    final dx = b[0] - a[0];
    final dy = b[1] - a[1];
    // p/q 参数对：顺序为 lat 下界、lat 上界、lon 下界、lon 上界。
    final p = <double>[-dx, dx, -dy, dy];
    final q = <double>[
      a[0] - minLat,
      maxLat - a[0],
      a[1] - minLon,
      maxLon - a[1],
    ];
    for (var i = 0; i < 4; i++) {
      if (p[i].abs() < 1e-15) {
        if (q[i] < 0) return null; // 平行于该边界且在框外
      } else {
        final r = q[i] / p[i];
        if (p[i] < 0) {
          if (r > t1) return null;
          if (r > t0) t0 = r;
        } else {
          if (r < t0) return null;
          if (r < t1) t1 = r;
        }
      }
    }
    return [
      [a[0] + t0 * dx, a[1] + t0 * dy],
      [a[0] + t1 * dx, a[1] + t1 * dy],
    ];
  }

  static bool _approxEq(List<double> a, List<double> b) =>
      (a[0] - b[0]).abs() < 1e-12 && (a[1] - b[1]).abs() < 1e-12;

  /// 本地底图要素数防御性上限（R3 兜底）。
  ///
  /// **取值理由**：整市 OSM 底图（如信阳 18MB / 约 4.46 万要素）远超此值；而经
  /// [cropTo] 裁剪后，一条 50–1000m 走廊内真实要素数通常为数十~数千。取 20000
  /// 既给密集城区走廊留足余量，又能在任何「裁剪失效」类逻辑漏洞复发时把 DXF
  /// 体积兜底控制在数 MB 量级（而非几十 MB）。
  static const int defaultFeatureCap = 20000;

  /// R3 防御性上限：本地底图要素总数超过 [cap] 条时，按「到线路（[routePts]）最近
  /// 点距离」由近到远保留前 [cap] 条，其余丢弃，并向 [warnings] 追加中文提示。
  ///
  /// 目的：即便将来再出现类似「裁剪失效/回退全量」的逻辑漏洞，也不会产出几十 MB
  /// 的 DXF。三条数据集（道路/建筑/地名）统一按距离参与排序、共享同一上限，
  /// 保证截断后总要素数严格 ≤ [cap]。总数未超限时**原样返回**（零开销、零副作用）。
  static BasemapData capFeatures(
    BasemapData bm, {
    required List<List<double>> routePts,
    int cap = defaultFeatureCap,
    List<String>? warnings,
  }) {
    final total = bm.roads.length + bm.buildings.length + bm.places.length;
    if (cap <= 0 || total <= cap) return bm;

    double distToRoute(double lat, double lon) {
      if (routePts.isEmpty) return 0;
      var best = double.infinity;
      for (final p in routePts) {
        final d = _haversineM(lat, lon, p[0], p[1]);
        if (d < best) best = d;
      }
      return best;
    }

    final items = <_FeatureRef>[];
    for (var i = 0; i < bm.roads.length; i++) {
      final pts = bm.roads[i].pts;
      items.add(_FeatureRef(
          0,
          i,
          pts.isEmpty
              ? double.infinity
              : distToRoute(pts.first[0], pts.first[1])));
    }
    for (var i = 0; i < bm.buildings.length; i++) {
      final outer = bm.buildings[i].outer;
      if (outer.isEmpty) {
        items.add(_FeatureRef(1, i, double.infinity));
        continue;
      }
      var la = 0.0, lo = 0.0;
      for (final p in outer) {
        la += p[0];
        lo += p[1];
      }
      items.add(_FeatureRef(1, i, distToRoute(la / outer.length, lo / outer.length)));
    }
    for (var i = 0; i < bm.places.length; i++) {
      final p = bm.places[i];
      items.add(_FeatureRef(2, i, distToRoute(p.lat, p.lon)));
    }
    items.sort((a, b) => a.dist.compareTo(b.dist));

    final rKeep = <int>{}, bKeep = <int>{}, pKeep = <int>{};
    for (final it in items.take(cap)) {
      if (it.kind == 0) {
        rKeep.add(it.index);
      } else if (it.kind == 1) {
        bKeep.add(it.index);
      } else {
        pKeep.add(it.index);
      }
    }
    final roads = [
      for (var i = 0; i < bm.roads.length; i++)
        if (rKeep.contains(i)) bm.roads[i]
    ];
    final buildings = [
      for (var i = 0; i < bm.buildings.length; i++)
        if (bKeep.contains(i)) bm.buildings[i]
    ];
    final places = [
      for (var i = 0; i < bm.places.length; i++)
        if (pKeep.contains(i)) bm.places[i]
    ];
    warnings?.add('本地底图：要素数超过上限 $cap 条（本次 $total 条），'
        '已按「距线路最近优先」截断保留 $cap 条，图面为部分底图（可减小范围档位重试）。');
    return BasemapData(
      roads: roads,
      buildings: buildings,
      places: places,
      report: BasemapFetchReport(
        roads: DatasetReport(FetchState.ok,
            source: 'local', count: roads.length),
        buildings: DatasetReport(FetchState.ok,
            source: 'local', count: buildings.length),
        places: DatasetReport(FetchState.ok,
            source: 'local', count: places.length),
      ),
    );
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

  static void _consumeGeometry(
    dynamic geom,
    Map<String, dynamic> props,
    String name,
    List<BuildingPoly> buildings,
    List<RoadPoly> roads,
    List<PlaceFeature> places,
  ) {
    if (geom is! Map<String, dynamic>) return;
    final type = geom['type'];
    final coords = geom['coordinates'];

    if (type == 'GeometryCollection') {
      final gs = geom['geometries'];
      if (gs is List) {
        for (final g in gs) {
          _consumeGeometry(g, props, name, buildings, roads, places);
        }
      }
      return;
    }

    if (type == 'Polygon') {
      final rings = _ringsFromPolygon(coords);
      if (rings.isNotEmpty) buildings.add(BuildingPoly(rings, name));
      return;
    }
    if (type == 'MultiPolygon') {
      if (coords is List) {
        for (final poly in coords) {
          final rings = _ringsFromPolygon(poly);
          if (rings.isNotEmpty) buildings.add(BuildingPoly(rings, name));
        }
      }
      return;
    }
    if (type == 'LineString') {
      final pts = _lineFrom(coords);
      if (pts.length >= 2) roads.add(RoadPoly(pts, _gradeOf(props), name));
      return;
    }
    if (type == 'MultiLineString') {
      if (coords is List) {
        for (final line in coords) {
          final pts = _lineFrom(line);
          if (pts.length >= 2) roads.add(RoadPoly(pts, _gradeOf(props), name));
        }
      }
      return;
    }
    if (type == 'Point') {
      final p = _pointFrom(coords);
      if (p != null) places.add(_placeFrom(p, props, name));
      return;
    }
    if (type == 'MultiPoint') {
      if (coords is List) {
        for (final c in coords) {
          final p = _pointFrom(c);
          if (p != null) places.add(_placeFrom(p, props, name));
        }
      }
      return;
    }
  }

  /// GeoJSON Polygon 坐标 → 环列表（`[[lat,lon], ...]`），丢弃 <3 点的环。
  static List<List<List<double>>> _ringsFromPolygon(dynamic coords) {
    final out = <List<List<double>>>[];
    if (coords is! List) return out;
    for (final ring in coords) {
      final pts = _lineFrom(ring);
      if (pts.length >= 3) out.add(pts);
    }
    return out;
  }

  /// 坐标串 `[[lon,lat], ...]` → `[[lat,lon], ...]`（过滤非法点）。
  static List<List<double>> _lineFrom(dynamic arr) {
    final out = <List<double>>[];
    if (arr is! List) return out;
    for (final c in arr) {
      final p = _pointFrom(c);
      if (p != null) out.add(p);
    }
    return out;
  }

  /// `[lon, lat]` → `[lat, lon]`；**非数值 / 越界坐标一律按「非法坐标」过滤返回 null**
  /// （用类型判定，而非 `as num?` 强转——否则字符串坐标会抛 `TypeError`，
  /// 破坏 [parse] 「非法输入抛 [FormatException]」的契约）。
  static List<double>? _pointFrom(dynamic c) {
    if (c is! List || c.length < 2) return null;
    final dynamic rawLon = c[0];
    final dynamic rawLat = c[1];
    if (rawLon is! num || rawLat is! num) return null; // 非数值 → 过滤，不兜底为 0
    final lon = rawLon.toDouble();
    final lat = rawLat.toDouble();
    if (lat.isNaN || lat.isInfinite || lon.isNaN || lon.isInfinite) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return [lat, lon];
  }

  static RoadGrade _gradeOf(Map<String, dynamic> props) {
    final hw = (props['highway'] as String?) ?? '';
    if (hw.isNotEmpty) return OverpassClient.gradeOf(hw);
    // 无 highway 标注的线要素：按铁路/主干常见类兜底为 other（仍参与渲染，只是最细）。
    return RoadGrade.other;
  }

  static PlaceFeature _placeFrom(
      List<double> p, Map<String, dynamic> props, String name) {
    final place = (props['place'] as String?) ?? '';
    final landuse = (props['landuse'] as String?) ?? '';
    final PlaceLevel level;
    if (place.isNotEmpty) {
      level = OverpassClient.placeLevelOf(place);
    } else if (landuse == 'residential') {
      level = PlaceLevel.residential;
    } else {
      level = PlaceLevel.neighbourhood;
    }
    return PlaceFeature(
      name: name.isEmpty ? '未命名' : name,
      lat: p[0],
      lon: p[1],
      level: level,
      isArea: false,
    );
  }
}

/// 要素引用（R3 上限截断内部用）：`kind` 0=道路/1=建筑/2=地名，`index` 为原列表下标，
/// `dist` 为到线路（routePts）最近点的距离（米），用于「距线路最近优先」排序。
class _FeatureRef {
  final int kind;
  final int index;
  final double dist;
  const _FeatureRef(this.kind, this.index, this.dist);
}

/// 项目级「导入的本地底图」存储：`${labelsDir}/basemap/local/imported.geojson`。
/// 一次导入、长期离线复用（与在线缓存同处项目目录，不随 7 天过期）。
class LocalBasemapStore {
  final Directory root;
  LocalBasemapStore(this.root);

  /// 打开默认目录（`LabelStore.basemapDir()/local`）。
  static Future<LocalBasemapStore> open() async {
    final base = await LabelStore.instance.basemapDir();
    final d = Directory('${base.path}/local');
    if (!d.existsSync()) d.createSync(recursive: true);
    return LocalBasemapStore(d);
  }

  File get _file => File('${root.path}/imported.geojson');

  File get _metaFile => File('${root.path}/imported.meta.json');

  /// 是否已导入本地底图。
  bool exists() => _file.existsSync();

  /// 保存原始 GeoJSON 文本 + 元信息（导入时间 / 来源文件名 / 要素计数）。
  Future<void> save(
    String rawGeoJson, {
    String sourceName = '',
    int roads = 0,
    int buildings = 0,
    int places = 0,
  }) async {
    await robustWriteAsString(_file, rawGeoJson);
    await robustWriteAsString(
      _metaFile,
      jsonEncode({
        'sourceName': sourceName,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'roads': roads,
        'buildings': buildings,
        'places': places,
      }),
    );
  }

  /// 读取元信息（无则返回空 Map）。
  Map<String, dynamic> meta() {
    try {
      if (!_metaFile.existsSync()) return {};
      final s = _metaFile.readAsStringSync().trim();
      if (s.isEmpty) return {};
      final d = jsonDecode(s);
      return d is Map ? Map<String, dynamic>.from(d) : {};
    } catch (_) {
      return {};
    }
  }

  /// 载入并解析本地底图；未导入或解析失败返回 null。
  Future<BasemapData?> load() async {
    if (!_file.existsSync()) return null;
    try {
      return GeoJsonImporter.parse(_file.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  /// 清除本地底图（原始文件 + 元信息）。
  Future<void> clear() async {
    try {
      if (_file.existsSync()) _file.deleteSync();
      if (_metaFile.existsSync()) _metaFile.deleteSync();
    } catch (_) {}
  }
}
