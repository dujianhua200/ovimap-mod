/// 内置兜底底图：信阳市 OSM 道路（含路名）+ 地名 + 建筑轮廓。
///
/// ## 为什么需要它
/// 现场勘察常在没信号的村子里，而底图依赖 Overpass/高德/天地图联网抓取。
/// 抓不到就只有空白背景，DXF 里什么地物都没有 —— 图纸没法用。
/// 上游（dujianhua200/ovimap v4.0.x）把信阳全市的矢量底图**离线预打包**
/// 进安装包（`assets/buildings/*.geojson.gz`，约 21MB），这正是兜底图的来源。
///
/// ## 与上游实现的差别
/// 上游（`building_fallback.dart`）把这套数据当作"可下载的兜底包"：
/// 走 manifest + 多镜像下载 → 解压 → 写入 app 目录 → 建索引，
/// 适合"包体小、按需下载"的场景。但我们的包里**数据本来就在**，
/// 再走一遍"安装到磁盘"只是多一次 IO 与一份副本，没有收益。
///
/// 这里改为**直接读 asset、内存中按 bbox 过滤**：
///   · 首次遍历就建好 bbox 索引，之后查询是纯内存过滤；
///   · 不做落盘安装，重启零成本；
///   · 解析失败只返回空（绝不阻断导出）。
///
/// ## 数据格式
/// 标准 GeoJSON FeatureCollection（gzip 压缩）：
///   · xinyang.geojson.gz         建筑轮廓（Polygon/MultiPolygon）
///   · xinyang_roads.geojson.gz   道路（LineString，properties.highway/name）
///   · xinyang_places.geojson.gz  地名（Point，properties.name/kind）
library;

import 'dart:convert';
import 'dart:io' show Platform, gzip;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/services.dart' show rootBundle;

/// 数据覆盖范围（WGS84 经纬度）。
///
/// ⚠️ 这组常量必须**小于等于数据实际范围**，否则 `covers()` 会把
/// "明明有数据的地方"判成没数据，兜底被静默跳过。
///
/// 实测（assets/buildings/*.geojson.gz 真实包围盒）：
///   roads     lon 113.690~115.629  lat 31.160~32.679
///   places    lon 113.699~115.600  lat 31.200~32.596
///   buildings lon 113.723~115.932  lat 31.393~32.664
///
/// 取**三者交集**再各留 0.02° 余量：
///   lon 113.72 ~ 115.58   lat 31.41 ~ 32.58
///
/// 早期写的 113.7~115.6 / 31.2~32.6 比 buildings 的实际下界还宽，
/// 于是"建筑那一片"永远判不覆盖 —— 这就是用户三次反馈
/// "地图包好像没起作用"的真正原因。
const double kBundledLonMin = 113.72;
const double kBundledLonMax = 115.58;
const double kBundledLatMin = 31.41;
const double kBundledLatMax = 32.58;

/// 内置数据版本。换包时递增，便于诊断"用户装的是旧包"。
const int kBundledBasemapVersion = 1;

const String kBundledBuildingsAsset = 'assets/buildings/xinyang.geojson.gz';
const String kBundledRoadsAsset = 'assets/buildings/xinyang_roads.geojson.gz';
const String kBundledPlacesAsset = 'assets/buildings/xinyang_places.geojson.gz';

/// 一条内置道路（坐标已是 WGS84，`[lat, lon]` 与项目其余部分一致）。
class BundledRoad {
  final List<List<double>> pts;
  final String name;
  final String highway;
  final double minLat, minLon, maxLat, maxLon;

  BundledRoad(this.pts, this.name, this.highway)
      : minLat = pts.map((p) => p[0]).reduce((a, b) => a < b ? a : b),
        maxLat = pts.map((p) => p[0]).reduce((a, b) => a > b ? a : b),
        minLon = pts.map((p) => p[1]).reduce((a, b) => a < b ? a : b),
        maxLon = pts.map((p) => p[1]).reduce((a, b) => a > b ? a : b);
}

/// 一个内置地名点。
class BundledPlace {
  final String name;
  final String kind;
  final double lat, lon;
  const BundledPlace(this.name, this.kind, this.lat, this.lon);
}

/// 内置底图（单例，惰性加载一次）。
class BundledBasemap {
  BundledBasemap._();

