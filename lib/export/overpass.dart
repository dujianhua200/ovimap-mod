import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'basemap.dart';

/// 一次竞速的结果（原文 + 是否"空答案兜底"），供上层区分
/// "该范围确实无数据"与"数据源异常/疑似镜像故障"。
class OverpassFetchResult {
  /// 应答原文（Overpass JSON）。
  final String body;

  /// 是否为"所有端点都返回空答案 → 用空答案收场"。
  ///
  /// true 时上层应提示"数据源返回空（疑似镜像故障），建议重试"，
  /// 而不是"该范围内无数据"。
  final bool emptyFallback;

  /// 本轮中**硬失败**（HTTP 非 200 / 超时 / 连接失败 / 非数据应答）的端点数。
  ///
  /// 与 [emptyFallback] 一起用于判断是否值得再抢一轮（O1）：
  /// "有端点压根没答上来 + 只能拿空答案收场" ⇒ 值得重试；
  /// "所有端点都是 200 空" ⇒ 该范围确实无数据，重试只是白等。
  final int hardFailures;

  const OverpassFetchResult(
    this.body, {
    this.emptyFallback = false,
    this.hardFailures = 0,
  });
}

/// OSM Overpass 客户端：**只负责竞速取数**与**纯解析**（缓存/编排在 basemap.dart）。
class OverpassClient {
  OverpassClient._();

  // ---- 查询构造 ----

  static String buildRoadsQuery(String bbox) =>
      '[out:json][timeout:25];(way["highway"]($bbox););out geom;';

  static String buildBuildingsQuery(String bbox) =>
      '[out:json][timeout:25];'
      '(way["building"]($bbox);relation["building"]($bbox););out geom;';

  /// 周边要素查询（第二十八批）：**电力线 + 水系沟渠**。
  ///
  /// 通信线路设计要看与电力杆线的交越/平行关系、过河过沟位置；OSM 这两类
  /// 覆盖远好于建筑，加上后"矢量太少"的观感明显改善。
  static String buildExtrasQuery(String bbox) =>
      '[out:json][timeout:25];'
      '(way["power"="line"]($bbox);way["power"="minor_line"]($bbox);'
      'way["power"="cable"]($bbox);'
      'way["waterway"]($bbox);way["natural"="water"]($bbox););out geom;';

  /// 解析电力/水系要素（只取带几何的 way）。
  static List<ExtraPoly> parseExtras(String body) {
    final out = <ExtraPoly>[];
    final root = jsonDecode(body) as Map<String, dynamic>;
    for (final e in (root['elements'] as List? ?? const [])) {
      if (e is! Map) continue;
      final geom = e['geometry'];
      if (geom is! List || geom.length < 2) continue;
      final pts = <List<double>>[];
      for (final g in geom) {
        if (g is! Map) continue;
        final la = (g['lat'] as num?)?.toDouble();
        final lo = (g['lon'] as num?)?.toDouble();
        if (la == null || lo == null) continue;
        pts.add([la, lo]);
      }
      if (pts.length < 2) continue;
      final tags = Map<String, dynamic>.from(e['tags'] as Map? ?? const {});
      final kind = (tags['power'] != null)
          ? 'power'
          : ((tags['waterway'] != null || tags['natural'] == 'water') ? 'water' : '');
      if (kind.isEmpty) continue;
      final name = (tags['name'] ?? '') as String? ?? '';
      out.add(ExtraPoly(pts, kind, name));
    }
    return out;
  }

  /// 地名/片区/小区名查询（place=* + 具名 landuse=residential）。
  static String buildPlacesQuery(String bbox) =>
      '[out:json][timeout:25];'
      '(node["place"]($bbox);way["place"]($bbox);relation["place"]($bbox);'
      'way["landuse"="residential"]["name"]($bbox);'
      'relation["landuse"="residential"]["name"]($bbox););out center tags;';

  // ---- 网络层：并行竞速取数（首个成功即返回原文） ----

  /// 可注入的 HTTP GET 钩子（仅供测试零网络 mock 用；null 时用真实 http.get）。
  static Future<http.Response> Function(Uri url, {Map<String, String>? headers})?
      httpGetOverride;

  /// 单端点默认超时（第二十批：15s → 12s）。
  ///
  /// 实测：不可达/繁忙镜像会挂到 25s 才失败（甚至 11.7s 才回 504），
  /// 把"首个成功即返回"的竞速拖成串行等待；12s 未响应即放弃该端点
  /// （其它端点仍在跑），整体最坏耗时可控。
  static const Duration defaultTimeout = Duration(seconds: 12);

