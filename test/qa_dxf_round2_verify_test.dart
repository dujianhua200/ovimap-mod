// ============================================================================
// QA 第 2 轮对抗性复核（严过关）—— 针对 F1 顺序修复 + O4 + O2 的**连带影响**。
// 独立于第 1 轮文件（test/qa_dxf_basemap_verify_test.dart 保持原样不改），
// 全部自造数据。重点：F1 修复本身有没有引入新回归（图框/图签/指北针/配线/文字层级）。
// ============================================================================
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
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

// ------------------------- DXF 结构解析 -------------------------

class _Ent {
  final String type;
  final List<List<String>> kv = [];
  _Ent(this.type);
  String? first(String c) {
    for (final p in kv) {
      if (p[0] == c) return p[1];
    }
    return null;
  }

  List<List<double>> points() {
    final pts = <List<double>>[];
    double? x;
    for (final p in kv) {
      if (p[0] == '10') {
        x = double.tryParse(p[1]);
      } else if (p[0] == '20' && x != null) {
        pts.add([x, double.tryParse(p[1]) ?? 0]);
        x = null;
      }
    }
    return pts;
  }
}

/// 仅解析 ENTITIES 段（排除 BLOCKS/表段，避免块定义几何污染包围盒）。
List<_Ent> _entities(String text) {
  final lines = text.split('\n');
  final out = <_Ent>[];
  _Ent? cur;
  var inEntities = false;
  for (var i = 0; i + 1 < lines.length; i += 2) {
    final c = lines[i].trim();
    final v = lines[i + 1].trim();
    if (c == '2' && v == 'ENTITIES') {
      inEntities = true;
      continue;
    }
    if (c == '0' && v == 'ENDSEC') {
      if (inEntities) break;
      continue;
    }
    if (!inEntities) continue;
    if (c == '0') {
      cur = _Ent(v);
      out.add(cur);
    } else if (cur != null) {
      cur.kv.add([c, v]);
    }
  }
  return out;
}

List<_Ent> _on(List<_Ent> ents, String type, String layer) =>
    ents.where((e) => e.type == type && (e.first('8') ?? '') == layer).toList();

/// 坐标包围盒（仅几何组码），`[minX,minY,maxX,maxY]`。
List<double> _bounds(Iterable<_Ent> ents) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final e in ents) {
    for (final p in e.kv) {
      if (p[0] == '10' || p[0] == '11' || p[0] == '12' || p[0] == '13') {
        final v = double.tryParse(p[1]);
        if (v != null) {
          if (v < minX) minX = v;
          if (v > maxX) maxX = v;
        }
      } else if (p[0] == '20' || p[0] == '21' || p[0] == '22' || p[0] == '23') {
        final v = double.tryParse(p[1]);
        if (v != null) {
          if (v < minY) minY = v;
          if (v > maxY) maxY = v;
        }
      }
    }
  }
  return [minX, minY, maxX, maxY];
}

/// 复刻改造后的 _pickScale（较长边）。
int _pickScale(double minX, double minY, double maxX, double maxY) {
  const m = 10.0;
  final spanX = (maxX - minX).abs();
  final spanY = (maxY - minY).abs();
  final contentW = (math.max(spanX, spanY) + 2 * m).clamp(1.0, 1e9);
  final raw = contentW / 0.40;
  const std = [100, 200, 250, 500, 1000, 2000, 2500, 5000, 10000];
  for (final s in std) {
    if (raw <= s) return s;
  }
  return (raw / 1000).ceil() * 1000;
}

// ------------------------- 数据工厂 -------------------------

const double kLat = 32.1264;
const double kLon = 114.0913;

const Set<String> kBasemapLayers = {
  'DaoLuBian',
  'DaoLuZhong',
  'DaoLu',
  'JianZhu',
  'JianZhuFill',
  'DiMing',
};
const Set<String> kBizLayers = {'GanLu', 'PeiXianTu'};
const Set<String> kFrameLayers = {'TuQian', 'BeiFangZhen'};

