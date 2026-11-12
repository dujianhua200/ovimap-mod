import 'dart:convert';

import 'package:http/http.dart' as http;

import '../geo/gcj02.dart';
import 'tianditu.dart';

/// 内置高德 Web 服务 key（单一来源；`AppState.builtinAmapKey` 引用本常量）。
///
/// ⚠️ **仓库已公开，内置 key 一律不入库**（v3.9.2）：本常量保留但为空串，
/// 未配置时相关功能走「未配置」提示（绝不静默失败）。
/// 自己在「更多 → 高德 Key 设置」里填一次即可，用户值优先级最高。
const String kBuiltinAmapKey = '';

/// 高德 Web 服务 API 客户端（第二十批新增，替代/优先于天地图的搜索与地名兜底）。
///
/// 与 [TiandituClient] 同口径：
/// - 返回 [SearchResult]（点：name / address / lat / lon），便于搜索源互换；
/// - 高德返回坐标为 **GCJ-02**，出口统一过 `Gcj02Converter.gcj02ToWgs84`
///   转为 WGS-84（可用 [convertGcj] 关闭以对照原始返回）。
///
/// 接口：
/// - 关键字搜索 `v5/place/text`：`keywords`、`region`+`city_limit`、
///   `location=<lng,lat>` + `sortrule=distance`（离基准点最近优先）；
/// - 矩形区域搜索 `v5/place/polygon`：`polygon=<lng,lat|lng,lat>`，
///   用于 DXF 底图地名兜底（OSM 地名为空时补名）。
///
/// 失败一律抛带中文/原始 info 的异常——**绝不静默返回空**（与既有语义一致）。
class AmapClient {
  AmapClient._();

  /// 可注入的 HTTP GET 钩子（仅供测试零网络 mock 用；null 时用真实 http.get）。
  static Future<http.Response> Function(Uri url)? httpGetOverride;

  /// 高德 Web 服务根地址（HTTPS）。
  static const String baseUrl = 'https://restapi.amap.com';

  /// 单请求超时（秒）：高德响应快，超时即降级到下一搜索源，不卡 UI。
  static const Duration defaultTimeout = Duration(seconds: 8);

  /// 成功状态码（`status == '1'` 且 `infocode == '10000'`）。
  static const String okStatus = '1';
  static const String okInfocode = '10000';

  /// 关键字搜索（v5/place/text）。
  ///
  /// [key] 为高德 Web 服务 key（一般由 `AppState.amapKey` 给出：用户自配优先，
  /// 未配置则回退到内置 [kBuiltinAmapKey]；传入空串则不启用本源）。
  /// [region] 为可选城市（中文/城市编码），配合 [cityLimit] 限定在该城市内。
  /// [nearLat]/[nearLon] 为 WGS-84 基准点（一般传当前地图中心）：传入后按
  /// `sortrule=distance` 让高德按距离排序返回（离用户最近的排最前）。
  /// [convertGcj] 为 true（默认）时把返回的 GCJ-02 坐标纠偏为 WGS-84。
  static Future<List<SearchResult>> search(
    String q,
    String key, {
    String region = '',
    bool cityLimit = false,
    double? nearLat,
    double? nearLon,
    int pageSize = 10,
    bool convertGcj = true,
  }) async {
    final params = <String, String>{
      'key': key,
      'keywords': q,
      'page_size': '$pageSize',
      'page_num': '1',
    };
    final reg = region.trim();
    if (reg.isNotEmpty) {
      params['region'] = reg;
      params['city_limit'] = cityLimit ? 'true' : 'false';
    }
    // 高德 location 参数顺序为 "经度,纬度"；基准点为 WGS-84，高德按 GCJ-02 计算距离，
    // 故先把基准点正向加密为 GCJ-02（同城量级偏差不影响排序结果）。
    if (nearLat != null && nearLon != null) {
      final gcj = Gcj02Converter.wgs84ToGcj02(nearLat, nearLon);
      params['location'] = '${gcj[1]},${gcj[0]}';
      params['sortrule'] = 'distance';
    }
    final uri = Uri.https(
      'restapi.amap.com',
      '/v5/place/text',
      params,
    );
    return _query(uri, convertGcj);
  }