  /// 全端点失败后的重试次数（默认 1 次，间隔 1.2s）。
  static const int defaultRetries = 1;
  static const Duration retryDelay = Duration(milliseconds: 1200);

  /// 重试轮的单端点超时倍数：**首轮求快、重试轮求成**。
  ///
  /// 实测 mail.ru 镜像偶发 18.9s 才回 200——首轮 12s 会放弃它，
  /// 但既然已经进入重试（说明快的都没成），多等一会儿更可能拿到数据。
  static const int retryTimeoutFactor = 2;

  /// 并行请求全部端点，取最先成功者；**必要时整轮重试 [retries] 次**。
  ///
  /// 竞速语义不变（首个**有数据**的成功者即返回，慢端点不阻塞）。两种情形会再跑一轮：
  /// 1. 整轮全灭（抛异常）→ 重试（既有策略）；
  /// 2. **有端点硬失败 + 只能拿空答案收场**（O1）→ 重试一轮
  ///    （如"主站 504 一片 + 仅一个镜像回了空"，重试很可能救回数据）。
  ///
  /// **不重试**的情形：所有端点都是 200 且都返回空集 —— 那是该范围确实无数据，
  /// 重试只是白等 12~24s × 3 个数据集（QA 明确要求的防劣化约束）。
  static Future<OverpassFetchResult> fetchRawDetailed(
    String query, {
    List<String>? endpoints,
    Duration timeout = defaultTimeout,
    int retries = defaultRetries,
  }) async {
    final eps = (endpoints == null || endpoints.isEmpty)
        ? OverpassEndpoints.builtin()
        : endpoints;
    Object? lastErr;
    for (var attempt = 0; attempt <= retries; attempt++) {
      final t = attempt == 0
          ? timeout
          : timeout * retryTimeoutFactor; // 重试轮更耐心
      try {
        final r = await _raceOnce(query, eps, t);
        // O1：**只在"有端点硬失败 + 只能拿空答案收场"时再抢一轮**。
        // 典型场景：主站忙时 4 个 504、仅 1 个镜像回了空 —— 这时重试很可能救回数据；
        // 而"所有端点都是 200 空"= 该范围确实无数据，重试只是白等 12~24s × 3 个数据集。
        final worthRetry = r.emptyFallback && r.hardFailures > 0;
        if (!worthRetry || attempt == retries) return r;
      } catch (e) {
        lastErr = e;
        if (attempt == retries) {
          throw HttpException(
              'overpass 所有端点均失败（已重试 $retries 次）: $lastErr');
        }
      }
      await Future<void>.delayed(retryDelay);
    }
    // 防御：正常不会走到这里（循环内必返回或抛出）。
    throw HttpException('overpass 取数失败（已重试 $retries 次）: $lastErr');
  }

  /// 并行请求全部端点，取最先成功者；**全端点失败后整轮重试 [retries] 次**。
  ///
  /// 竞速语义不变（首个成功即返回，慢端点不阻塞），只在"整轮全灭"时补一次重试，
  /// 把偶发网络抖动导致的"导不出建筑/道路"救回来；仍失败才抛异常（由调用方降级）。
  static Future<String> fetchRaw(
    String query, {
    List<String>? endpoints,
    Duration timeout = defaultTimeout,
    int retries = defaultRetries,
  }) async =>
      (await fetchRawDetailed(
        query,
        endpoints: endpoints,
        timeout: timeout,
        retries: retries,
      ))
          .body;