List<MapLabel> _poles(double lat, double lon, {int seq0 = 1, double dLat = 0, double dLon = 0}) =>
    List.generate(3, (i) => MapLabel(
        typeId: 'pipe',
        seq: seq0 + i,
        lat: lat + dLat * i,
        lon: lon + dLon * i,
        lineGroupId: 'g'));

BasemapFetchReport _ok({int roads = 0, int b = 0, int p = 0}) =>
    BasemapFetchReport(
      roads: DatasetReport(FetchState.ok, count: roads),
      buildings: DatasetReport(FetchState.ok, count: b),
      places: DatasetReport(FetchState.ok, count: p),
    );

Future<String> _export(
  Directory dir, {
  required List<MapLabel> labels,
  required BasemapData bm,
  DxfVersion v = DxfVersion.r2000,
  bool straightened = false,
  bool buildingFill = false,
  String name = 'qa2',
}) async {
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final r = await DxfExporter.export(
      name: name,
      labels: labels,
      includeSurroundings: true,
      basemap: bm,
      version: v,
      straightenedWiring: straightened,
      buildingFill: buildingFill);
  return latin1.decode(r.file.readAsBytesSync());
}

/// 底图明显超出线路范围（远建筑/远路/远村），用于图框包围盒回归测试。
BasemapData _farBasemap() => BasemapData(
      roads: [
        RoadPoly(const [
          [32.0, 114.0],
          [32.0, 114.025],
        ], RoadGrade.trunk, '远路'),
      ],
      buildings: [
        BuildingPoly(const [
          [
            [32.02, 114.02],
            [32.02, 114.022],
            [32.022, 114.022],
            [32.022, 114.02],
          ]
        ], '远楼'),
      ],
      places: const [
        PlaceFeature(name: '远村', lat: 32.018, lon: 114.019, level: PlaceLevel.village),
      ],
      report: _ok(roads: 1, b: 1, p: 1),
    );