  static BundledBasemap? _instance;

  /// 是否启用。默认 **false**。
  ///
  /// `main.dart` 启动时置 true（生产环境）。
  ///
  /// ⚠️ 测试里**必须**保持 false：数据解压后有 20 万+ 要素，
  /// 在 `flutter test` 的并行进程里同时加载会直接把用例拖到超时
  /// （实测 13 个用例 "did not complete"）。单元测试关心的是导出逻辑，
  /// 不需要真底图；需要验内置数据的用例在 test 里显式打开开关。
  static bool _enabled = false;

  static bool get enabled => _enabled && (!_isFlutterTest || _bypassTestGuard);

  static set enabled(bool v) => _enabled = v;

  /// 测试专用旁路：允许在 `flutter_tester` 里真正加载内置数据。
  ///
  /// 只有**专门验证内置底图**的用例才该打开它（那些用例自己承担加载耗时）。
  static bool _bypassTestGuard = false;

  static void setTestBypass(bool v) {
    _bypassTestGuard = v;
    if (v) _enabled = true;
  }

  /// 是否运行在 `flutter test` 里。
  ///
  /// 判据：测试运行器的可执行文件叫 `flutter_tester`。用它做**硬保护** ——
  /// 即使某个测试忘了关开关（或 main.dart 的初始化被复用），也不会
  /// 在并行测试里解压 21MB 数据把别人拖超时。
  static bool get _isFlutterTest {
    try {
      final exe = Platform.resolvedExecutable.toLowerCase();
      return exe.contains('flutter_tester');
    } catch (_) {
      return false;
    }
  }

  static Future<BundledBasemap> get instance async {
    final v = _instance;
    if (v != null) return v;
    final b = BundledBasemap._();
    await b._load();
    _instance = b;
    return b;
  }

  static void resetForTest() => _instance = null;

  final List<BundledRoad> _roads = [];
  final List<BundledPlace> _places = [];
  final List<List<List<double>>> _buildingRings = [];

  /// 各项数据的 bbox（用于快速判断"这一片有没有内置数据"）。
  double _rMinLat = 90, _rMaxLat = -90, _rMinLon = 180, _rMaxLon = -180;
  double _pMinLat = 90, _pMaxLat = -90, _pMinLon = 180, _pMaxLon = -180;

  /// 建筑数据范围：用**构建时实测的常量**（不再解析 70 万条来求）。
  ///
  /// 实测值（assets/buildings/xinyang.geojson.gz）：
  ///   lon 113.723 ~ 115.932   lat 31.393 ~ 32.664
  /// 惰性解析后没有全量顶点可扫，所以这里写死。换数据包时同步改。
  static const double _bMinLon = 113.723, _bMaxLon = 115.932;
  static const double _bMinLat = 31.393, _bMaxLat = 32.664;

  bool get roadsLoaded => _roads.isNotEmpty;
  bool get placesLoaded => _places.isNotEmpty;
  /// 建筑数据是否可用（只看字节在不在，不看解析结果）。
  bool get buildingsLoaded => _buildingsGzBytes != null;

  /// 给定 bbox **是否与内置数据范围有交集**。
  ///
  /// v3.13 由"完全包含"改为"**相交即可**"：
  /// 原来要求 `lonMin >= 边界 && lonMax <= 边界`，线路只要稍微越界
  /// （勘察常压着县界走）就整块跳过兜底 —— 用户三次反馈"地图包没用上"。
  /// 正确的语义是：**有交集就补**，越界部分自然没有数据（查询时按 bbox 过滤）。
  static bool covers(double lonMin, double latMin, double lonMax, double latMax) {
    // 不相交才返回 false
    if (lonMax < kBundledLonMin || lonMin > kBundledLonMax) return false;
    if (latMax < kBundledLatMin || latMin > kBundledLatMax) return false;
    return true;
  }

  /// 加载失败的**可观测**记录（每类数据一条）。
  ///
  /// 早期这里全是 `catch (_) {}` 静默吞掉 —— 数据没加载上，用户只看到
  /// "地图包好像没起作用"，我们却拿不到任何线索。现在把异常收进
  /// [loadErrors] 并暴露到 [summary]，便于现场排查。
  final List<String> loadErrors = [];