  /// 一轮竞速：全部端点并行，首个**有数据**的成功者胜出；全灭则抛异常。
  ///
  /// 空答案（`elements: []`）不立即胜出，仅当**所有端点都失败或都返回空**时才用它收场
  /// （见 _raceOnce 内第二道闸注释）。这样既拦住"空壳镜像抢答"，又保留
  /// "该范围确实无数据"的正常路径（由 [OverpassFetchResult.emptyFallback] 区分）。
  static Future<OverpassFetchResult> _raceOnce(
      String query, List<String> eps, Duration timeout) {
    final c = Completer<OverpassFetchResult>();
    /// 已结算（失败 + 空答案）的端点数。
    var settled = 0;
    /// 硬失败（非 200 / 超时 / 连接失败 / 非数据应答）的端点数。
    var hardFailures = 0;
    /// 首个空答案原文（兜底用）。
    String? emptyBody;
    Object? lastErr;
    for (final base in eps) {
      () async {
        try {
          final urlStr = '$base?data=${Uri.encodeQueryComponent(query)}';
          final get = httpGetOverride ?? http.get;
          final res = await get(Uri.parse(urlStr), headers: const {
            'User-Agent': 'HuaZhouCloudMap/3.0 (map export)',
          }).timeout(timeout);
          if (res.statusCode != 200 || res.body.isEmpty) {
            throw HttpException('overpass http ${res.statusCode} ($base)');
          }
          // 第一道闸：200 也可能是错误页/限流提示——正常应答必含 `"elements"`。
          if (!res.body.contains('"elements"')) {
            throw HttpException('overpass 非数据应答 ($base)');
          }
          // 第二道闸（P0 修复）：**空数据集不得赢下竞速**。
          // 实测 `overpass.osm.ch` 常年返回 `{"elements":[]}`（数据库时间戳非法值 "34"，
          // 全局故障）且**最快**（1.0s）——它一抢答就 "谎报成功 + 0 条道路/建筑"，
          // 且用户点「重试抓取」也救不回来。故空答案只作兜底暂存，继续等其它端点。
          if (hasEmptyElements(res.body)) {
            emptyBody ??= res.body;
            settled++;
            if (settled == eps.length && !c.isCompleted) {
              c.complete(OverpassFetchResult(emptyBody!,
                  emptyFallback: true, hardFailures: hardFailures));
            }
            return;
          }
          if (!c.isCompleted) {
            c.complete(OverpassFetchResult(res.body, hardFailures: hardFailures));
          }
        } catch (e) {
          lastErr = e;
          hardFailures++;
          settled++;
          if (settled == eps.length && !c.isCompleted) {
            if (emptyBody != null) {
              // 全灭但有过空答案 → 用空答案收场（ok + count 0 + emptyFallback）
              c.complete(OverpassFetchResult(emptyBody!,
                  emptyFallback: true, hardFailures: hardFailures));
            } else {
              c.completeError(HttpException('overpass 所有端点均失败: $lastErr'));
            }
          }
        }
      }();
    }
    return c.future;
  }

  /// 判断应答是否为**空数据集**（`"elements": []`）。
  ///
  /// 轻量正则（兼容压缩/美化两种排版），避免对 MB 级应答做整份 jsonDecode。
  static final RegExp _emptyElements = RegExp(r'"elements"\s*:\s*\[\s*\]');

  /// 应答是否为 Overpass 的"空数据集"（有 elements 但 0 条）。
  static bool hasEmptyElements(String body) => _emptyElements.hasMatch(body);

  // ---- 纯解析 ----

  /// 解析道路。**N1 修复**：仅丢弃**无名**的
  /// `footway/steps/cycleway/pedestrian/bridleway`；**无名 service/track/path/
  /// residential/... 一律保留**（小区内部路网），不再出现"丢弃又赋宽"的死逻辑。
  static List<RoadPoly> parseRoads(String json) {
    final list = <RoadPoly>[];
    final seen = <String>{};
    final root = jsonDecode(json) as Map<String, dynamic>;
    final elements = root['elements'] as List?;
    if (elements == null) return list;
    const dropWhenUnnamed = <String>{
      'footway', 'steps', 'cycleway', 'pedestrian', 'bridleway'
    };
    for (final el in elements.cast<Map<String, dynamic>>()) {
      final geom = el['geometry'] as List?;
      if (geom == null || geom.length < 2) continue;
      final pts = <List<double>>[];
      for (final g in geom.cast<Map<String, dynamic>>()) {
        pts.add([
          (g['lat'] as num).toDouble(),
          (g['lon'] as num).toDouble(),
        ]);
      }
      final tags = (el['tags'] as Map?)?.cast<String, dynamic>() ?? {};
      final hw = (tags['highway'] as String?) ?? '';
      final name = (tags['name'] as String?) ?? '';
      if (name.isEmpty && dropWhenUnnamed.contains(hw)) continue;
      final grade = gradeOf(hw);
      // 去重：同名 + 首尾点近似相同视为重复
      final key = '$name|${_qk(pts.first)}|${_qk(pts.last)}';
      if (name.isNotEmpty && !seen.add(key)) continue;
      list.add(RoadPoly(pts, grade, name));
    }
    return list;
  }