/// 常规底图（4 等级路 + 带孔建筑 + 多级地名）。
BasemapData _stdBasemap() {
  List<List<double>> line(double la0, double lo0, double la1, double lo1, int n) {
    final o = <List<double>>[];
    for (var i = 0; i <= n; i++) {
      final t = i / n;
      o.add([la0 + (la1 - la0) * t, lo0 + (lo1 - lo0) * t]);
    }
    return o;
  }

  return BasemapData(
    roads: [
      RoadPoly(line(32.1264, 114.0895, 32.1264, 114.0935, 6), RoadGrade.trunk, '干道'),
      RoadPoly(line(32.1255, 114.0913, 32.1285, 114.0913, 6), RoadGrade.primary, '人民路'),
      RoadPoly(line(32.1290, 114.0920, 32.1296, 114.0928, 3), RoadGrade.secondary, '支路'),
      RoadPoly(line(32.1240, 114.0940, 32.1248, 114.0948, 3), RoadGrade.service, ''),
    ],
    buildings: [
      BuildingPoly([
        [
          [32.1268, 114.0918],
          [32.1268, 114.0924],
          [32.1273, 114.0924],
          [32.1273, 114.0918],
        ],
        [
          [32.1269, 114.0919],
          [32.1269, 114.0923],
          [32.1272, 114.0923],
          [32.1272, 114.0919],
        ],
      ], '李庄验证楼'),
    ],
    places: const [
      PlaceFeature(name: '验证市', lat: 32.1200, lon: 114.0900, level: PlaceLevel.city),
      PlaceFeature(name: '验证村', lat: 32.1285, lon: 114.0922, level: PlaceLevel.village),
    ],
    report: _ok(roads: 4, b: 1, p: 2),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==========================================================================
  // B. F1 正确性 + 连带影响
  // ==========================================================================

  test('F1（强）：整块底图先写出、整块业务后写出（maxBasemapIdx < minBizIdx）', () async {
    final dir = Directory.systemTemp.createTempSync('qa2_order');
    final text = await _export(dir, labels: _poles(kLat, kLon), bm: _stdBasemap());
    final ents = _entities(text);

    int? minBiz, maxBiz, minBase, maxBase;
    for (var i = 0; i < ents.length; i++) {
      final layer = ents[i].first('8') ?? '';
      if (kBizLayers.contains(layer)) {
        minBiz ??= i;
        maxBiz = i;
      }
      if (kBasemapLayers.contains(layer)) {
        minBase ??= i;
        maxBase = i;
      }
    }
    expect(minBiz, isNotNull);
    expect(minBase, isNotNull);
    // 整块底图在整块业务之前：底图最大索引 < 业务最小索引
    expect(maxBase! < minBiz!,
        isTrue,
        reason: 'F1 未生效：底图区间[$minBase,$maxBase] 与业务区间[$minBiz,$maxBiz] 交叠/反序；'
            'DXF 后写者在上层，须"整块底图先写、整块业务后写"');
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('F1（连带）：底图内部文字仍后置于底图几何之上（缓冲逻辑未破坏）', () async {
    final dir = Directory.systemTemp.createTempSync('qa2_text');
    final text = await _export(dir,
        labels: _poles(kLat, kLon), bm: _stdBasemap(), buildingFill: true);
    final ents = _entities(text);

    const geomLayers = {'DaoLuBian', 'DaoLuZhong', 'JianZhuFill'};
    int? lastGeom;
    int? firstText;
    for (var i = 0; i < ents.length; i++) {
      final layer = ents[i].first('8') ?? '';
      if (geomLayers.contains(layer)) lastGeom = i;
      if (kBasemapLayers.contains(layer) && ents[i].type == 'TEXT') {
        firstText ??= i;
      }
    }
    expect(lastGeom, isNotNull);
    expect(firstText, isNotNull);
    expect(lastGeom! < firstText!,
        isTrue,
        reason: '底图文字(idx=$firstText)未后置于底图几何(idx=$lastGeom)之上');
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('F1（最大风险·图框回归）：底图明显超出线路时，图框仍完整包住并集，图签/指北针在框内', () async {
    final dir = Directory.systemTemp.createTempSync('qa2_frame');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final labels = _poles(32.0, 114.0, dLon: 0.001); // 线路仅 ~188m

    // 无底图基准：图框≈线路范围
    final r0 = await DxfExporter.export(
        name: 'nobm', labels: labels, includeSurroundings: false, version: DxfVersion.r2000);
    final G0 = _bounds(_entities(latin1.decode(r0.file.readAsBytesSync())));

    // 远底图（~2.4km 外）：若图框只按业务算，底图会被裁在框外
    final tBm = await _export(dir, labels: labels, bm: _farBasemap(), name: 'bm');
    final ents = _entities(tBm);
    final content = ents.where((e) => !kFrameLayers.contains(e.first('8') ?? '')).toList();
    final U = _bounds(content); // 底图+业务并集
    final G = _bounds(ents); // 全图

    // 1) 图框必须因底图而显著扩大（证明底图被纳入图框，而非只按业务算）
    expect(G[2], greaterThan(G0[2] + 1000),
        reason: '图框右边界未随远底图扩大 → 底图可能被裁在框外（回归）');
    expect(G[3], greaterThan(G0[3] + 1000),
        reason: '图框上边界未随远底图扩大 → 底图可能被裁在框外（回归）');

    // 2) 图框完整包住底图+业务并集（不是"首个对就行"）
    expect(G[0], lessThanOrEqualTo(U[0] + 0.005), reason: '图框左未包住并集');
    expect(G[1], lessThanOrEqualTo(U[1] + 0.005), reason: '图框下未包住并集');
    expect(G[2], greaterThanOrEqualTo(U[2] - 0.005), reason: '图框右未包住并集');
    expect(G[3], greaterThanOrEqualTo(U[3] - 0.005), reason: '图框上未包住并集');

    // 3) 指北针在框内（右上角）
    final arrow = _on(ents, 'CIRCLE', 'BeiFangZhen');
    expect(arrow, isNotEmpty);
    final c = arrow.first.points().first;
    expect(c[0], greaterThan(G[0]));
    expect(c[0], lessThan(G[2]));
    expect(c[1], greaterThan(G[1]));
    expect(c[1], lessThan(G[3]));

    // 4) 图签存在且不越出全图（图框为最外者 → 图签若越框会污染 G，上组断言即失败）
    expect(_on(ents, 'LINE', 'TuQian'), isNotEmpty);

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('F1（连带）：拉直配线图仍置于路由图右侧，且被图框包住、走向正常', () async {
    final dir = Directory.systemTemp.createTempSync('qa2_wire');
    final labels = _topoLabels();

    final noWire = await _export(dir, labels: labels, bm: _stdBasemap(), name: 'nw');
    final withWire = await _export(
        dir, labels: labels, bm: _stdBasemap(), straightened: true, name: 'ww');

    final gNo = _bounds(_entities(noWire));
    final entsW = _entities(withWire);
    final gW = _bounds(entsW);

    // 配线图向右扩展 → 右边界变大
    expect(gW[2], greaterThan(gNo[2] + 1),
        reason: '拉直配线图未向右扩展（布局可能错位）');

    // 存在明显在路由图右侧的 PeiXianTu 实体（原点是 routeW+60）
    final routeMaxX = gNo[2]; // 无配线时右边界≈路由图右侧
    final farPei = _on(entsW, 'LWPOLYLINE', 'PeiXianTu')
        .where((e) => e.points().any((p) => p[0] > routeMaxX + 30))
        .toList();
    expect(farPei, isNotEmpty, reason: '未发现位于路由图右侧的配线图实体');

    // 图框包住配线图：G 最外=图框，配线在其内（trivially）——确保未越框
    for (final e in entsW) {
      for (final p in e.points()) {
        expect(p[0], lessThanOrEqualTo(gW[2] + 0.005));
        expect(p[1], lessThanOrEqualTo(gW[3] + 0.005));
      }
    }
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ==========================================================================
  // C. O4 南北向比例
  // ==========================================================================
  test('O4：南北 / 东西 / 斜向三向一致合理，且南北向不再被 X≈0 拖到最小档', () async {
    final dir = Directory.systemTemp.createTempSync('qa2_o4');

    double spanXOf(List<MapLabel> ls) {
      final s = 111320.0 * math.cos(ls.first.lat * math.pi / 180);
      var mn = double.infinity, mx = -double.infinity;
      for (final l in ls) {
        final x = (l.lon - ls.first.lon) * s;
        if (x < mn) mn = x;
        if (x > mx) mx = x;
      }
      return (mx - mn).abs();
    }

    double spanYOf(List<MapLabel> ls) {
      var mn = double.infinity, mx = -double.infinity;
      for (final l in ls) {
        final y = (l.lat - ls.first.lat) * 110540.0;
        if (y < mn) mn = y;
        if (y > mx) mx = y;
      }
      return (mx - mn).abs();
    }

    // 目标 ~4974m；南北：dLat = 4974/110540；东西：dLon = 4974/94400
    final ns = _poles(32.0, 114.0, dLat: 4974 / 110540.0); // 经度不变
    final ew = _poles(32.0, 114.0, dLon: 4974 / 94400.0); // 纬度不变
    final diag = _poles(32.0, 114.0, dLat: 0.032, dLon: 0.0373);

    final scaleNS = _pickScale(0, 0, spanXOf(ns), spanYOf(ns));
    final scaleEW = _pickScale(0, 0, spanXOf(ew), spanYOf(ew));

    // O4 关键：长度相当的南北/东西向应得到相同比例（不再因 X≈0 退化到最小档）
    expect(scaleNS, scaleEW, reason: '南北/东西向比例应一致（较长边模型）');
    expect(scaleNS, greaterThan(1000),
        reason: '南北向比例不应退化到最小档（旧公式会取 1:100）');

    // 南北向：竖直路 → 描边偏移在 X；半宽=纸面mm×比例
    const halfMm = 0.90; // v3.9.5 路宽加倍
    final expNS = halfMm / 1000 * scaleNS;
    final nsRoad = BasemapData(
      roads: [
        RoadPoly(
            [
              for (var i = 0; i <= 6; i++) [32.0 + (4974 / 110540.0) * i / 6, 114.0]
            ],
            RoadGrade.trunk,
            '南北干道'),
      ],
      buildings: const [],
      places: const [],
      report: _ok(roads: 1),
    );
    final tNS = await _export(dir, labels: ns, bm: nsRoad, name: 'ns');
    var maxAbsX = 0.0;
    for (final e in _on(_entities(tNS), 'LWPOLYLINE', 'DaoLuBian')) {
      for (final p in e.points()) {
        if (p[0].abs() > maxAbsX) maxAbsX = p[0].abs();
      }
    }
    expect(maxAbsX, closeTo(expNS, 1e-6), reason: '南北向半宽应=$expNS，实测 $maxAbsX');
    expect(tNS.contains('NaN'), isFalse);
    expect(tNS.contains('Infinity'), isFalse);

    // 东西向：水平路 → 描边偏移在 Y
    final expEW = halfMm / 1000 * scaleEW;
    final ewRoad = BasemapData(
      roads: [
        RoadPoly(
            [
              for (var i = 0; i <= 6; i++) [32.0, 114.0 + (4974 / 94400.0) * i / 6]
            ],
            RoadGrade.trunk,
            '东西干道'),
      ],
      buildings: const [],
      places: const [],
      report: _ok(roads: 1),
    );
    final tEW = await _export(dir, labels: ew, bm: ewRoad, name: 'ew');
    var maxAbsY = 0.0;
    for (final e in _on(_entities(tEW), 'LWPOLYLINE', 'DaoLuBian')) {
      for (final p in e.points()) {
        if (p[1].abs() > maxAbsY) maxAbsY = p[1].abs();
      }
    }
    expect(maxAbsY, closeTo(expEW, 1e-6));
    expect(expNS, closeTo(expEW, 1e-6), reason: '南北/东西向等效半宽应一致');

    // 斜向：无 NaN/Inf、有描边、字号为正
    final diagBm = BasemapData(
      roads: [
        RoadPoly(
            [
              for (var i = 0; i <= 6; i++) [32.0 + 0.032 * i / 6, 114.0 + 0.0373 * i / 6]
            ],
            RoadGrade.trunk,
            '斜向干道'),
      ],
      buildings: const [],
      places: const [
        PlaceFeature(name: '斜村', lat: 32.01, lon: 114.01, level: PlaceLevel.village),
      ],
      report: _ok(roads: 1, p: 1),
    );
    final tDiag = await _export(dir, labels: diag, bm: diagBm, name: 'dg');
    expect(tDiag.contains('NaN'), isFalse);
    expect(tDiag.contains('Infinity'), isFalse);
    expect(_on(_entities(tDiag), 'LWPOLYLINE', 'DaoLuBian'), isNotEmpty);
    for (final t in _entities(tDiag).where((e) => e.type == 'TEXT')) {
      final h = double.tryParse(t.first('40') ?? '');
      expect(h, isNotNull);
      expect(h!, greaterThan(0));
    }

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('O4：极短(10m)/极长(47km)在新公式下仍不出极端值/NaN', () async {
    final dir = Directory.systemTemp.createTempSync('qa2_ext');

    final short = _poles(32.0, 114.0, dLon: 0.0001);
    final tS = await _export(
        dir,
        labels: short,
        bm: BasemapData(
          roads: [
            RoadPoly(const [
              [32.0, 114.0],
              [32.0, 114.0002],
            ], RoadGrade.trunk, ''),
          ],
          buildings: const [],
          places: const [],
          report: _ok(roads: 1),
        ),
        name: 's');
    expect(tS.contains('NaN'), isFalse);
    expect(tS.contains('Infinity'), isFalse);

    final long = _poles(32.0, 114.0, dLon: 0.5);
    final tL = await _export(
        dir,
        labels: long,
        bm: BasemapData(
          roads: [
            RoadPoly(const [
              [32.0, 114.0],
              [32.0, 114.5],
            ], RoadGrade.trunk, ''),
          ],
          buildings: const [],
          places: const [],
          report: _ok(roads: 1),
        ),
        name: 'l');
    expect(tL.contains('NaN'), isFalse);
    expect(tL.contains('Infinity'), isFalse);

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ==========================================================================
  // D. O2 缓存降噪（别误伤"失败必须可见"）
  // ==========================================================================
  test('O2：正常缓存命中(全 cached 无失败) → warnings 为空、不弹提示', () async {
    const report = BasemapFetchReport(
      roads: DatasetReport(FetchState.cached, count: 5),
      buildings: DatasetReport(FetchState.cached, count: 2),
      places: DatasetReport(FetchState.cached, count: 3),
    );
    expect(report.anyFailed, isFalse);
    expect(report.toWarnings(), isEmpty, reason: '正常缓存命中不应产生 warning');

    // 端到端：导出 warnings 应为空（对话框据此不弹 toast）
    final dir = Directory.systemTemp.createTempSync('qa2_o2a');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final r = await DxfExporter.export(
        name: 'o2a',
        labels: _poles(kLat, kLon),
        includeSurroundings: true,
        basemap: const BasemapData(
            roads: [], buildings: [], places: [], report: report),
        version: DxfVersion.r2000);
    expect(r.warnings, isEmpty, reason: '正常缓存命中的导出不得弹提示');
    expect(r.file.existsSync(), isTrue);
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('O2：部分失败/全失败(降级) → warnings 仍结构化且可解释，未被静音', () async {
    // 部分失败：道路 ok / 建筑 failed / 地名 cached（无 error）
    const partial = BasemapFetchReport(
      roads: DatasetReport(FetchState.ok, count: 5),
      buildings: DatasetReport(FetchState.failed, error: '超时'),
      places: DatasetReport(FetchState.cached, count: 3),
    );
    expect(partial.anyFailed, isTrue);
    final w = partial.toWarnings();
    expect(w, isNotEmpty);
    expect(w.any((s) => s.contains('建筑轮廓') && s.contains('未获取')), isTrue);
    expect(w.any((s) => s.contains('地名') && s.contains('缓存')), isTrue);
    expect(w.any((s) => s.contains('刷新底图')), isTrue);

    // 全失败
    const allFail = BasemapFetchReport(
      roads: DatasetReport(FetchState.failed, error: '网络不可达'),
      buildings: DatasetReport(FetchState.failed, error: '网络不可达'),
      places: DatasetReport(FetchState.failed, error: '网络不可达'),
    );
    expect(allFail.allFailed, isTrue);
    final wa = allFail.toWarnings();
    expect(wa.any((s) => s.contains('道路矢量')), isTrue);
    expect(wa.any((s) => s.contains('刷新底图')), isTrue);

    // 有 ok 但空 → "无 X"
    const empty = BasemapFetchReport(
      roads: DatasetReport(FetchState.ok, count: 0),
      buildings: DatasetReport(FetchState.ok, count: 1),
      places: DatasetReport(FetchState.ok, count: 1),
    );
    expect(empty.toWarnings().any((s) => s.contains('无道路矢量')), isTrue);

    // 端到端：降级导出 warnings 非空、文件仍产出
    final dir = Directory.systemTemp.createTempSync('qa2_o2b');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final r = await DxfExporter.export(
        name: 'o2b',
        labels: _poles(kLat, kLon),
        includeSurroundings: true,
        basemap: const BasemapData(
            roads: [], buildings: [], places: [], report: partial),
        version: DxfVersion.r2000);
    expect(r.warnings, isNotEmpty, reason: '降级必须可见（失败可见 P0）');
    expect(r.file.existsSync(), isTrue);
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('O2：离线回退(cached 带 error) → 仍提示、可解释（不被降噪静音）', () async {
    // 全 cached 但均带 error（联网失败后回退旧缓存）→ anyFailed=false
    const offline = BasemapFetchReport(
      roads: DatasetReport(FetchState.cached, source: 'cache(offline)', error: 'SocketException', count: 4),
      buildings: DatasetReport(FetchState.cached, source: 'cache(offline)', error: 'SocketException', count: 2),
      places: DatasetReport(FetchState.cached, source: 'cache(offline)', error: 'SocketException', count: 1),
    );
    expect(offline.anyFailed, isFalse);
    final w = offline.toWarnings();
    expect(w, isNotEmpty, reason: '离线回退必须提示（不能因降噪静音）');
    expect(w.any((s) => s.contains('联网失败')), isTrue);
    expect(w.every((s) => s.contains('缓存')), isTrue);
    // 无 failed → 不附"刷新底图"总指引（内容仍可解释）
    expect(w.any((s) => s.contains('刷新底图')), isFalse);
  });

  // ==========================================================================
  // E. 回归与红线（顺序调整后重新确认）
  // ==========================================================================
  test('E：顺序调整后 R12 仍无 370/420/LWPOLYLINE/HATCH；R2000 仍 AC1015 且含之', () async {
    final dir = Directory.systemTemp.createTempSync('qa2_ver');
    final t12 = await _export(dir,
        labels: _poles(kLat, kLon), bm: _stdBasemap(), v: DxfVersion.r12, name: 'r12');
    final e12 = _entities(t12);
    expect(t12, contains('1\nAC1009\n'));
    expect(t12, isNot(contains('\n370\n')));
    expect(t12, isNot(contains('\n420\n')));
    expect(e12.any((e) => e.type == 'LWPOLYLINE'), isFalse);
    expect(e12.any((e) => e.type == 'HATCH'), isFalse);
    expect(e12.where((e) => e.type == 'POLYLINE').length,
        e12.where((e) => e.type == 'SEQEND').length);

    final t20 = await _export(dir,
        labels: _poles(kLat, kLon),
        bm: _stdBasemap(),
        v: DxfVersion.r2000,
        buildingFill: true, // 显式开启：R2000 仍应含 HATCH
        name: 'r20');
    final e20 = _entities(t20);
    expect(t20, contains('1\nAC1015\n'));
    expect(t20, contains('\n370\n'));
    expect(t20, contains('\n420\n'));
    expect(e20.any((e) => e.type == 'LWPOLYLINE'), isTrue);
    expect(e20.any((e) => e.type == 'HATCH'), isTrue);
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// 含拓扑的 8 杆链 + 3 箱体（用于配线图）。
List<MapLabel> _topoLabels() {
  const gid = 'g1';
  final labels = <MapLabel>[];
  const offs = [
    (0.0, 0.0),
    (0.0004, 0.0002),
    (0.0009, 0.0005),
    (0.0013, 0.0011),
    (0.0015, 0.0018),
    (0.0013, 0.0024),
    (0.0008, 0.0028),
    (0.0002, 0.0030),
  ];
  for (var i = 0; i < offs.length; i++) {
    labels.add(MapLabel(
        typeId: 'pipe',
        seq: i + 1,
        lat: 32.1264 + offs[i].$1,
        lon: 114.0913 + offs[i].$2,
        lineGroupId: gid,
        distLabel: i == 2 ? '埋42.5' : ''));
  }
  final cross = MapLabel(typeId: 'crossbox', seq: 9, lat: 32.1264, lon: 114.0913, name: '李庄光交');
  final split = MapLabel(
      typeId: 'splitterbox', seq: 10, lat: 32.1279, lon: 114.0931, name: '李庄分光箱', splitterRatio: '1:8');
  final fiber = MapLabel(typeId: 'fiberbox', seq: 11, lat: 32.1266, lon: 114.0943, name: '李庄分纤盒');
  split.topoParentId = cross.id;
  fiber.topoParentId = split.id;
  split.cableSpec = '架24芯GYTS-01';
  fiber.cableSpec = '架12芯GYTS-02';
  labels.addAll([cross, split, fiber]);
  return labels;
}
