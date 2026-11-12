import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'amap.dart';
import 'tianditu.dart';

// 保持向后兼容：`SearchResult` 仍可从 search.dart 导入。
export 'tianditu.dart' show SearchResult, kBuiltinTiandituKey;

/// 搜索结果 + 与参考点（通常为地图中心）的 haversine 距离（米）。
class SearchHit {
  final SearchResult result;

  /// 与参考点的距离（米，WGS84 haversine）。
  final double distM;
  const SearchHit(this.result, this.distM);
}

/// 地名搜索（多源、国内优先）：
/// 1. **高德 POI 搜索**（国内，覆盖与准确率最好，需用户自配 key）
/// 2. 天地图 POI 搜索（国内，快且准，需在「更多→天地图 Key」里配置 key）
/// 3. OSM Nominatim（境外，国内经常不可达，作为回退）
/// 4. Photon / komoot（境外备用源）
/// 全部失败时抛出带中文说明的异常——绝不静默返回空。
class SearchService {
  SearchService._();

  /// [amapKey] 为高德 Web 服务 key（可空，需用户自配）。有 key 时**优先走高德**；
  /// [tdtKey] 为天地图开发者 key（可空）。两者都没配或都失败时回退到境外源。
  ///
  /// [nearLat] / [nearLon] 为可选基准点（WGS84，一般传当前地图中心）。
  /// 传入后结果按与基准点的 haversine 距离升序排序（离用户最近的排最前，
  /// 对齐奥维地图的搜索体验）；不传时保持数据源原始顺序。
  /// 同时作为天地图本地检索范围的中心（±0.3°，约 ±30km；本地无结果
  /// 再用全国范围兜底）——避免本地小区被全国同名 POI 淹没。
  ///
  /// [convertGcj] 控制天地图检索结果是否做 GCJ-02→WGS-84 纠偏
  /// （天地图检索 POI 实测为 GCJ-02；由设置项「天地图地名坐标系」决定，
  /// 默认开启）。
  static Future<List<SearchResult>> search(String q,
      {String tdtKey = '',
      String amapKey = '',
      double? nearLat,
      double? nearLon,
      bool convertGcj = true}) async {
    Object? lastErr;
    List<SearchResult> results = const [];
    // 优先级：高德 > 天地图 > Nominatim > Photon（任一源取到非空即停，失败降级）。
    if (amapKey.isNotEmpty) {
      try {
        final r = await AmapClient.search(q, amapKey,
            convertGcj: convertGcj,
            nearLat: nearLat,
            nearLon: nearLon);
        if (r.isNotEmpty) results = r;
      } catch (e) {
        lastErr = e;
      }
    }
    if (results.isEmpty && tdtKey.isNotEmpty) {
      try {
        final r = await TiandituClient.search(q, tdtKey,
            convertGcj: convertGcj,
            nearLat: nearLat,
            nearLon: nearLon);
        if (r.isNotEmpty) results = r;
      } catch (e) {
        lastErr = e;
      }
    }
    if (results.isEmpty) {
      try {
        final r = await _nominatim(q);
        if (r.isNotEmpty) results = r;
      } catch (e) {
        lastErr = e;
      }
    }
    if (results.isEmpty) {
      try {
        final r = await _photon(q);
        if (r.isNotEmpty) results = r;
      } catch (e) {
        lastErr = e;
      }
    }
    if (results.isEmpty) {
      throw Exception('地名搜索失败：$lastErr');
    }
    return sortByDistance(results, nearLat: nearLat, nearLon: nearLon);
  }

  /// 按与基准点的距离升序排序（纯函数，便于测试）。
  /// 未传基准点时原样返回（防御：保持原顺序）。
  static List<SearchResult> sortByDistance(List<SearchResult> results,
      {double? nearLat, double? nearLon}) {
    if (nearLat == null || nearLon == null) return results;
    final out = [...results];
    out.sort((a, b) => haversineM(nearLat, nearLon, a.lat, a.lon)
        .compareTo(haversineM(nearLat, nearLon, b.lat, b.lon)));
    return out;
  }

  /// haversine 球面距离（米）。本地实现，不依赖导出层。
  static double haversineM(double la1, double lo1, double la2, double lo2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(la2 - la1);
    final dLon = rad(lo2 - lo1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(la1)) * math.cos(rad(la2)) *
            math.sin(dLon / 2) * math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static Future<List<SearchResult>> _nominatim(String q) async {
    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?format=json&limit=6&q='
        '${Uri.encodeQueryComponent(q)}');
    final res = await http.get(url, headers: const {
      'User-Agent': 'HuaZhouCloudMap/3.0 (search)',
    }).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('nominatim http ${res.statusCode}');
    }
    final arr = jsonDecode(res.body) as List;
    final out = <SearchResult>[];
    for (final o in arr.cast<Map<String, dynamic>>()) {
      final lat = double.tryParse((o['lat'] as String?) ?? '');
      final lon = double.tryParse((o['lon'] as String?) ?? '');
      if (lat == null || lon == null) continue;
      final disp = (o['display_name'] as String?) ?? '';
      out.add(SearchResult(
        name: (o['name'] as String?) ?? disp,
        address: disp,
        lat: lat,
        lon: lon,
      ));
    }
    return out;
  }

  static Future<List<SearchResult>> _photon(String q) async {
    final url = Uri.parse(
        'https://photon.komoot.io/api/?limit=6&q=${Uri.encodeQueryComponent(q)}');
    final res = await http.get(url, headers: const {
      'User-Agent': 'HuaZhouCloudMap/3.0 (search)',
    }).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('photon http ${res.statusCode}');
    }
    final jo = jsonDecode(res.body) as Map<String, dynamic>;
    final features = (jo['features'] as List?) ?? const [];
    final out = <SearchResult>[];
    for (final f in features.cast<Map<String, dynamic>>()) {
      final geom = f['geometry'] as Map<String, dynamic>?;
      final coords = (geom?['coordinates'] as List?) ?? const [];
      if (coords.length < 2) continue;
      final lon = (coords[0] as num?)?.toDouble();
      final lat = (coords[1] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      final p = (f['properties'] as Map<String, dynamic>?) ?? {};
      final name = (p['name'] as String?) ?? '';
      final parts = [
        p['street'],
        p['city'],
        p['county'],
        p['state'],
        p['country'],
      ].where((e) => e != null && e.toString().isNotEmpty).toList();
      out.add(SearchResult(
        name: name.isEmpty ? parts.join(' · ') : name,
        address: parts.join(' · '),
        lat: lat,
        lon: lon,
      ));
    }
    return out;
  }
}
