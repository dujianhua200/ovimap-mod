import 'dart:convert';

import 'package:http/http.dart' as http;

import '../geo/gcj02.dart';

/// 内置天地图开发者 key（单一来源；`AppState.builtinTdtKey` 引用本常量）。
///
/// ⚠️ **仓库已公开，内置 key 一律不入库**（v3.9.2）：常量保留但为空串，
/// 未配置时走「未配置」提示。请在「更多→天地图 Key 设置」里填自己的 key。
const String kBuiltinTiandituKey = '';

/// 地名 / POI 检索结果（点）。
class SearchResult {
  final String name;
  final String address;
  final double lat;
  final double lon;
  const SearchResult({
    required this.name,
    required this.address,
    required this.lat,
    required this.lon,
  });

  String get displayName =>
      address.isEmpty || address == name ? name : '$name · $address';
}

/// 天地图地名搜索 2.0 客户端（从 `SearchService._tianditu` 抽取的公共方法）。
///
/// - **瓦片**为 CGCS2000 ≈ WGS84；但 **v2/search 的 POI 检索数据实测是
///   GCJ-02 火星坐标**（信阳地区偏移约 300~600 米）。官方"无需纠偏"仅指
///   瓦片——因此本客户端在出口统一把检索结果过 `Gcj02Converter.gcj02ToWgs84`
///   （可用 [search] 的 `convertGcj` 关闭，配合设置项「天地图地名坐标系」），
///   保证 app 内存储统一 WGS84（第十九批实测修正，原注释"不做 GCJ 转换"
///   属错误认知）。
/// - 端点 `/v2/search` 支持 `mapBound` 矩形限定；`queryType=1` 为关键字查询。
///   传入基准点（`nearLat/nearLon`）时优先以 ±0.3°（约 ±30km）本地范围检索，
///   本地无结果再用全国范围兜底重试——避免全国检索时本地小区被外地同名
///   POI 淹没（实测：全国搜"丰乐园"返回 10 条外地名，信阳 0 条）。
/// - 天地图**仅提供 POI/地名点**，不提供建筑/道路矢量面（N7），故仅用于地名兜底。
class TiandituClient {
  TiandituClient._();

  /// 可注入的 HTTP GET 钩子（仅供测试零网络 mock 用；null 时用真实 http.get）。
  static Future<http.Response> Function(Uri url)? httpGetOverride;

  /// 全国范围（左下经,左下纬,右上经,右上纬）。
  static const String nationalBound = '73,3,135,54';

  /// 本地检索半径（度）：±0.3° ≈ ±30km，覆盖县城及以上搜索场景。
  static const double localDelta = 0.3;

  /// 以基准点为中心的本地检索范围（左下经,左下纬,右上经,右上纬）。
  static String localBound(double lat, double lon) {
    return '${lon - localDelta},${lat - localDelta},'
        '${lon + localDelta},${lat + localDelta}';
  }

  /// 关键字检索。失败抛异常（带中文说明），绝不静默返回空。
  ///
  /// [mapBound] 显式传入时按该范围检索（如 [poiInBounds]，不做兜底重试）；
  /// 不传且给了 [nearLat]/[nearLon]（WGS84 基准点，一般传当前地图中心）时，
  /// 先用本地 ±0.3° 范围检索，结果为空再用全国范围重试一次（本地优先、
  /// 全国兜底）；都不满足时用全国范围。
  /// [convertGcj] 为 false 时不做 GCJ-02→WGS-84 纠偏（保留原始返回坐标）。
  static Future<List<SearchResult>> search(
    String q,
    String key, {
    String? mapBound,
    int level = 12,
    int count = 15,
    bool convertGcj = true,
    double? nearLat,
    double? nearLon,
  }) async {
    // 本地优先 + 全国兜底（两段式）：仅在未显式指定范围且给了基准点时启用。
    if (mapBound == null && nearLat != null && nearLon != null) {
      final local = await _query(q, key, localBound(nearLat, nearLon), level,
          count, convertGcj);
      if (local.isNotEmpty) return local;
      return _query(q, key, nationalBound, level, count, convertGcj);
    }
    return _query(q, key, mapBound ?? nationalBound, level, count, convertGcj);
  }

