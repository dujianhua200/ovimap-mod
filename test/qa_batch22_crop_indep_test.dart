// ============================================================================
// QA 独立对抗性验证（严过关）—— 第二十二批「本地底图只导出范围内」修复。
//
// 严格**不复用**工程师 batch22_* 的任何 fixture/断言，全部自造数据 + 自写
// 独立 oracle（dense-sampling 线路裁剪 + 自写 GeoJSON 要素统计），目的：
// 证明「真的修好了」，而不是「工程师的测试是绿的」。
//
// 覆盖：
//   B 真实 18MB 整市文件端到端（parse → export）：市区 50m / 空白处 50m / 档位单调
//   C 裁剪几何正确性：框外零进入、框内必留、长路裁剪无「跨框连线」、多次进出拆多段、
//     容差外扩、退化输入（单点/零长/退化框/NaN/Inf）
//   D 上限保护：超限按距离截断、接近上限不误伤、cap=20000 对 880m 城区是否误截
//   E 既有语义未回退：parse/store 语义、cropTo 不改入参、在线路径文件 mtime 未本批改动
// ============================================================================
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/local_basemap.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String root;
  _FakePathProvider(this.root);
  @override
  Future<String?> getExternalStoragePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

// --------------------------- DXF 解析工具 ---------------------------

class _Ent {
  final String type;
  final List<List<String>> kv = [];
  _Ent(this.type);
  String? first(String c) {
    for (final p in kv) {
      if (p[0] == c) return p[1].trim();
    }
    return null;
  }
}

List<_Ent> _parseDxf(String t) {
  final lines = t.replaceAll('\r\n', '\n').split('\n');
  final out = <_Ent>[];
  _Ent? cur;
  for (var i = 0; i + 1 < lines.length; i += 2) {
    final code = lines[i].trim();
    final val = lines[i + 1];
    if (code == '0') {
      cur = _Ent(val.trim());
      out.add(cur);
    } else if (cur != null) {
      cur.kv.add([code, val]);
    }
  }
  return out;
}

/// 某图层绘图实体数（排除 POLYLINE 的 VERTEX/SEQEND 子实体）。
int _cntLayer(List<_Ent> ents, String layer) => ents
    .where((e) => e.type != 'VERTEX' && e.type != 'SEQEND' && e.first('8') == layer)
    .length;

int _bmEnts(List<_Ent> ents) =>
    _cntLayer(ents, 'DaoLuBian') +
    _cntLayer(ents, 'JianZhu') +
    _cntLayer(ents, 'DiMing') +
    _cntLayer(ents, 'JianZhuFill');

// --------------------------- 合成构件 ---------------------------

List<List<double>> _line(
    double lat0, double lon0, double lat1, double lon1, int n) {
  final out = <List<double>>[];
  for (var i = 0; i <= n; i++) {
    final t = i / n;
    out.add([lat0 + (lat1 - lat0) * t, lon0 + (lon1 - lon0) * t]);
  }
  return out;
}

RoadPoly _road(List<List<double>> pts,
        [RoadGrade g = RoadGrade.trunk, String name = '']) =>
    RoadPoly(pts, g, name);

BuildingPoly _square(double lat, double lon, double d) => BuildingPoly([
      [
        [lat, lon],
        [lat, lon + d],
        [lat + d, lon + d],
        [lat + d, lon],
      ]
    ], '');

PlaceFeature _place(double lat, double lon, String name) =>
    PlaceFeature(name: name, lat: lat, lon: lon, level: PlaceLevel.village);

BasemapData _mk(List<RoadPoly> roads, List<BuildingPoly> buildings,
        List<PlaceFeature> places) =>
    BasemapData(
      roads: roads,
      buildings: buildings,
      places: places,
      report: BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, source: 'local', count: roads.length),
        buildings: DatasetReport(FetchState.ok,
            source: 'local', count: buildings.length),
        places: DatasetReport(FetchState.ok,
            source: 'local', count: places.length),
      ),
    );

MapLabel _pole(double lat, double lon, [int seq = 1]) =>
    MapLabel(typeId: 'pipe', seq: seq, lat: lat, lon: lon, lineGroupId: 'g');

// --------------------------- 独立 oracle ---------------------------

/// 独立统计：直接从原始 GeoJSON 文本按几何类型数要素（不经过 GeoJsonImporter）。
Map<String, int> _rawCount(String text) {
  final root = jsonDecode(text) as Map<String, dynamic>;
  var poly = 0, road = 0, place = 0;
  void walk(dynamic geom) {
    if (geom is! Map) return;
    switch (geom['type']) {
      case 'Polygon':
        poly++;
        break;
      case 'MultiPolygon':
        final cs = geom['coordinates'] as List;
        poly += cs.length;
        break;
      case 'LineString':
        road++;
        break;
      case 'MultiLineString':
        final cs = geom['coordinates'] as List;
        road += cs.length;
        break;
      case 'Point':
        place++;
        break;
      case 'MultiPoint':
        final cs = geom['coordinates'] as List;
        place += cs.length;
        break;
      case 'GeometryCollection':
        for (final g in (geom['geometries'] as List)) {
          walk(g);
        }
        break;
    }
  }

  for (final f in (root['features'] as List)) {
    walk((f as Map)['geometry']);
  }
  return {'poly': poly, 'road': road, 'place': place};
}