  /// `highway` 标签 → [RoadGrade]（含 `*_link` 归入上级）。
  static RoadGrade gradeOf(String hw) {
    switch (hw) {
      case 'motorway':
      case 'trunk':
      case 'motorway_link':
      case 'trunk_link':
        return RoadGrade.trunk;
      case 'primary':
      case 'primary_link':
        return RoadGrade.primary;
      case 'secondary':
      case 'secondary_link':
        return RoadGrade.secondary;
      case 'tertiary':
      case 'tertiary_link':
        return RoadGrade.tertiary;
      case 'residential':
      case 'unclassified':
      case 'living_street':
        return RoadGrade.residential;
      case 'service':
      case 'track':
      case 'path':
        return RoadGrade.service;
      default:
        return RoadGrade.other;
    }
  }

  /// 解析建筑。**N2 修复**：`way` 取单环；`relation` **按 role 缝合成闭合环**，
  /// **每个外环输出一个 [BuildingPoly]**（内环作孔）。
  static List<BuildingPoly> parseBuildings(String json) {
    final out = <BuildingPoly>[];
    final root = jsonDecode(json) as Map<String, dynamic>;
    final elements = root['elements'] as List?;
    if (elements == null) return out;
    for (final el in elements.cast<Map<String, dynamic>>()) {
      final tags = (el['tags'] as Map?)?.cast<String, dynamic>() ?? {};
      final name = (tags['name'] as String?) ?? '';
      final type = (el['type'] as String?) ?? 'way';
      if (type == 'relation') {
        final members = el['members'] as List?;
        if (members == null) continue;
        final outerSegs = <List<List<double>>>[];
        final innerSegs = <List<List<double>>>[];
        for (final m in members.cast<Map<String, dynamic>>()) {
          final role = (m['role'] as String?) ?? 'outer';
          final geom = m['geometry'] as List?;
          if (geom == null || geom.length < 2) continue;
          final seg = <List<double>>[];
          for (final g in geom.cast<Map<String, dynamic>>()) {
            seg.add([
              (g['lat'] as num).toDouble(),
              (g['lon'] as num).toDouble(),
            ]);
          }
          if (role == 'inner') {
            innerSegs.add(seg);
          } else {
            outerSegs.add(seg);
          }
        }
        final outerRings = _stitchRings(outerSegs);
        final innerRings = _stitchRings(innerSegs);
        for (final ring in outerRings) {
          if (ring.length < 3) continue;
          if (name.isEmpty && _ringSpanM(ring) < 4) continue;
          final holes = <List<List<double>>>[];
          for (final h in innerRings) {
            if (h.length >= 3 && _pointInRing(_centroid(h), ring)) holes.add(h);
          }
          out.add(BuildingPoly([ring, ...holes], name));
        }
      } else {
        final geom = el['geometry'] as List?;
        if (geom == null || geom.length < 3) continue;
        final ring = <List<double>>[];
        for (final g in geom.cast<Map<String, dynamic>>()) {
          ring.add([
            (g['lat'] as num).toDouble(),
            (g['lon'] as num).toDouble(),
          ]);
        }
        if (ring.length < 3) continue;
        if (name.isEmpty && _ringSpanM(ring) < 4) continue;
        out.add(BuildingPoly([ring], name));
      }
    }
    return out;
  }

  /// 解析地名（`place=*` 点/面 + 具名 `landuse=residential`）。
  /// `way/relation` 用 `out center` 的 `center` 作落点。
  static List<PlaceFeature> parsePlaces(String json) {
    final out = <PlaceFeature>[];
    final root = jsonDecode(json) as Map<String, dynamic>;
    final elements = root['elements'] as List?;
    if (elements == null) return out;
    for (final el in elements.cast<Map<String, dynamic>>()) {
      final tags = (el['tags'] as Map?)?.cast<String, dynamic>() ?? {};
      final name = (tags['name'] as String?) ?? '';
      if (name.isEmpty) continue;
      double? lat, lon;
      if (el['lat'] != null && el['lon'] != null) {
        lat = (el['lat'] as num).toDouble();
        lon = (el['lon'] as num).toDouble();
      } else if (el['center'] != null) {
        final c = el['center'] as Map;
        lat = (c['lat'] as num).toDouble();
        lon = (c['lon'] as num).toDouble();
      }
      if (lat == null || lon == null) continue;
      final place = (tags['place'] as String?) ?? '';
      final landuse = (tags['landuse'] as String?) ?? '';
      final PlaceLevel level;
      final bool isArea;
      if (place.isNotEmpty) {
        level = placeLevelOf(place);
        isArea = (el['type'] as String?) != 'node';
      } else if (landuse == 'residential') {
        level = PlaceLevel.residential;
        isArea = true;
      } else {
        continue;
      }
      out.add(PlaceFeature(
        name: name,
        lat: lat,
        lon: lon,
        level: level,
        isArea: isArea,
      ));
    }
    return out;
  }