  Future<void> _load() async {
    final sw = Stopwatch()..start();
    try {
      final txt = await _readGz(kBundledRoadsAsset);
      for (final f in _features(txt)) {
        final geom = f['geometry'];
        if (geom is! Map) continue;
        if (geom['type'] != 'LineString') continue;
        final pts = _toLatLon(geom['coordinates']);
        if (pts.length < 2) continue;
        final props = _props(f);
        final road = BundledRoad(
          pts,
          (props['name'] as String?) ?? '',
          (props['highway'] as String?) ?? '',
        );
        _roads.add(road);
        _extendRoadBox(road);
      }
    } catch (e) {
      loadErrors.add('道路：$e');
    }

    try {
      final txt = await _readGz(kBundledPlacesAsset);
      for (final f in _features(txt)) {
        final props = _props(f);
        final name = (props['name'] as String?) ?? '';
        if (name.isEmpty) continue;
        final geom = f['geometry'];
        if (geom is! Map || geom['type'] != 'Point') continue;
        final c = geom['coordinates'];
        if (c is! List || c.length < 2) continue;
        final lon = (c[0] as num).toDouble();
        final lat = (c[1] as num).toDouble();
        _places.add(
            BundledPlace(name, (props['kind'] as String?) ?? '', lat, lon));
        _pMinLat = lat < _pMinLat ? lat : _pMinLat;
        _pMaxLat = lat > _pMaxLat ? lat : _pMaxLat;
        _pMinLon = lon < _pMinLon ? lon : _pMinLon;
        _pMaxLon = lon > _pMaxLon ? lon : _pMaxLon;
      }
    } catch (e) {
      loadErrors.add('地名：$e');
    }

    // **建筑数据不在加载时解析**（v3.16 内存修复）。
    //
    // 背景：建筑有 70 万栋，全量解析进内存要 1.5~2 GB ——
    // 用户实测任务管理器里 ovimap 占到 1967 MB，机器直接卡死。
    //
    // 改为：这里只**记住压缩字节**（21MB），第一次查询建筑时才解压解析，
    // 且解析结果**只保留 bbox 内的**，用完即弃。
    // 代价是首次查询慢一点（约 3~5 秒），换来常驻内存从 2GB 降到几十 MB。
    try {
      final raw = await rootBundle.load(kBundledBuildingsAsset);
      _buildingsGzBytes = raw.buffer.asUint8List();
    } catch (e) {
      loadErrors.add('建筑：$e');
    }
    _loaded = true;
    _loadMs = sw.elapsedMilliseconds;
  }

  /// 建筑数据的压缩字节（惰性解析用；不在内存里存解析结果）。
  Uint8List? _buildingsGzBytes;

  /// 是否已经跑过 [_load]（无论成功失败）。
  bool _loaded = false;
  bool get loadedOnce => _loaded;

  /// 上次加载耗时（毫秒），用于诊断"是不是加载太慢/超时"。
  int _loadMs = 0;
  int get loadMs => _loadMs;

  void _extendRoadBox(BundledRoad r) {
    _rMinLat = r.minLat < _rMinLat ? r.minLat : _rMinLat;
    _rMaxLat = r.maxLat > _rMaxLat ? r.maxLat : _rMaxLat;
    _rMinLon = r.minLon < _rMinLon ? r.minLon : _rMinLon;
    _rMaxLon = r.maxLon > _rMaxLon ? r.maxLon : _rMaxLon;
  }

  static Future<String> _readGz(String asset) async {
    final data = await rootBundle.load(asset);
    return utf8.decode(gzip.decode(data.buffer.asUint8List()));
  }