  /// 实际发起一次检索请求并解析（含 GCJ 纠偏出口）。
  static Future<List<SearchResult>> _query(String q, String key,
      String mapBound, int level, int count, bool convertGcj) async {
    final postStr = jsonEncode({
      'keyWord': q,
      'level': level,
      'mapBound': mapBound,
      'queryType': 1, // 1=关键字查询（含地名、POI）
      'start': 0,
      'count': count,
    });
    final url = Uri.parse(
        'http://api.tianditu.gov.cn/v2/search?postStr='
        '${Uri.encodeQueryComponent(postStr)}&type=query&tk=${Uri.encodeQueryComponent(key)}');
    final get = httpGetOverride ?? http.get;
    final res = await get(url).timeout(const Duration(seconds: 6));
    if (res.statusCode != 200) {
      throw Exception('tianditu http ${res.statusCode}');
    }
    final jo = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final status = jo['status'] as Map<String, dynamic>?;
    if (status?['infocode'] != 1000) {
      throw Exception('tianditu status ${status?['cndesc'] ?? 'err'}');
    }
    final out = <SearchResult>[];
    for (final p in (jo['pois'] as List?) ?? const []) {
      final m = p as Map<String, dynamic>;
      final ll = parseLonlat((m['lonlat'] as String?) ?? '');
      if (ll == null) continue;
      final name = (m['name'] as String?)?.trim() ?? '';
      if (name.isEmpty) continue;
      // 天地图检索 POI 实测为 GCJ-02，出口统一纠偏为 WGS84（app 内存储同系）。
      final wgs = convertGcj
          ? Gcj02Converter.gcj02ToWgs84(ll[0], ll[1])
          : ll;
      out.add(SearchResult(
        name: name,
        address: (m['address'] as String?)?.trim() ?? '',
        lat: wgs[0],
        lon: wgs[1],
      ));
    }
    // 行政区划命中（如搜索城市/片区名）
    final area = jo['area'] as Map<String, dynamic>?;
    if (area != null) {
      final name = (area['name'] as String?)?.trim() ?? '';
      final ll = parseLonlat((area['lonlat'] as String?) ?? '');
      if (name.isNotEmpty && ll != null) {
        final wgs = convertGcj
            ? Gcj02Converter.gcj02ToWgs84(ll[0], ll[1])
            : ll;
        out.add(SearchResult(
            name: name, address: '', lat: wgs[0], lon: wgs[1]));
      }
    }
    return out;
  }

  /// 在指定 bbox 内按关键字检索地名/POI（`bbox = [minLat, minLon, maxLat, maxLon]`）。
  /// 用于 OSM 地名为空时的**兜底补名**。范围显式传入，不做本地/全国两段式。
  ///
  /// **坐标口径**：`mapBound` 用 [bbox] 的 **WGS-84** 原值拼串（未转 GCJ-02）。
  /// 天地图的 `mapBound` 是**软过滤**（实测不硬限范围，会返回框外数十公里的同名 POI），
  /// 故 WGS/GCJ 的系统性偏移对它影响小；范围硬约束统一交由上层
  /// `BasemapFetcher._poiByKeywords` / `cropPlaces` 在**纠偏后的 WGS-84 空间**执行。
  static Future<List<SearchResult>> poiInBounds(
    List<double> bbox,
    String keyword,
    String key, {
    bool convertGcj = true,
  }) async {
    final mapBound = '${bbox[1]},${bbox[0]},${bbox[3]},${bbox[2]}';
    return search(keyword, key,
        mapBound: mapBound, count: 20, convertGcj: convertGcj);
  }

  /// "经度,纬度" → `[纬度, 经度]`，解析失败返回 null。
  static List<double>? parseLonlat(String s) {
    if (!s.contains(',')) return null;
    final parts = s.split(',');
    final lon = double.tryParse(parts[0].trim());
    final lat = double.tryParse(parts[1].trim());
    if (lat == null || lon == null) return null;
    return [lat, lon];
  }
}