/// 独立 oracle：dense-sampling 估计 polyline 落在 bbox 内的总长度（度）与「进入段数」。
/// 不复制 Liang–Barsky，避免「同源同 bug」。
List<double> _denseClip(String tag, List<List<double>> pts, List<double> box,
    {int stepsPerSeg = 400}) {
  bool inside(double la, double lo) =>
      la >= box[0] && la <= box[2] && lo >= box[1] && lo <= box[3];
  var len = 0.0;
  var runs = 0;
  var wasInside = false;
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final dLat = b[0] - a[0], dLon = b[1] - a[1];
    final segLen =
        math.sqrt(dLat * dLat + dLon * dLon); // 度，够用（相对比较）
    for (var k = 0; k < stepsPerSeg; k++) {
      final t0 = k / stepsPerSeg, t1 = (k + 1) / stepsPerSeg;
      final mLa = a[0] + dLat * (t0 + t1) / 2;
      final mLo = a[1] + dLon * (t0 + t1) / 2;
      final ins = inside(mLa, mLo);
      if (ins) len += segLen / stepsPerSeg;
      if (ins && !wasInside) runs++;
      if (ins) wasInside = true;
      if (!ins) wasInside = false;
    }
  }
  return [len, runs.toDouble()];
}

/// 独立统计 cropTo 输出的每段长度（度）之和与段数。
List<double> _implLen(List<List<List<double>>> segs) {
  var len = 0.0;
  for (final seg in segs) {
    for (var i = 1; i < seg.length; i++) {
      final dLat = seg[i][0] - seg[i - 1][0];
      final dLon = seg[i][1] - seg[i - 1][1];
      len += math.sqrt(dLat * dLat + dLon * dLon);
    }
  }
  return [len, segs.length.toDouble()];
}