  /// `place` 标签 → [PlaceLevel]。
  static PlaceLevel placeLevelOf(String p) {
    switch (p) {
      case 'city':
        return PlaceLevel.city;
      case 'suburb':
      case 'quarter':
      case 'borough':
      case 'city_block':
        return PlaceLevel.suburb;
      case 'neighbourhood':
      case 'neighborhood':
        return PlaceLevel.neighbourhood;
      case 'town':
        return PlaceLevel.town;
      case 'village':
        return PlaceLevel.village;
      case 'hamlet':
        return PlaceLevel.hamlet;
      case 'residential':
        return PlaceLevel.residential;
      default:
        return PlaceLevel.neighbourhood;
    }
  }

  // ---- 几何工具 ----

  /// 按端点量化匹配贪心缝合线段为闭合环（relation 多环修复）。
  static List<List<List<double>>> _stitchRings(List<List<List<double>>> segs) {
    const tol = 1e-7; // ≈1cm，Overpass 共享节点坐标应精确一致
    final rings = <List<List<double>>>[];
    final unused = List<List<List<double>>>.from(segs);
    while (unused.isNotEmpty) {
      var cur = List<List<double>>.from(unused.removeAt(0));
      var extended = true;
      while (extended) {
        extended = false;
        for (var i = 0; i < unused.length; i++) {
          final seg = unused[i];
          if (_samePt(cur.last, seg.first, tol)) {
            cur = [...cur, ...seg.skip(1)];
          } else if (_samePt(cur.last, seg.last, tol)) {
            cur = [...cur, ...seg.reversed.skip(1)];
          } else if (_samePt(cur.first, seg.last, tol)) {
            cur = [...seg.sublist(0, seg.length - 1), ...cur];
          } else if (_samePt(cur.first, seg.first, tol)) {
            cur = [...seg.reversed.skip(1), ...cur];
          } else {
            continue;
          }
          unused.removeAt(i);
          extended = true;
          break;
        }
      }
      if (cur.length >= 3) {
        if (_samePt(cur.first, cur.last, tol)) {
          cur = cur.sublist(0, cur.length - 1);
        }
        if (cur.length >= 3) rings.add(cur);
      }
    }
    return rings;
  }

  static bool _samePt(List<double> a, List<double> b, double tol) =>
      (a[0] - b[0]).abs() <= tol && (a[1] - b[1]).abs() <= tol;