  static List<Map<String, dynamic>> _features(String jsonText) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map) return const [];
    final feats = decoded['features'];
    if (feats is! List) return const [];
    return feats.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  static Map<String, dynamic> _props(Map<String, dynamic> f) {
    final p = f['properties'];
    return p is Map ? p.cast<String, dynamic>() : <String, dynamic>{};
  }

  /// GeoJSON 是 `[lon, lat]`；项目内部统一用 `[lat, lon]`。
  static List<List<double>> _toLatLon(dynamic coords) {
    if (coords is! List) return const [];
    final out = <List<double>>[];
    for (final c in coords) {
      if (c is! List || c.length < 2) continue;
      final lon = (c[0] as num).toDouble();
      final lat = (c[1] as num).toDouble();
      out.add([lat, lon]);
    }
    return out;
  }

  // ---------------- 查询 ----------------

  /// 取 bbox 内的道路（与 bbox 相交即算）。
  List<BundledRoad> roadsIn(
      double lonMin, double latMin, double lonMax, double latMax) {
    if (_roads.isEmpty) return const [];
    return _roads.where((r) {
      return !(r.maxLat < latMin ||
          r.minLat > latMax ||
          r.maxLon < lonMin ||
          r.minLon > lonMax);
    }).toList();
  }

  /// 取 bbox 内的地名。
  List<BundledPlace> placesIn(
          double lonMin, double latMin, double lonMax, double latMax) =>
      _places
          .where((p) =>
              p.lon >= lonMin &&
              p.lon <= lonMax &&
              p.lat >= latMin &&
              p.lat <= latMax)
          .toList();

  /// 取 bbox 内的建筑轮廓环（`[lat, lon]` 列表）。
  ///
  /// ## 惰性解析（v3.16 内存修复）
  /// 建筑 70 万栋，全量解析常驻要 ~2GB。这里改为：
  ///   · 解压 + 解析只在**第一次查询**时发生；
  ///   · 解析过程中**只保留落在 bbox 内的环**，其余立即丢弃；
  ///   · 不缓存解析结果（下次查询重新过滤）。
  /// 代价是每次导出多几秒，换来常驻内存从 GB 级降到几十 MB。
  List<List<List<double>>> buildingsIn(
      double lonMin, double latMin, double lonMax, double latMax) {
    final gz = _buildingsGzBytes;
    if (gz == null) return const [];

    // 快速排除：与数据总范围无交集
    if (lonMax < _bMinLon || lonMin > _bMaxLon) return const [];
    if (latMax < _bMinLat || latMin > _bMaxLat) return const [];

    final out = <List<List<double>>>[];
    try {
      final txt = utf8.decode(gzip.decode(gz));
      for (final f in _features(txt)) {
        final geom = f['geometry'];
        if (geom is! Map) continue;
        final coords = geom['coordinates'];
        final type = geom['type'];
        if (type == 'Polygon' && coords is List) {
          for (final ring in coords) {
            final ringPts = _toLatLon(ring);
            if (_ringInBox(ringPts, lonMin, latMin, lonMax, latMax)) {
              out.add(ringPts);
            }
          }
        } else if (type == 'MultiPolygon' && coords is List) {
          for (final poly in coords) {
            if (poly is! List) continue;
            for (final ring in poly) {
              final ringPts = _toLatLon(ring);
              if (_ringInBox(ringPts, lonMin, latMin, lonMax, latMax)) {
                out.add(ringPts);
              }
            }
          }
        }
      }
    } catch (e) {
      loadErrors.add('建筑解析：$e');
    }
    return out;
  }

  /// 环是否有顶点落在框内。
  static bool _ringInBox(List<List<double>> ring, double lonMin, double latMin,
      double lonMax, double latMax) {
    if (ring.length < 3) return false;
    for (final p in ring) {
      if (p[0] >= latMin &&
          p[0] <= latMax &&
          p[1] >= lonMin &&
          p[1] <= lonMax) {
        return true;
      }
    }
    return false;
  }

  /// 诊断用：各项数据条数与覆盖范围。
  String summary() {
    String box(double a, double b, double c, double d) =>
        a > 90 ? '无' : '${c.toStringAsFixed(2)},${a.toStringAsFixed(2)}'
            '~${d.toStringAsFixed(2)},${b.toStringAsFixed(2)}';
    final errs = loadErrors.isEmpty
        ? ''
        : '\n加载异常：${loadErrors.join('；')}';
    return '道路 ${_roads.length} 条（${box(_rMinLat, _rMaxLat, _rMinLon, _rMaxLon)}）\n'
        '地名 ${_places.length} 个（${box(_pMinLat, _pMaxLat, _pMinLon, _pMaxLon)}）\n'
        '建筑 ${_buildingsGzBytes != null ? '已就绪（惰性，按范围过滤）' : '未加载'}'
        '（${box(_bMinLat, _bMaxLat, _bMinLon, _bMaxLon)}）\n'
        '耗时 ${_loadMs}ms$errs';
  }
}