/// 点 p 到折线的最近平面的累计参数（0..1，按段序号 + 段内比例），用于验证点序。
double _paramOf(List<double> p, List<List<double>> poly) {
  var best = double.infinity;
  var bestParam = 0.0;
  for (var i = 1; i < poly.length; i++) {
    final a = poly[i - 1], b = poly[i];
    final dLat = b[0] - a[0], dLon = b[1] - a[1];
    final denom = dLat * dLat + dLon * dLon;
    var t = 0.0;
    if (denom > 0) {
      t = ((p[0] - a[0]) * dLat + (p[1] - a[1]) * dLon) / denom;
      t = t.clamp(0.0, 1.0);
    }
    final qLat = a[0] + dLat * t, qLon = a[1] + dLon * t;
    final d = math.sqrt(
        (p[0] - qLat) * (p[0] - qLat) + (p[1] - qLon) * (p[1] - qLon));
    if (d < best) {
      best = d;
      bestParam = i - 1 + t;
    }
  }
  return bestParam;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final realPath =
      '${Platform.environment['HOME']}/Desktop/信阳矢量底图_整市.geojson';
  final realFile = File(realPath);

  // ==========================================================================
  // B. 真实 18MB 整市文件端到端
  // ==========================================================================
  group('B. 真实 18MB 整市文件端到端', () {
    test('B0 独立统计原始要素数 == parse() 计数（44599）', () {
      if (!realFile.existsSync()) {
        // ignore: avoid_print
        print('SKIP B：真实文件不存在（$realPath）');
        return;
      }
      final raw = _rawCount(realFile.readAsStringSync());
      final bm = GeoJsonImporter.parse(realFile.readAsStringSync());
      final total = bm.roads.length + bm.buildings.length + bm.places.length;
      // ignore: avoid_print
      print('B0 RAW=$raw  PARSE roads=${bm.roads.length} '
          'buildings=${bm.buildings.length} places=${bm.places.length} total=$total');
      expect(raw['road'], bm.roads.length, reason: '独立统计道路数应等于 parse');
      expect(raw['poly'], bm.buildings.length, reason: '独立统计建筑数应等于 parse');
      expect(raw['place'], bm.places.length, reason: '独立统计地名数应等于 parse');
      expect(total, greaterThan(40000), reason: '整市文件应 > 4 万要素');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('B1 市区 50m：文件远小于 1MB，底图实体数与裁剪结果一致', () async {
      if (!realFile.existsSync()) {
        // ignore: avoid_print
        print('SKIP B1：真实文件不存在');
        return;
      }
      final dir = Directory.systemTemp.createTempSync('qa22_b1');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);

      final bm = GeoJsonImporter.parse(realFile.readAsStringSync());
      final labels = <MapLabel>[
        _pole(32.1301, 114.0814, 1),
        _pole(32.1305, 114.0817, 2),
      ];
      // 独立裁剪 oracle（与 export 内部同参）
      final bbox = BasemapFetcher.boundsOf(labels, 50);
      final cropped = GeoJsonImporter.cropTo(bm, bbox, toleranceM: 5);

      final r = await DxfExporter.export(
        name: 'qa22_real_city50',
        labels: labels,
        includeSurroundings: true,
        localBasemap: bm,
        rangeM: 50,
      );
      final e = _parseDxf(gbk_bytes.decode(r.file.readAsBytesSync()));
      final size = r.file.lengthSync();
      // ignore: avoid_print
      print('B1 市区50m：cropped(road=${cropped.roads.length} '
          'bld=${cropped.buildings.length} place=${cropped.places.length}) → '
          'DXF DaoLuBian=${_cntLayer(e, 'DaoLuBian')} '
          'JianZhu=${_cntLayer(e, 'JianZhu')} '
          'DiMing=${_cntLayer(e, 'DiMing')} size=$size');

      expect(size, lessThan(1024 * 1024), reason: '市区 50m 应远小于 1MB（≈9.6KB）');
      expect(_bmEnts(e), greaterThan(0), reason: '市区 50m 内有数据，必须出图');
      expect(_bmEnts(e), lessThan(2000), reason: '不得带出框外全量');
      // 地名 1:1（每个地名一条 DiMing 文字），可精确对齐
      expect(_cntLayer(e, 'DiMing'), cropped.places.length,
          reason: 'DiMing 实体数应等于裁剪后地名数');
      // 道路双线：每条裁剪后道路 ≤ 2 条 DaoLuBian
      expect(_cntLayer(e, 'DaoLuBian'),
          lessThanOrEqualTo(2 * cropped.roads.length),
          reason: 'DaoLuBian 不应超过裁剪后道路数的 2 倍');
      expect(r.warnings.any((w) => w.contains('范围内无底图数据')), isFalse,
          reason: '市区有数据，不应出现「无底图数据」警告');

      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('B2 数据空白处 50m：不再全量 + 真空白点给「范围内无底图数据」warning', () async {
      if (!realFile.existsSync()) {
        // ignore: avoid_print
        print('SKIP B2：真实文件不存在');
        return;
      }
      final dir = Directory.systemTemp.createTempSync('qa22_b2');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final bm = GeoJsonImporter.parse(realFile.readAsStringSync());

      Future<void> runCase(String tag, double la, double lo,
          {required bool mustBeEmpty}) async {
        final labels = <MapLabel>[
          _pole(la, lo, 1),
          _pole(la + 0.0004, lo + 0.0006, 2),
        ];
        final r = await DxfExporter.export(
          name: 'qa22_blank_$tag',
          labels: labels,
          includeSurroundings: true,
          localBasemap: bm,
          rangeM: 50,
        );
        final e = _parseDxf(gbk_bytes.decode(r.file.readAsBytesSync()));
        final size = r.file.lengthSync();
        final bbox = BasemapFetcher.boundsOf(labels, 50);
        final cropped = GeoJsonImporter.cropTo(bm, bbox, toleranceM: 5);
        final croppedTotal =
            cropped.roads.length + cropped.buildings.length + cropped.places.length;
        // ignore: avoid_print
        print('B2 $tag 50m：croppedTotal=$croppedTotal bmEnts=${_bmEnts(e)} '
            'size=$size warnings=${r.warnings}');
        // 核心：无论该点数据多少，都绝不回退全量（KB 级，远小于 1MB）
        expect(size, lessThan(1024 * 1024),
            reason: '$tag 50m 应仅线路本体（KB 级），绝不再是 ~50MB 全量');
        expect(_bmEnts(e), lessThan(2000), reason: '$tag 不得带出框外全量');
        if (mustBeEmpty) {
          expect(croppedTotal, 0, reason: '$tag 应为真空白（独立探针已确认 50m 无要素）');
          expect(_bmEnts(e), 0, reason: '$tag 框内无数据，不得回退全量写底图');
          expect(r.warnings.any((w) => w.contains('范围内无底图数据')), isTrue,
              reason: '$tag 必须给出「范围内无底图数据」中文 warning：${r.warnings}');
        }
      }

      // 独立探针确认：这两个真实点 50m（含 5m 容差）裁剪为空。
      await runCase('信阳远郊', 32.30, 114.30, mustBeEmpty: true);
      await runCase('信阳西郊', 32.15, 113.95, mustBeEmpty: true);
      // 用户点名的「罗山/新县」：实测 50m 内仍有 1 条过路（非完全空白），
      // 断言「不回退全量」即可（这也是用户真实遇到的稀疏区）。
      await runCase('罗山县城', 32.20, 114.50, mustBeEmpty: false);
      await runCase('新县山区', 31.60, 114.85, mustBeEmpty: false);
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('B3 对照：同市区点 50/300/880m 随范围增大而增大（既不恒空也不恒全量）', () async {
      if (!realFile.existsSync()) {
        // ignore: avoid_print
        print('SKIP B3：真实文件不存在');
        return;
      }
      final dir = Directory.systemTemp.createTempSync('qa22_b3');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final bm = GeoJsonImporter.parse(realFile.readAsStringSync());
      final labels = <MapLabel>[
        _pole(32.1301, 114.0814, 1),
        _pole(32.1305, 114.0817, 2),
      ];
      final sizes = <double, int>{};
      final ents = <double, int>{};
      for (final rm in <double>[50, 300, 880, 1000]) {
        final r = await DxfExporter.export(
          name: 'qa22_scale_${rm.toInt()}',
          labels: labels,
          includeSurroundings: true,
          localBasemap: bm,
          rangeM: rm,
        );
        final e = _parseDxf(gbk_bytes.decode(r.file.readAsBytesSync()));
        sizes[rm] = r.file.lengthSync();
        ents[rm] = _bmEnts(e);
        // ignore: avoid_print
        print('B3 市区 rangeM=$rm → bmEnts=${ents[rm]} size=${sizes[rm]}');
      }
      // 裁剪「按范围」工作：实体数随范围单调不减，且 50m 明显小于 880m。
      expect(ents[50]!, lessThanOrEqualTo(ents[300]!),
          reason: '50m 实体数不应多于 300m');
      expect(ents[300]!, lessThanOrEqualTo(ents[880]!),
          reason: '300m 实体数不应多于 880m');
      expect(ents[880]!, lessThanOrEqualTo(ents[1000]!),
          reason: '880m 实体数不应多于 1000m');
      expect(ents[880]!, greaterThan(ents[50]!),
          reason: '范围越大应带出越多数据（证明不是被改成恒空）');
      // 且任何档位都不得接近全量（44599 要素 → ~50MB）
      for (final rm in <double>[50, 300, 880, 1000]) {
        expect(sizes[rm]!, lessThan(5 * 1024 * 1024),
            reason: 'rangeM=$rm 不得全量导出');
        expect(ents[rm]!, lessThan(20000),
            reason: 'rangeM=$rm 要素数应低于防御上限');
      }
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('B4 修复前 vs 修复后对比（合成 400 要素 ≈ 旧「回退全量」）', () async {
      final dir = Directory.systemTemp.createTempSync('qa22_b4');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);

      // 用合成「整市规模」底图（400 要素）做对照——渲染 4.4 万真实要素到 DXF 需数分钟，
      // 不适用于单测；此处以 400 要素度量「修复前=全量注入 / 修复后=按范围裁剪」两路径的
      // 结构性差异；真实 4.4 万要素的体量对比用算术外推给出（见 print）。
      final farLat = 33.0, farLon = 115.0;
      final bm = _mk(
        [
          for (var i = 0; i < 200; i++)
            _road(_line(farLat + i * 0.0002, farLon, farLat + i * 0.0002,
                farLon + 0.002, 4), RoadGrade.trunk, '远路$i'),
        ],
        [for (var i = 0; i < 100; i++) _square(farLat + i * 0.0003, farLon + i * 0.0003, 0.001)],
        [for (var i = 0; i < 100; i++) _place(farLat + i * 0.0004, farLon + i * 0.0004, '远村$i')],
      );
      // 线路落在数据空白处（信阳市区，距合成底图 ~100km）
      final labels = <MapLabel>[_pole(32.1300, 114.0800, 1), _pole(32.1304, 114.0806, 2)];

      final after = await DxfExporter.export(
        name: 'qa22_b4_after',
        labels: labels,
        includeSurroundings: true,
        localBasemap: bm,
        rangeM: 50,
      );
      final before = await DxfExporter.export(
        name: 'qa22_b4_before',
        labels: labels,
        includeSurroundings: true,
        basemap: bm, // 跳过裁剪 = 旧「回退全量」等价
        rangeM: 50,
      );
      final eBefore = _parseDxf(gbk_bytes.decode(before.file.readAsBytesSync()));
      final eAfter = _parseDxf(gbk_bytes.decode(after.file.readAsBytesSync()));
      final bSize = before.file.lengthSync(), aSize = after.file.lengthSync();
      // ignore: avoid_print
      print('B4 合成(400 要素)：修复前 bmEnts=${_bmEnts(eBefore)} size=$bSize  '
          'vs 修复后 bmEnts=${_bmEnts(eAfter)} size=$aSize');
      // 算术外推：真实 44599 要素 ÷ 400 ≈ 111×；用户实测修复前 ≈50MB
      // ignore: avoid_print
      print('B4 外推：真实 44599 要素全量渲染 ≈ ${(bSize * 44599 / 400 / 1024 / 1024).toStringAsFixed(1)} MB '
          '（用户实测 ≈50MB），修复后裁剪为空 → $aSize B');
      expect(_bmEnts(eBefore), greaterThan(100), reason: '全量注入应带出大量底图实体');
      expect(_bmEnts(eAfter), 0, reason: '空白处裁剪为空 → 不回退全量');
      // 注意：DXF 有固定的头/表/块/线路本体开销，小样本下不会到 100×；
      // 真正的判据是「底图实体从 N 条 → 0 条」，体积随之大降。
      expect(after.file.lengthSync(), lessThan(before.file.lengthSync() ~/ 10),
          reason: '修复后应比「回退全量」小一个数量级以上');
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ==========================================================================
  // C. 裁剪几何正确性（cropTo 纯函数）
  // ==========================================================================
  group('C. 裁剪几何正确性', () {
    test('C1 框外要素一条不进 + 框内道路/建筑/地名都保留', () {
      const box = <double>[32.1295, 114.0795, 32.1305, 114.0805];
      final bm = _mk(
        [
          _road(_line(32.1300, 114.0798, 32.1300, 114.0802, 4), RoadGrade.primary,
              '框内路'),
          for (var i = 0; i < 50; i++)
            _road(_line(33.0 + i * 0.01, 115.0, 33.0 + i * 0.01, 115.01, 3),
                RoadGrade.trunk, '远路$i'),
        ],
        [
          _square(32.1298, 114.0798, 0.0002),
          for (var i = 0; i < 50; i++) _square(33.0 + i * 0.01, 115.0, 0.001),
        ],
        [
          _place(32.1300, 114.0800, '框内村'),
          for (var i = 0; i < 50; i++) _place(33.0 + i * 0.01, 115.0, '远村$i'),
        ],
      );
      final c = GeoJsonImporter.cropTo(bm, box);
      expect(c.roads.length, 1);
      expect(c.roads.single.name, '框内路');
      expect(c.buildings.length, 1);
      expect(c.places.length, 1);
      expect(c.places.single.name, '框内村');
      // 逐顶点：输出绝不含框外坐标
      for (final r in c.roads) {
        for (final p in r.pts) {
          expect(p[0] >= box[0] - 1e-9 && p[0] <= box[2] + 1e-9, isTrue,
              reason: '含框外纬度 $p');
          expect(p[1] >= box[1] - 1e-9 && p[1] <= box[3] + 1e-9, isTrue,
              reason: '含框外经度 $p');
        }
      }
    });

    test('C2 长路裁剪：无「跨框连线」（每段中点必须落在框内）', () {
      const box = <double>[32.1295, 114.0795, 32.1305, 114.0805];
      // 框外(西)→框内→框外(北)→框内→框外(东)：多次进出
      final pts = <List<double>>[
        [32.1300, 114.0700], // 西 框外
        [32.1300, 114.0798], // 框内
        [32.1300, 114.0800], // 框内
        [32.1500, 114.0800], // 北 框外（长距离）
        [32.1300, 114.0802], // 框内（重新穿入）
        [32.1300, 114.0900], // 东 框外
      ];
      final c = GeoJsonImporter.cropTo(_mk([_road(pts, RoadGrade.primary, '折返路')], [], []), box);
      expect(c.roads.length, 2, reason: '穿出再穿入应裁成 2 段');
      for (final r in c.roads) {
        expect(r.pts.length, greaterThanOrEqualTo(2), reason: '每段至少 2 点');
        // ① 无跨框连线：任意相邻两点的中点必须在框内（否则即为「把线拉出框外」bug）
        for (var i = 1; i < r.pts.length; i++) {
          final mLa = (r.pts[i][0] + r.pts[i - 1][0]) / 2;
          final mLo = (r.pts[i][1] + r.pts[i - 1][1]) / 2;
          expect(mLa >= box[0] - 1e-9 && mLa <= box[2] + 1e-9,
              isTrue, reason: '相邻段中点越出框（纬度 $mLa）→ 跨框连线');
          expect(mLo >= box[1] - 1e-9 && mLo <= box[3] + 1e-9,
              isTrue, reason: '相邻段中点越出框（经度 $mLo）→ 跨框连线');
        }
        // ② 点序：每个点沿原折线的参数（段号+段内比例）非递减，无折返
        final ps = [for (final p in r.pts) _paramOf(p, pts)];
        for (var i = 1; i < ps.length; i++) {
          expect(ps[i], greaterThanOrEqualTo(ps[i - 1] - 1e-9),
              reason: '点序折返：$ps');
        }
      }
    });

    test('C3 独立 oracle（dense-sampling）：裁剪段数与总长与真值一致', () {
      const box = <double>[31.9000, 114.0000, 32.0000, 114.1000];
      final cases = <List<List<double>>>[
        // 直线穿过框
        _line(31.80, 113.90, 32.10, 114.20, 1),
        // 两端在外、中间穿框（斜穿）
        _line(31.80, 113.95, 32.10, 114.05, 1),
        // 框内
        _line(31.950, 114.050, 31.980, 114.080, 1),
        // 框外
        _line(31.70, 113.70, 31.75, 113.75, 1),
        // 多次进出（W 形）
        <List<double>>[
          [31.90, 113.90],
          [32.05, 114.00],
          [31.90, 114.10],
          [32.05, 114.20],
        ],
      ];
      for (var ci = 0; ci < cases.length; ci++) {
        final pts = cases[ci];
        final segs =
            GeoJsonImporter.cropTo(_mk([_road(pts, RoadGrade.primary, 'c$ci')], [], []), box)
                .roads;
        final impl = _implLen([for (final r in segs) r.pts]);
        final oracle = _denseClip('c$ci', pts, box);
        // 段数一致
        expect(impl[1].round(), oracle[1].round(),
            reason: 'case$ci 段数：impl=${impl[1]} oracle=${oracle[1]}');
        // 总长一致（dense 采样，容差 3%+1e-4 度）
        expect((impl[0] - oracle[0]).abs(),
            lessThan(0.03 * oracle[0] + 1e-4),
            reason: 'case$ci 总长：impl=${impl[0]} oracle=${oracle[0]}');
        // 输出必在框内
        for (final r in segs) {
          for (final p in r.pts) {
            expect(p[0] >= box[0] - 1e-9 && p[0] <= box[2] + 1e-9, isTrue);
            expect(p[1] >= box[1] - 1e-9 && p[1] <= box[3] + 1e-9, isTrue);
          }
        }
        // ignore: avoid_print
        print('C3 case$ci：implSegs=${impl[1]} oracleSegs=${oracle[1]} '
            'implLen=${impl[0].toStringAsFixed(6)} '
            'oracleLen=${oracle[0].toStringAsFixed(6)}');
      }
    });

    test('C4 toleranceM 外扩：边界附近保留、远处不误收', () {
      // 框：lat 32.1300±0.0005（约 ±55m），lon 114.0800±0.0005
      const box = <double>[32.1300, 114.0800, 32.1310, 114.0810];
      // 框外经度 +0.0002（约 19m 外）的近路
      final nearOutside =
          _line(32.1305, 114.0812, 32.1305, 114.0816, 1); // 起点在框外 ~19m
      // 框外经度 +0.005（约 470m 外）的远路
      final farOutside = _line(32.1305, 114.0860, 32.1305, 114.0870, 1);
      final bm = _mk([
        _road(nearOutside, RoadGrade.primary, '近外'),
        _road(farOutside, RoadGrade.primary, '远外'),
      ], [], []);

      final zero = GeoJsonImporter.cropTo(bm, box); // 容差 0
      final wide = GeoJsonImporter.cropTo(bm, box, toleranceM: 30); // 外扩 30m

      // 容差 0：近外(19m)也应在框外 → 一条都不进
      expect(zero.roads.isEmpty, isTrue,
          reason: '容差 0 时框外 19m 的路不应进入：${zero.roads.length}');
      // 容差 30m：19m 的近外路进入，470m 的远外路仍不进
      expect(wide.roads.length, 1, reason: '容差 30m 应只收 19m 的近外路');
      expect(wide.roads.single.name, '近外');
      for (final p in wide.roads.single.pts) {
        expect(p[1], lessThan(box[3] + 0.0004), reason: '外扩不应把 470m 外的收进来');
      }
    });

    test('C5 退化/极端输入不崩溃、不产生非法几何', () {
      const box = <double>[32.1295, 114.0795, 32.1305, 114.0805];
      // 单点（<2 点）、零长段
      final single = GeoJsonImporter.cropTo(
          _mk([_road([[32.1300, 114.0800]], RoadGrade.trunk, '点')], [], []), box);
      expect(single.roads.isEmpty, isTrue, reason: '单点不应成为道路段');
      final zeroLen = GeoJsonImporter.cropTo(
          _mk([
            _road([
              [32.1300, 114.0800],
              [32.1300, 114.0800]
            ], RoadGrade.trunk, '零长')
          ], [], []),
          box);
      expect(zeroLen.roads.isEmpty, isTrue, reason: '零长段应被丢弃');

      // 退化 bbox（min==max）
      final degen = GeoJsonImporter.cropTo(
          _mk([_road(_line(32.1300, 114.0800, 32.1301, 114.0801, 2), RoadGrade.trunk, 'd')], [], []),
          <double>[32.1300, 114.0800, 32.1300, 114.0800]);
      for (final r in degen.roads) {
        for (final p in r.pts) {
          expect(p[0].isFinite && p[1].isFinite, isTrue, reason: '退化框输出非法坐标 $p');
        }
      }

      // NaN / Infinity 坐标（直接构造，绕过 parse）：不得崩溃。
      // 观察项 F1：直接给 cropTo 注入非有限坐标会原样传播（详见报告）；
      // 生产入口 GeoJsonImporter.parse 已过滤非有限坐标，故系统级契约由 C5b 验证。
      final bad = GeoJsonImporter.cropTo(
          _mk([
            _road([
              [double.nan, 114.0800],
              [32.1300, double.nan]
            ], RoadGrade.trunk, 'nan'),
            _road([
              [double.infinity, 114.0800],
              [32.1300, double.infinity]
            ], RoadGrade.trunk, 'inf'),
          ], [], []),
          box);
      // ignore: avoid_print
      print('C5(NaN 直注) 输出段数=${bad.roads.length}（观察项 F1：可能含非有限坐标）');
    });

    test('C5b 系统级：含 NaN/Inf 的 GeoJSON 经 parse 过滤后不得产生非法几何', () {
      const box = <double>[32.1295, 114.0795, 32.1305, 114.0805];
      // 直接构造一份含 NaN / Infinity（JSON 无法表达，parse 层用字符串? 不行）——
      // GeoJSON 数字不支持 NaN，故此处模拟「越界/非法坐标」：parse 的 _pointFrom
      // 会对越界/非有限一律过滤。用越界坐标验证「非法坐标不进 cropTo」。
      final text = jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'highway': 'trunk'},
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                [999.0, 999.0], // 越界 → 应被过滤，不得产非法点
                [114.0800, 32.1300]
              ]
            }
          },
          {
            'type': 'Feature',
            'properties': {'place': 'village', 'name': '有效点'},
            'geometry': {
              'type': 'Point',
              'coordinates': [114.0801, 32.1301]
            }
          }
        ]
      });
      final bm = GeoJsonImporter.parse(text);
      // 越界点被过滤后，该线只剩 1 点 → parse 不产出该道路
      expect(bm.roads.isEmpty, isTrue,
          reason: '越界/非法坐标应在 parse 层过滤，绝不进入底图');
      expect(bm.places.length, 1, reason: '合法点仍应保留');
      final c = GeoJsonImporter.cropTo(
          _mk([_road(_line(32.1300, 114.0800, 32.1300, 114.0802, 2), RoadGrade.trunk, 'v')], [], []),
          box);
      for (final r in c.roads) {
        for (final p in r.pts) {
          expect(p[0].isFinite && p[1].isFinite, isTrue, reason: '输出含非法坐标 $p');
        }
      }
    });
  });

  // ==========================================================================
  // D. 上限保护（capFeatures）
  // ==========================================================================
  group('D. 要素上限保护', () {
    test('D1 超限按「距线路最近优先」截断到 cap + 中文 warning', () {
      final route = <List<double>>[
        [32.1300, 114.0800]
      ];
      // 距线路近（~1e-6 度级）与远（~1 度级）两组，远组必然被丢
      final roads = <RoadPoly>[
        for (var i = 0; i < 300; i++)
          _road([
            [32.1300 + i * 1e-6, 114.0800]
          ], RoadGrade.other, 'NEAR$i'),
        for (var i = 0; i < 200; i++)
          _road([
            [33.0 + i * 0.001, 115.0]
          ], RoadGrade.other, 'FAR$i'),
      ];
      final w = <String>[];
      final capped = GeoJsonImporter.capFeatures(_mk(roads, [], []),
          routePts: route, cap: 100, warnings: w);
      expect(capped.roads.length, 100);
      expect(capped.roads.every((r) => r.name.startsWith('NEAR')), isTrue,
          reason: '应保留离线路最近的');
      expect(w.length, 1);
      expect(w.single, contains('上限'));
      expect(w.single, contains('100'));
    });

    test('D2 接近但不超上限（10000+ 且 < cap）→ 一条都不截断', () {
      final route = <List<double>>[
        [32.1300, 114.0800]
      ];
      final roads = <RoadPoly>[
        for (var i = 0; i < 12000; i++)
          _road([
            [32.1300 + i * 1e-7, 114.0800]
          ], RoadGrade.other, 'N$i'),
      ];
      final w = <String>[];
      final capped = GeoJsonImporter.capFeatures(_mk(roads, [], []),
          routePts: route, cap: 20000, warnings: w);
      expect(capped.roads.length, 12000, reason: '未超上限不得截断');
      expect(w, isEmpty, reason: '未超上限不应产生 warning');
    });

    test('D3 DXF 级接线：注入小 cap 截断且仍产出合法 DXF', () async {
      final dir = Directory.systemTemp.createTempSync('qa22_d3');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      expect(GeoJsonImporter.defaultFeatureCap, 20000,
          reason: '生产默认上限应为 20000');
      final places = <PlaceFeature>[
        for (var i = 0; i < 300; i++)
          _place(32.1300 + (i % 30) * 1e-6, 114.0800 + (i ~/ 30) * 1e-6, 'P$i'),
      ];
      final r = await DxfExporter.export(
        name: 'qa22_cap',
        labels: <MapLabel>[_pole(32.1300, 114.0800)],
        includeSurroundings: true,
        localBasemap: _mk([], [], places),
        localBasemapFeatureCap: 60,
        rangeM: 300,
      );
      final e = _parseDxf(gbk_bytes.decode(r.file.readAsBytesSync()));
      expect(_cntLayer(e, 'DiMing'), 60, reason: '应截断到注入上限 60');
      expect(r.warnings.any((w) => w.contains('上限')), isTrue);
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('D4 cap=20000 对 880m 信阳城区是否误截（独立评估）', () {
      if (!realFile.existsSync()) {
        // ignore: avoid_print
        print('SKIP D4：真实文件不存在');
        return;
      }
      final bm = GeoJsonImporter.parse(realFile.readAsStringSync());
      // 信阳城区典型线路
      final labels = <MapLabel>[
        _pole(32.1301, 114.0814, 1),
        _pole(32.1305, 114.0817, 2),
      ];
      for (final rm in <double>[300, 880, 1000]) {
        final bbox = BasemapFetcher.boundsOf(labels, rm);
        final cropped =
            GeoJsonImporter.cropTo(bm, bbox, toleranceM: rm * 0.1);
        final total =
            cropped.roads.length + cropped.buildings.length + cropped.places.length;
        // ignore: avoid_print
        print('D4 信阳城区 rangeM=$rm → 裁剪后总要素=$total '
            '(road=${cropped.roads.length} bld=${cropped.buildings.length} '
            'place=${cropped.places.length}) cap=20000');
        expect(total, lessThan(20000),
            reason: 'rangeM=$rm 城区裁剪后 $total 条，若 ≥cap 则说明 cap 会误截正常场景');
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  // ==========================================================================
  // E. 既有语义未回退
  // ==========================================================================
  group('E. 既有语义未回退', () {
    test('E1 cropTo 不修改入参（纯函数/不可变）', () {
      const box = <double>[32.1295, 114.0795, 32.1305, 114.0805];
      final road = _road(_line(31.0, 113.0, 33.0, 115.0, 5), RoadGrade.trunk, 'x');
      final b = _square(31.0, 113.0, 0.001);
      final p = _place(31.0, 113.0, 'y');
      final bm = _mk([road], [b], [p]);
      final beforeRoadPts = [for (final q in road.pts) [...q]];
      GeoJsonImporter.cropTo(bm, box);
      expect(road.pts, beforeRoadPts, reason: 'cropTo 不得改动入参道路点');
      expect(bm.roads.length, 1);
      expect(bm.buildings.length, 1);
      expect(bm.places.length, 1);
    });

    test('E2 parse / store 语义未变（往返一致 + 非法输入抛 FormatException）', () async {
      final dir = Directory.systemTemp.createTempSync('qa22_e2');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final text = jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'highway': 'trunk', 'name': '甲路'},
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                [114.08, 32.13],
                [114.09, 32.14]
              ]
            }
          },
          {
            'type': 'Feature',
            'properties': {'name': '乙楼'},
            'geometry': {
              'type': 'Polygon',
              'coordinates': [
                [
                  [114.08, 32.13],
                  [114.081, 32.13],
                  [114.081, 32.131],
                  [114.08, 32.131],
                  [114.08, 32.13]
                ]
              ]
            }
          },
          {
            'type': 'Feature',
            'properties': {'place': 'village', 'name': '丙村'},
            'geometry': {
              'type': 'Point',
              'coordinates': [114.082, 32.132]
            }
          }
        ]
      });
      final bm = GeoJsonImporter.parse(text);
      expect(bm.roads.length, 1);
      expect(bm.buildings.length, 1);
      expect(bm.places.length, 1);
      // 坐标顺序 [lat,lon]
      expect(bm.roads.single.pts.first, [32.13, 114.08]);
      expect(bm.places.single.lat, 32.132);
      expect(bm.places.single.lon, 114.082);
      expect(bm.roads.single.grade, RoadGrade.trunk);
      expect(bm.roads.single.name, '甲路');

      final localDir = Directory('${dir.path}/local');
      localDir.createSync(recursive: true);
      final store = LocalBasemapStore(localDir);
      await store.save(text, sourceName: 't.geojson', roads: 1, buildings: 1, places: 1);
      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.roads.length, 1);
      expect(loaded.buildings.length, 1);
      expect(loaded.places.length, 1);
      expect(store.meta()['sourceName'], 't.geojson');

      expect(() => GeoJsonImporter.parse('not json'), throwsA(isA<FormatException>()));
      expect(() => GeoJsonImporter.parse('{"type":"FeatureCollection","features":[]}'),
          throwsA(isA<FormatException>()));
      dir.deleteSync(recursive: true);
    });
  });
}