  /// 环的最大跨度（米），用于丢弃无名的极小碎片。
  static double _ringSpanM(List<List<double>> ring) {
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in ring) {
      if (p[0] < minLat) minLat = p[0];
      if (p[0] > maxLat) maxLat = p[0];
      if (p[1] < minLon) minLon = p[1];
      if (p[1] > maxLon) maxLon = p[1];
    }
    final w = (maxLon - minLon) * 111320 * math.cos(minLat * math.pi / 180).abs();
    final h = (maxLat - minLat) * 110540;
    return math.max(w, h);
  }

  /// 环几何中心（顶点平均）。
  static List<double> _centroid(List<List<double>> ring) {
    var lat = 0.0, lon = 0.0;
    for (final p in ring) {
      lat += p[0];
      lon += p[1];
    }
    return [lat / ring.length, lon / ring.length];
  }

  /// 射线法点是否在环内。
  static bool _pointInRing(List<double> pt, List<List<double>> ring) {
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final xi = ring[i][1], yi = ring[i][0];
      final xj = ring[j][1], yj = ring[j][0];
      final intersect = ((yi > pt[0]) != (yj > pt[0])) &&
          (pt[1] < (xj - xi) * (pt[0] - yi) / ((yj - yi) + 1e-15) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  /// 坐标量化到 ~10m，用于近似端点判重。
  static String _qk(List<double> latlon) =>
      '${(latlon[0] * 10000).round()}_${(latlon[1] * 10000).round()}';
}

/// Overpass 端点解析（内置候选 + 用户自定义）。
class OverpassEndpoints {
  OverpassEndpoints._();

  /// 内置候选端点（第二十批 P0 修复，逐条实测 `way["highway"]` 取数结果）。
  ///
  /// 保留（实测能返回真实数据）：
  /// - `overpass-api.de` 主站（65 条 / 2.3~14s，忙时会 504）
  /// - `overpass.kumi.systems`（抖动可用：200/6.8s 与 504 交替）
  /// - `maps.mail.ru`（65 条 / 1.8~19s）
  /// - `overpass.openstreetmap.fr`（65 条 / 2.8s）★新验证
  /// - `z.overpass-api.de`（主站备用前端，65 条 / 3.2s）★新验证
  ///
  /// 已全部移除（见 [retired]）：空壳抢答的 `osm.ch`、已死的 `openstreetmap.ru` /
  /// `osm.jp`、长期超时的 `private.coffee`。
  static const List<String> _builtin = [
    // 自建反代（用户指定内置，默认首位）：国内直连最快，成功即免连境外。
    // ⚠️ 路径是 `/interpreter`（不含 /api）——v3.5 曾错记为 `/api/interpreter`，
    // 该路径恒 521，导致反代从未真正生效。实测 2026-09-20：小范围查询
    // 稳定返回（Overpass 0.7.62）；超大查询该 Worker 会 521，由竞速机制
    // 自然回落到下面的境外端点，不影响可用性。
    'https://hzyt.hainasi.eu.org/interpreter',
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
    'https://overpass.openstreetmap.fr/api/interpreter',
    'https://z.overpass-api.de/api/interpreter',
  ];

  // ===================== 已下线端点（仅供测试/诊断对照，绝不参与抓取） =====================

  /// 长期超时/不可达的个人站（白占并发槽且常挂到 25s）。
  static const String retiredPrivateCoffee =
      'https://overpass.private.coffee/api/interpreter';

  /// **空壳镜像（P0 元凶）**：恒返回 `{"elements":[]}`、`timestamp_osm_base:"34"`
  /// （非法值 ⇒ 实例数据库无数据），且响应最快（≈1.0s）→ 抢答导致 0 道路/0 建筑。
  static const String retiredOsmCh =
      'https://overpass.osm.ch/api/interpreter';

  /// 已死：3/3 TCP 挂 10s（还低于 12s 超时，白白占满整个竞速窗口）。
  static const String retiredOsmRu =
      'https://overpass.openstreetmap.ru/api/interpreter';

  /// 已死：3/3 秒拒。
  static const String retiredOsmJp =
      'https://overpass.osm.jp/api/interpreter';

  /// 已下线端点全集（测试用于断言"这些端点绝不能再出现在候选列表里"）。
  static const List<String> retired = [
    retiredPrivateCoffee,
    retiredOsmCh,
    retiredOsmRu,
    retiredOsmJp,
  ];

  /// 内置候选端点（返回副本，调用方可安全增删）。
  static List<String> builtin() => List<String>.from(_builtin);

  /// 拆分用户自定义端点原文（支持换行 / 逗号 / 分号多分隔符；忽略空白与空行）。
  ///
  /// **保序**：按用户输入出现顺序返回（去重交由 [resolve] 统一处理）。
  static List<String> splitCustom(String raw) => raw
      .split(RegExp(r'[\r\n,;]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  /// 单个端点地址是否合法：必须以 `http://` 或 `https://` 开头。
  ///
  /// 用户搭的 Cloudflare Worker / 自建反代地址必为 http(s)，
  /// 借此拦住"忘了写协议头"（如 `ovp.xxx.com`）这类最常见的手误。
  static bool isValidEndpoint(String url) {
    final t = url.trim();
    return t.startsWith('http://') || t.startsWith('https://');
  }

  /// 解析生效端点列表：**用户自定义在前、内置在后**（去重、保序）。
  ///
  /// 用户配自定义端点的目的就是**优先走自建反代**（Cloudflare Worker 等，
  /// 绕开境外直连的慢与不稳），内置镜像退居兜底。故自定义条目排在最前，
  /// 竞速时"首个成功即返回"，反代可用时即刻命中。
  ///
  /// `resolve('')` 与 [builtin] 完全等价（无自定义 ⇒ 只剩内置、顺序不变），
  /// 保证"未配置"路径行为与既有完全一致。
  static List<String> resolve(String userCustom) {
    final out = <String>[];
    for (final e in splitCustom(userCustom)) {
      if (!out.contains(e)) out.add(e);
    }
    for (final b in _builtin) {
      if (!out.contains(b)) out.add(b);
    }
    return out;
  }
}