  /// 矩形区域 POI 搜索（v5/place/polygon），用于 DXF 底图**地名兜底**。
  ///
  /// [bbox] = `[minLat, minLon, maxLat, maxLon]`（**WGS-84**）。
  ///
  /// **坐标系（关键修复）**：高德按 **GCJ-02** 解读 `polygon` 顶点，而 [bbox] 是
  /// WGS-84。若直接拿 WGS 值拼串，检索区会整体偏移（实测约 600m）——**漏掉框内
  /// 东北侧名字、多收西南侧约 600m 外的名字**。故在 [convertGcj] 为 true 时，先把
  /// bbox 的**四个角点分别** `Gcj02Converter.wgs84ToGcj02`（经纬偏移随位置缓慢变化，
  /// 四角独立转换、取分量极值构成覆盖框，不做两点外推），再拼
  /// 「左下(lng,lat)|右上(lng,lat)」两个顶点。
  /// [convertGcj] 为 false 时保持 WGS 原值（"原样返回"语义，用于对照/测试）。
  /// [keywords] 为关键字（如「小区」）；[types] 为高德 POI 类型编码（可空）。
  static Future<List<SearchResult>> poiInBounds(
    List<double> bbox,
    String keywords,
    String key, {
    String types = '',
    int pageSize = 20,
    bool convertGcj = true,
  }) async {
    // 四角点：左下/右下/左上/右上（[lat, lon]）。
    final corners = <List<double>>[
      [bbox[0], bbox[1]],
      [bbox[0], bbox[3]],
      [bbox[2], bbox[1]],
      [bbox[2], bbox[3]],
    ];
    var latMinG = 90.0, latMaxG = -90.0, lonMinG = 180.0, lonMaxG = -180.0;
    for (final c in corners) {
      final p = convertGcj
          ? Gcj02Converter.wgs84ToGcj02(c[0], c[1])
          : [c[0], c[1]];
      if (p[0] < latMinG) latMinG = p[0];
      if (p[0] > latMaxG) latMaxG = p[0];
      if (p[1] < lonMinG) lonMinG = p[1];
      if (p[1] > lonMaxG) lonMaxG = p[1];
    }
    final params = <String, String>{
      'key': key,
      'polygon': '$lonMinG,$latMinG|$lonMaxG,$latMaxG',
      'page_size': '$pageSize',
      'page_num': '1',
    };
    final kw = keywords.trim();
    if (kw.isNotEmpty) params['keywords'] = kw;
    final ty = types.trim();
    if (ty.isNotEmpty) params['types'] = ty;
    final uri = Uri.https('restapi.amap.com', '/v5/place/polygon', params);
    return _query(uri, convertGcj);
  }

  /// 发起一次请求并解析（含状态码校验与 GCJ 纠偏出口）。
  static Future<List<SearchResult>> _query(Uri uri, bool convertGcj) async {
    final get = httpGetOverride ?? http.get;
    final res = await get(uri).timeout(defaultTimeout);
    if (res.statusCode != 200) {
      throw Exception('amap http ${res.statusCode}');
    }
    final jo = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final status = (jo['status'] as String?) ?? '';
    final infocode = (jo['infocode'] as String?) ?? '';
    final info = (jo['info'] as String?) ?? '';
    if (status != okStatus || (infocode.isNotEmpty && infocode != okInfocode)) {
      throw Exception('amap $infocode $info');
    }
    final out = <SearchResult>[];
    for (final p in (jo['pois'] as List?) ?? const []) {
      if (p is! Map<String, dynamic>) continue;
      final ll = parseLocation((p['location'] as String?) ?? '');
      if (ll == null) continue;
      final name = (p['name'] as String?)?.trim() ?? '';
      if (name.isEmpty) continue;
      // 高德返回 GCJ-02；出口统一纠偏为 WGS-84（app 内存储同系）。
      final wgs = convertGcj ? Gcj02Converter.gcj02ToWgs84(ll[0], ll[1]) : ll;
      out.add(SearchResult(
        name: name,
        address: (p['address'] as String?)?.trim() ?? '',
        lat: wgs[0],
        lon: wgs[1],
      ));
    }
    return out;
  }

  /// `"经度,纬度"` → `[纬度, 经度]`，解析失败返回 null。
  static List<double>? parseLocation(String s) {
    if (!s.contains(',')) return null;
    final parts = s.split(',');
    final lon = double.tryParse(parts[0].trim());
    final lat = double.tryParse(parts[1].trim());
    if (lat == null || lon == null) return null;
    return [lat, lon];
  }
}
