// ============================================================================
// QA 独立对抗性验证（严过关）—— 不复用工程师任何 fixture，全部自造数据。
// 目的：证明"真的修好了"，而不是"测试是绿的"。
//
//   坑① 纸面毫米换算：证明线宽不再等于真实路宽（结构 + 行为双向取证）
//   坑② R12 输出不得含 R2000 专有物（自产 R12 硬断言 + 配对状态机）
//   坑③ N1/N2 全修（自写合成 Overpass JSON）
//   边界：极短/极长线路不炸、空 labels 明确异常、GBK 中文/特殊字符回读
//   HATCH 组码最小集自洽（CAD 实机部分明确标注）
//   失败三态结构化、离线缓存命中、成册固定 R12（兼容优先）
// ============================================================================
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/export/archive_book.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/export/overpass.dart';
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

// ------------------------- DXF 结构解析工具 -------------------------

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

  List<String> all(String c) => [for (final p in kv) if (p[0] == c) p[1]];

  /// LWPOLYLINE / 多段线顶点（10=x，20=y，按出现顺序配对）。
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

List<_Ent> _entities(String text) {
  final lines = text.split('\n');
  final out = <_Ent>[];
  _Ent? cur;
  for (var i = 0; i + 1 < lines.length; i += 2) {
    final c = lines[i].trim();
    final v = lines[i + 1].trim();
    if (c == '0') {
      cur = _Ent(v);
      out.add(cur);
    } else if (cur != null) {
      cur.kv.add([c, v]);
    }
  }
  return out;
}

List<_Ent> _on(List<_Ent> ents, String type, String layer) => ents
    .where((e) => e.type == type && (e.first('8') ?? '') == layer)
    .toList();

/// 复刻 DxfExporter._pickScale（独立复算，用于期望值）。
int _pickScale(double minX, double minY, double maxX, double maxY) {
  const m = 10.0;
  final contentW = (maxX - minX + 2 * m).abs().clamp(1.0, 1e9);
  final raw = contentW / 0.40;
  const std = [100, 200, 250, 500, 1000, 2000, 2500, 5000, 10000];
  for (final s in std) {
    if (raw <= s) return s;
  }
  return (raw / 1000).ceil() * 1000;
}

// ------------------------- 测试数据工厂 -------------------------

const double kLat = 32.1264;
const double kLon = 114.0913;

/// 三个点（跨度 0.002°），把出图比例钉到 1:1000（与 A2 同口径）。
List<MapLabel> _poles(double lat, double lon, {double span = 0.002}) => [
      MapLabel(typeId: 'pipe', seq: 1, lat: lat, lon: lon, lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe', seq: 2, lat: lat, lon: lon + span / 2, lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe', seq: 3, lat: lat, lon: lon + span, lineGroupId: 'g'),
    ];

BasemapFetchReport _okReport({int roads = 0, int b = 0, int p = 0}) =>
    BasemapFetchReport(
      roads: DatasetReport(FetchState.ok, count: roads),
      buildings: DatasetReport(FetchState.ok, count: b),
      places: DatasetReport(FetchState.ok, count: p),
    );

/// 单条水平道路（同一纬度 → 中心 y=0，描边应在 ±半宽）。
BasemapData _oneRoad(RoadGrade grade, double lat, double lon0, double lon1) {
  final pts = <List<double>>[];
  for (var i = 0; i <= 8; i++) {
    pts.add([lat, lon0 + (lon1 - lon0) * i / 8]);
  }
  return BasemapData(
    roads: [RoadPoly(pts, grade, '')],
    buildings: const [],
    places: const [],
    report: _okReport(roads: 1),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==========================================================================
  // 坑① 纸面毫米换算（对抗）：所有线宽必须是 纸面mm÷1000×比例，且与真实路宽无关
  // ==========================================================================
  test('坑①：道路半宽 = 纸面毫米×比例（逐等级），且绝不等于真实路宽 1:1', () async {
    final dir = Directory.systemTemp.createTempSync('qa_mm');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final labels = _poles(kLat, kLon);
    // 独立复算比例尺
    final scaleX = 111320.0 * math.cos(kLat * math.pi / 180);
    final scale = _pickScale(0, 0, (kLon + 0.002 - kLon) * scaleX, 0);
    expect(scale, 1000, reason: '该线路跨度应估为 1:1000');

    // 设计表：等级 → 半宽（纸面毫米）
    // v3.9.5 起路宽整体加倍（用户反馈"路有点窄"）。
    const halfMm = <RoadGrade, double>{
      RoadGrade.trunk: 0.90,
      RoadGrade.primary: 0.76,
      RoadGrade.secondary: 0.60,
      RoadGrade.tertiary: 0.50,
      RoadGrade.residential: 0.36,
      RoadGrade.service: 0.24,
      RoadGrade.other: 0.20,
    };

    final observed = <RoadGrade, double>{};
    for (final e in halfMm.entries) {
      final bm = _oneRoad(e.key, kLat, kLon - 0.003, kLon + 0.004);
      final r = await DxfExporter.export(
          name: 'qa_${e.key.name}',
          labels: labels,
          includeSurroundings: true,
          basemap: bm,
          version: DxfVersion.r2000);
      final text = latin1.decode(r.file.readAsBytesSync());
      final casing = _on(_entities(text), 'LWPOLYLINE', 'DaoLuBian');
      expect(casing, isNotEmpty, reason: '${e.key} 应有双线描边');
      var maxAbsY = 0.0;
      for (final ent in casing) {
        for (final p in ent.points()) {
          if (p[1].abs() > maxAbsY) maxAbsY = p[1].abs();
        }
      }
      final expected = e.value / 1000.0 * scale;
      expect(maxAbsY, closeTo(expected, 1e-6),
          reason: '${e.key} 半宽应为 纸面${e.value}mm×$scale = $expected m，实测 $maxAbsY m');
      observed[e.key] = maxAbsY;
    }

    // 等级越高越粗（严格递减）
    final ordered = [
      RoadGrade.trunk,
      RoadGrade.primary,
      RoadGrade.secondary,
      RoadGrade.tertiary,
      RoadGrade.residential,
      RoadGrade.service,
      RoadGrade.other,
    ];
    for (var i = 1; i < ordered.length; i++) {
      expect(observed[ordered[i]]!, lessThan(observed[ordered[i - 1]]!),
          reason: '${ordered[i - 1]} 应比 ${ordered[i]} 宽（分级可见）');
    }

    // 反向红线：绝不是"真实路宽 12m → 半宽 6m"
    expect(observed[RoadGrade.trunk]!, lessThan(1.0),
        reason: '主干半宽必须远小于真实路宽（否则"路太粗"复发）');

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('坑①：极短线路（约 10m）：比例尺不取极端值，不产生 NaN/Infinity', () async {
    final dir = Directory.systemTemp.createTempSync('qa_short');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final labels = _poles(32.0, 114.0, span: 0.0001); // ≈9.4m
    final bm = _oneRoad(RoadGrade.trunk, 32.0, 114.0, 114.0002);
    final r = await DxfExporter.export(
        name: 'qa_short',
        labels: labels,
        includeSurroundings: true,
        basemap: bm,
        version: DxfVersion.r2000);
    final text = latin1.decode(r.file.readAsBytesSync());

    expect(text.contains('NaN'), isFalse, reason: '出现 NaN');
    expect(text.contains('Infinity'), isFalse, reason: '出现 Infinity');
    _assertAllNumbersFinite(_entities(text));
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('坑①：极长线路（约 47km）：线宽/字号有限且为正，不炸', () async {
    final dir = Directory.systemTemp.createTempSync('qa_long');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final labels = _poles(32.0, 114.0, span: 0.5); // ≈47km
    final bm = _oneRoad(RoadGrade.trunk, 32.0, 114.0, 114.5);
    final bm2 = BasemapData(
      roads: bm.roads,
      buildings: const [],
      places: const [
        PlaceFeature(
            name: '验证市长途', lat: 32.0, lon: 114.25, level: PlaceLevel.city),
      ],
      report: _okReport(roads: 1, p: 1),
    );
    final r = await DxfExporter.export(
        name: 'qa_long',
        labels: labels,
        includeSurroundings: true,
        basemap: bm2,
        version: DxfVersion.r2000);
    final text = latin1.decode(r.file.readAsBytesSync());
    expect(text.contains('NaN'), isFalse);
    expect(text.contains('Infinity'), isFalse);
    _assertAllNumbersFinite(_entities(text));

    // 字号必须为正
    final texts = _entities(text).where((e) => e.type == 'TEXT').toList();
    expect(texts, isNotEmpty);
    for (final t in texts) {
      final h = double.tryParse(t.first('40') ?? '');
      expect(h, isNotNull);
      expect(h!, greaterThan(0));
    }
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('空 labels：导出应抛明确异常，而不是崩溃/产出空文件', () async {
    final dir = Directory.systemTemp.createTempSync('qa_empty');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    await expectLater(
      DxfExporter.export(name: 'qa_empty', labels: const []),
      throwsA(isA<Exception>()),
    );
    dir.deleteSync(recursive: true);
  });

  // ==========================================================================
  // 坑② R12 输出不得含 R2000 专有物（自产 DXF 硬断言）
  // ==========================================================================
  test('坑②：R12 输出无 370/420/LWPOLYLINE/HATCH，POLYLINE/VERTEX/SEQEND 一一配对，GBK 正常',
      () async {
    final dir = Directory.systemTemp.createTempSync('qa_r12');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final bm = _verifyBasemap();
    final r = await DxfExporter.export(
        name: 'qa_r12',
        labels: _poles(kLat, kLon),
        includeSurroundings: true,
        basemap: bm,
        version: DxfVersion.r12,
        buildingFill: true); // 显式开启：继续覆盖 R12 SOLID 填充路径
    final bytes = r.file.readAsBytesSync();
    final text = latin1.decode(bytes);
    final ents = _entities(text);

    // 版本头精确
    expect(text, contains('1\nAC1009\n'), reason: '\$ACADVER 应为 AC1009');
    // 独占行禁令（避免被坐标数字误伤）
    expect(text, isNot(contains('\n370\n')));
    expect(text, isNot(contains('\n420\n')));
    // 实体层禁令（逐实体类型，杜绝子串误判）
    expect(ents.any((e) => e.type == 'LWPOLYLINE'), isFalse);
    expect(ents.any((e) => e.type == 'HATCH'), isFalse);
    // R12 建筑填充回退 SOLID
    expect(ents.where((e) => e.type == 'SOLID').length, greaterThan(0));

    // POLYLINE / SEQEND 一一配对 + 状态机
    final polys = ents.where((e) => e.type == 'POLYLINE').toList();
    final seqs = ents.where((e) => e.type == 'SEQEND').toList();
    final verts = ents.where((e) => e.type == 'VERTEX').toList();
    expect(polys, isNotEmpty);
    expect(polys.length, seqs.length, reason: 'POLYLINE(${polys.length}) ≠ SEQEND(${seqs.length})');

    var inPoly = false, orphanVertex = 0, seqNoPoly = 0;
    for (final e in ents) {
      if (e.type == 'POLYLINE') {
        expect(inPoly, isFalse, reason: 'POLYLINE 嵌套');
        inPoly = true;
      } else if (e.type == 'VERTEX') {
        if (!inPoly) orphanVertex++;
      } else if (e.type == 'SEQEND') {
        if (!inPoly) seqNoPoly++;
        inPoly = false;
      }
    }
    expect(orphanVertex, 0);
    expect(seqNoPoly, 0);
    expect(inPoly, isFalse, reason: '结尾仍有未闭合 POLYLINE');
    expect(verts.length, greaterThan(0));
    for (final v in verts) {
      expect(v.first('8'), isNotEmpty);
    }

    // GBK 中文：自造名称回读不乱码；'李'=C0EE
    final decoded = gbk_bytes.decode(bytes);
    expect(decoded, contains('验证小区'));
    expect(decoded, contains('验证村'));
    expect(decoded.contains('\uFFFD'), isFalse);
    expect(bytes, containsAllInOrder([0xC0, 0xEE]));

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('坑②：R2000 应为 AC1015 且含 370/420/LWPOLYLINE/HATCH；默认版本为 R12', () async {
    final dir = Directory.systemTemp.createTempSync('qa_r2000');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final bm = _verifyBasemap();
    final r = await DxfExporter.export(
        name: 'qa_r2000',
        labels: _poles(kLat, kLon),
        includeSurroundings: true,
        basemap: bm,
        version: DxfVersion.r2000,
        buildingFill: true); // 显式开启：继续覆盖 HATCH 填充路径
    final text = latin1.decode(r.file.readAsBytesSync());
    final ents = _entities(text);

    expect(text, contains('1\nAC1015\n'));
    expect(text, contains('\n370\n'));
    expect(text, contains('\n420\n'));
    expect(ents.any((e) => e.type == 'LWPOLYLINE'), isTrue);
    expect(ents.any((e) => e.type == 'HATCH'), isTrue);
    expect(_on(ents, 'LWPOLYLINE', 'DaoLuBian'), isNotEmpty);
    // 道路中心线已按新规格删除：R2000 也不得输出 DaoLuZhong 实体
    expect(_on(ents, 'LWPOLYLINE', 'DaoLuZhong'), isEmpty,
        reason: '不应输出道路中心线（DaoLuZhong 已删除）');
    expect(_on(ents, 'HATCH', 'JianZhuFill'), isNotEmpty);

    // 默认版本（不传 version）应为 **R12（AC1009）**——最广兼容、ezdxf 严格可开
    final r2 = await DxfExporter.export(
        name: 'qa_default',
        labels: _poles(kLat, kLon),
        includeSurroundings: true,
        basemap: bm);
    expect(latin1.decode(r2.file.readAsBytesSync()), contains('1\nAC1009\n'));

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ==========================================================================
  // 坑③ N1 / N2 / 地名（自写合成 Overpass JSON）
  // ==========================================================================
  test('坑③ N1：无名 service/track/path/residential/unclassified/living_street 保留；'
      '无名 footway/steps/cycleway/pedestrian/bridleway 丢弃', () {
    Map<String, dynamic> way(String hw, double lon, {String? name}) => {
          'type': 'way',
          'geometry': [
            {'lat': 30.0, 'lon': lon},
            {'lat': 30.001, 'lon': lon},
          ],
          'tags': {'highway': hw, if (name != null) 'name': name},
        };
    final json = jsonEncode({
      'elements': [
        way('service', 100.0),
        way('track', 100.01),
        way('path', 100.02),
        way('residential', 100.03),
        way('unclassified', 100.04),
        way('living_street', 100.05),
        way('footway', 100.10),
        way('steps', 100.11),
        way('cycleway', 100.12),
        way('pedestrian', 100.13),
        way('bridleway', 100.14),
        way('footway', 100.20, name: '有名步道'),
      ]
    });
    final roads = OverpassClient.parseRoads(json);
    // 保留：6 无名(service/track/path/residential/unclassified/living_street) + 1 有名 footway
    expect(roads.length, 7,
        reason: '应保留 6 无名内部路 + 1 有名 footway，实测 ${roads.length}');
    expect(roads.where((r) => r.grade == RoadGrade.service).length, 3,
        reason: 'service/track/path 归 service 且无名保留');
    expect(roads.any((r) => r.name == '有名步道'), isTrue);
  });

  test('坑③ N1：overpass.dart 不再有"丢弃 service 又给 service 赋宽"的矛盾死逻辑', () {
    // 结构性取证：RoadPoly 无 width 字段（真实路宽无法 1:1 进入渲染）
    final src = File('lib/export/basemap.dart').readAsStringSync();
    final roadPolyBlock = src.substring(
        src.indexOf('class RoadPoly'), src.indexOf('class BuildingPoly'));
    expect(roadPolyBlock.contains('width'), isFalse,
        reason: 'RoadPoly 不得含 width 字段（否则可能 1:1 用真实路宽）');
    // overpass.dart 不得出现对 service 的宽度赋值
    final op = File('lib/export/overpass.dart').readAsStringSync();
    expect(op.contains('width'), isFalse, reason: 'overpass.dart 不应再出现 width');
  });

  test('坑③ N2：relation 多环按 role 缝合，每个外环一个 BuildingPoly，内环作孔', () {
    List<Map<String, dynamic>> rect(
        double lat, double lon, double s, String? role) {
      final a = [lat, lon], b = [lat + s, lon], c = [lat + s, lon + s], d = [lat, lon + s];
      final segs = [
        [a, b],
        [b, c],
        [c, d],
        [d, a]
      ];
      return [
        for (final g in segs)
          {
            'type': 'way',
            if (role != null) 'role': role,
            'geometry': [
              for (final p in g) {'lat': p[0], 'lon': p[1]}
            ],
          }
      ];
    }

    // 外环A（含内环）+ 外环B（无 role → 应默认 outer）+ 一个单环 way
    final relation = {
      'type': 'relation',
      'tags': {'building': 'yes', 'name': '二号院'},
      'members': [
        ...rect(31.0000, 115.0000, 0.0010, 'outer'),
        ...rect(31.0003, 115.0003, 0.0003, 'inner'),
        ...rect(31.0020, 115.0020, 0.0010, null), // 无 role
      ],
    };
    final way = {
      'type': 'way',
      'geometry': [
        {'lat': 31.01, 'lon': 115.01},
        {'lat': 31.01, 'lon': 115.011},
        {'lat': 31.011, 'lon': 115.011},
      ],
      'tags': {'building': 'house', 'name': '单环屋'},
    };
    final buildings =
        OverpassClient.parseBuildings(jsonEncode({'elements': [relation, way]}));

    // 2 外环 → 2 个 BuildingPoly；way → 1 个
    expect(buildings.length, 3, reason: '每个外环一个 BuildingPoly + way 单环');
    final holed = buildings.where((b) => b.rings.length > 1).toList();
    expect(holed.length, 1, reason: '仅含内环的那个外环带孔');
    expect(holed.first.outer.length, greaterThanOrEqualTo(3));
    // 无 role 成员默认 outer：确保第二个外环也独立成块
    expect(buildings.where((b) => b.name == '二号院').length, 2,
        reason: '两个外环各自成块，均带 relation 名');
  });

  test('坑③ parsePlaces：place=* 点/面 + 具名 landuse=residential 的层级与落点', () {
    final json = jsonEncode({
      'elements': [
        {
          'type': 'node',
          'lat': 30.0,
          'lon': 120.0,
          'tags': {'place': 'village', 'name': '验证村'}
        },
        {
          'type': 'way',
          'center': {'lat': 30.1, 'lon': 120.1},
          'tags': {'place': 'suburb', 'name': '验证片区'}
        },
        {
          'type': 'relation',
          'center': {'lat': 30.2, 'lon': 120.2},
          'tags': {'place': 'town', 'name': '验证镇'}
        },
        {
          'type': 'way',
          'center': {'lat': 30.3, 'lon': 120.3},
          'tags': {'landuse': 'residential', 'name': '验证小区'}
        },
        {
          'type': 'node',
          'lat': 30.4,
          'lon': 120.4,
          'tags': {'landuse': 'residential'} // 无名 → 丢弃
        },
        {
          'type': 'node',
          'lat': 30.5,
          'lon': 120.5,
          'tags': {'place': 'village'} // 无名 → 丢弃
        },
        {
          'type': 'way',
          'tags': {'place': 'village', 'name': '无坐标'} // 无 lat/lon/center → 丢弃
        },
      ]
    });
    final places = OverpassClient.parsePlaces(json);
    expect(places.length, 4);
    expect(places.any((p) => p.name == '验证村' && p.level == PlaceLevel.village),
        isTrue);
    expect(places.any((p) => p.name == '验证片区' && p.level == PlaceLevel.suburb), isTrue);
    expect(places.any((p) => p.name == '验证镇' && p.level == PlaceLevel.town), isTrue);
    final xq = places.firstWhere((p) => p.name == '验证小区');
    expect(xq.level, PlaceLevel.residential);
    expect(xq.isArea, isTrue);
    expect(xq.lat, closeTo(30.3, 1e-9));
    expect(xq.lon, closeTo(120.3, 1e-9));
  });

  // ==========================================================================
  // 边界：GBK 中文/特殊字符回读
  // ==========================================================================
  test('边界：中文 + 特殊字符地名/建筑名 GBK 写出后回读不乱码', () async {
    final dir = Directory.systemTemp.createTempSync('qa_gbk');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    const cnName = '幸福小区（二期）·3组团';
    final bm = BasemapData(
      roads: const [],
      buildings: [
        BuildingPoly(const [
          [
            [32.1264, 114.0913],
            [32.1264, 114.0918],
            [32.1270, 114.0918],
          ]
        ], '李庄1号楼'),
      ],
      places: const [
        PlaceFeature(
            name: cnName, lat: kLat, lon: kLon, level: PlaceLevel.residential),
      ],
      report: _okReport(b: 1, p: 1),
    );
    for (final v in DxfVersion.values) {
      final r = await DxfExporter.export(
          name: 'qa_gbk_${v.name}',
          labels: _poles(kLat, kLon),
          includeSurroundings: true,
          basemap: bm,
          version: v);
      final bytes = r.file.readAsBytesSync();
      final decoded = gbk_bytes.decode(bytes);
      expect(decoded, contains(cnName), reason: '${v.name}: 特殊字符地名应完整回读');
      expect(decoded, contains('李庄1号楼'));
      expect(decoded.contains('\uFFFD'), isFalse, reason: '${v.name}: 出现替换符=乱码');
    }
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ==========================================================================
  // HATCH 组码最小集自洽（结构自洽可验；CAD 实机部分明确标注）
  // ==========================================================================
  test('HATCH 组码最小集自洽：91=路径数、93=顶点数、92/72/73/97/75/76 组合闭合', () async {
    final dir = Directory.systemTemp.createTempSync('qa_hatch');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    // 带孔建筑 → HATCH 应含 2 条边界路径（外环 + 孔）
    final bm = _verifyBasemap();
    final r = await DxfExporter.export(
        name: 'qa_hatch',
        labels: _poles(kLat, kLon),
        includeSurroundings: true,
        basemap: bm,
        version: DxfVersion.r2000,
        buildingFill: true); // 显式开启：HATCH 路径专项覆盖
    final text = latin1.decode(r.file.readAsBytesSync());
    final hatches = _entities(text).where((e) => e.type == 'HATCH').toList();
    expect(hatches, isNotEmpty);

    for (final h in hatches) {
      expect(h.first('2'), 'SOLID');
      expect(h.first('70'), '1'); // 实体填充
      expect(h.first('71'), '0');
      final pathCount = int.parse(h.first('91')!);
      // 路径数 = 92 组数 = 73 组数 = 97 组数
      expect(h.all('92').length, pathCount);
      expect(h.all('73').length, pathCount);
      expect(h.all('97').length, pathCount);
      // 各码取值
      expect(h.all('92').every((v) => v == '7'), isTrue);
      expect(h.all('72').every((v) => v == '0'), isTrue);
      expect(h.all('73').every((v) => v == '1'), isTrue);
      expect(h.all('97').every((v) => v == '0'), isTrue);
      // 顶点数一致性：Σ93 == 10 数 == 20 数
      final sum93 = h.all('93').fold<int>(0, (a, b) => a + int.parse(b));
      expect(h.all('10').length, sum93, reason: '10 组码数应等于 Σ93');
      expect(h.all('20').length, sum93, reason: '20 组码数应等于 Σ93');
      // 收尾：75=0（普通样式）/ 76=1（预定义图案）
      final kv = h.kv;
      expect(kv[kv.length - 2][0], '75');
      expect(kv[kv.length - 2][1], '0');
      expect(kv[kv.length - 1][0], '76');
      expect(kv[kv.length - 1][1], '1');
      // 注：种子点（98/10/20）与图案定义是否为 AutoCAD/浩辰/中望/天正 全部接受，
      //     只能在 CAD 实机验证（本用例只保证"结构自洽、顶点数一致"）。
    }
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ==========================================================================
  // 失败三态：无网络 / 无数据 / 部分成功 → warnings 结构化且不抛错，DXF 仍产出
  // ==========================================================================
  test('失败三态：warnings 结构化且不抛错，DXF 仍能产出', () async {
    final dir = Directory.systemTemp.createTempSync('qa_fail');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final labels = _poles(kLat, kLon);

    // (1) 全失败（无网络）
    final allFail = BasemapData(
      roads: const [],
      buildings: const [],
      places: const [],
      report: const BasemapFetchReport(
        roads: DatasetReport(FetchState.failed, error: '网络不可达且无缓存'),
        buildings: DatasetReport(FetchState.failed, error: '网络不可达且无缓存'),
        places: DatasetReport(FetchState.failed, error: '网络不可达且无缓存'),
      ),
    );
    final r1 = await DxfExporter.export(
        name: 'qa_allfail',
        labels: labels,
        includeSurroundings: true,
        basemap: allFail,
        version: DxfVersion.r2000);
    expect(r1.file.existsSync(), isTrue);
    expect(r1.report!.allFailed, isTrue);
    expect(r1.warnings.any((s) => s.contains('道路矢量')), isTrue);
    expect(r1.warnings.any((s) => s.contains('建筑轮廓')), isTrue);
    expect(r1.warnings.any((s) => s.contains('地名')), isTrue);
    expect(r1.warnings.any((s) => s.contains('刷新底图')), isTrue);

    // (2) 无数据（成功但空）
    final noData = BasemapData(
      roads: const [],
      buildings: const [],
      places: const [],
      report: _okReport(),
    );
    final r2 = await DxfExporter.export(
        name: 'qa_nodata',
        labels: labels,
        includeSurroundings: true,
        basemap: noData,
        version: DxfVersion.r2000);
    expect(r2.file.existsSync(), isTrue);
    expect(r2.report!.anyFailed, isFalse);
    expect(r2.warnings.any((s) => s.contains('无道路矢量')), isTrue);

    // (3) 部分成功（道路 ok / 建筑失败 / 地名缓存）
    final partial = BasemapData(
      roads: const [],
      buildings: const [],
      places: const [],
      report: const BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, count: 5),
        buildings: DatasetReport(FetchState.failed, error: '超时'),
        places: DatasetReport(FetchState.cached, count: 3),
      ),
    );
    final r3 = await DxfExporter.export(
        name: 'qa_partial',
        labels: labels,
        includeSurroundings: true,
        basemap: partial,
        version: DxfVersion.r2000);
    expect(r3.file.existsSync(), isTrue);
    expect(r3.report!.anyFailed, isTrue);
    expect(r3.warnings.any((s) => s.contains('建筑轮廓')), isTrue);
    expect(r3.warnings.any((s) => s.contains('缓存')), isTrue);

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ==========================================================================
  // 缓存：自造参数（子范围/超范围/隔离/失效/过期/离线持续）
  // ==========================================================================
  test('缓存：自造参数覆盖命中/超范围/隔离/失效/过期/跨实例离线可读', () async {
    final dir = Directory.systemTemp.createTempSync('qa_cache');
    final cache = BasemapCache(dir);
    final bbox = [31.50, 113.50, 31.60, 113.60];
    const json = '{"elements":[]}';

    expect(await cache.read('roads', bbox), isNull);
    await cache.write('roads', bbox, json);

    // 相同 & 子范围命中
    expect(await cache.read('roads', bbox), json);
    expect(await cache.read('roads', [31.52, 113.52, 31.58, 113.58]), json);
    // 超范围不命中
    expect(await cache.read('roads', [31.0, 113.0, 32.0, 114.0]), isNull);
    // 跨数据集隔离
    expect(await cache.read('buildings', [31.52, 113.52, 31.58, 113.58]), isNull);
    // 过期不复用
    expect(await cache.read('roads', bbox, maxAgeDays: -1), isNull);
    // 新实例（模拟重启）仍可读 → 离线复用
    final cache2 = BasemapCache(dir);
    expect(await cache2.read('roads', bbox), json);
    // invalidate 生效
    await cache.invalidate(bbox);
    expect(await cache.read('roads', bbox), isNull);

    dir.deleteSync(recursive: true);
  });

  // ==========================================================================
  // 抓取编排：缓存优先（离线路径不发生网络）→ 出图
  // ==========================================================================
  test('抓取编排：项目级缓存命中走离线路径（不触网）并可正常出图', () async {
    final dir = Directory.systemTemp.createTempSync('qa_fetch');
    final cache = BasemapCache(dir);

    final labels = _poles(30.0, 120.0, span: 0.001);
    final bbox = BasemapFetcher.boundsOf(labels, 880);

    // 预写缓存（三条数据集），几何均在 bbox 内
    await cache.write(
        'roads',
        bbox,
        jsonEncode({
          'elements': [
            {
              'type': 'way',
              'geometry': [
                {'lat': 30.0, 'lon': 120.0},
                {'lat': 30.0005, 'lon': 120.0},
              ],
              'tags': {'highway': 'residential'}
            }
          ]
        }));
    await cache.write(
        'buildings',
        bbox,
        jsonEncode({
          'elements': [
            {
              'type': 'way',
              'geometry': [
                {'lat': 30.0, 'lon': 120.0},
                {'lat': 30.0, 'lon': 120.0005},
                {'lat': 30.0005, 'lon': 120.0005},
              ],
              'tags': {'building': 'yes'}
            }
          ]
        }));
    await cache.write(
        'places',
        bbox,
        jsonEncode({
          'elements': [
            {
              'type': 'node',
              'lat': 30.0,
              'lon': 120.0,
              'tags': {'place': 'village', 'name': '缓存验证村'}
            }
          ]
        }));

    final data =
        await BasemapFetcher.fetchFor(labels, cache: cache, useTdt: false);
    expect(data.report.roads.state, FetchState.cached);
    expect(data.report.buildings.state, FetchState.cached);
    expect(data.report.places.state, FetchState.cached);
    expect(data.roads.length, 1);
    expect(data.buildings.length, 1);
    expect(data.places.length, 1);
    expect(data.places.first.name, '缓存验证村');

    // 用缓存数据出图
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final r = await DxfExporter.export(
        name: 'qa_fetch',
        labels: labels,
        includeSurroundings: true,
        basemap: data,
        version: DxfVersion.r2000);
    final text = latin1.decode(r.file.readAsBytesSync());
    expect(text, contains('DaoLuBian'));
    expect(text, contains('JianZhu'));
    expect(gbk_bytes.decode(r.file.readAsBytesSync()), contains('缓存验证村'));

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ==========================================================================
  // A6 绘制顺序核查：业务图层须在底图之上（DXF 后写者在上层）
  // ==========================================================================
  test('A6：底图实体应先于业务实体写出（业务在底图之上，不被底图压住）', () async {
    final dir = Directory.systemTemp.createTempSync('qa_a6');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final r = await DxfExporter.export(
        name: 'qa_a6',
        labels: _poles(kLat, kLon),
        includeSurroundings: true,
        basemap: _verifyBasemap(),
        version: DxfVersion.r2000,
        buildingFill: true); // 显式开启：连同填充一起核查"底图先写、业务后写"
    final ents = _entities(latin1.decode(r.file.readAsBytesSync()));

    const basemapLayers = {
      'DaoLuBian',
      'DaoLuZhong',
      'DaoLu',
      'JianZhu',
      'JianZhuFill',
      'DiMing',
    };
    const bizLayers = {'GanLu', 'PeiXianTu'};
    int? firstBiz, lastBasemap;
    for (var i = 0; i < ents.length; i++) {
      final layer = ents[i].first('8') ?? '';
      if (basemapLayers.contains(layer)) lastBasemap = i;
      if (bizLayers.contains(layer)) firstBiz ??= i;
    }
    expect(firstBiz, isNotNull);
    expect(lastBasemap, isNotNull);
    // DXF 后写者绘制在上层：要让业务在底图之上，底图必须"先写"。
    expect(lastBasemap! < firstBiz!, isTrue,
        reason: 'A6 违规：底图实体最后出现在 idx=$lastBasemap，业务实体首现于 idx=$firstBiz；'
            '底图后写 → 默认绘制在业务层之上，杆路/配线会被道路与"建筑填充"压住');

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ==========================================================================
  // 成册：固定 R12（对外交付兼容优先），仍含 路由图.dxf，离线（不抓底图）
  // ==========================================================================
  test('成册：路由图.dxf 为 R12（最兼容），离线语义不变', () async {
    final dir = Directory.systemTemp.createTempSync('qa_book');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final labels = _poles(32.0, 114.0);
    final r = await ArchiveBookExporter.export(name: 'QA成册', labels: labels);
    expect(r.included.contains('路由图.dxf'), isTrue);

    final arc = ZipDecoder().decodeBytes(r.zip.readAsBytesSync());
    final dxf = arc.files.firstWhere((e) => e.name == '路由图.dxf');
    final content = latin1.decode(dxf.content as List<int>);
    // 成册对外交付 → 固定 R12（AC1009），兼容性优先（与全局默认一致）
    expect(content, contains('1\nAC1009\n'));
    // 离线成册：不抓底图 → 不产生任何底图图层上的"实体"（图层表仍会声明图层，属正常）
    const basemapLayers = {
      'DaoLuBian',
      'DaoLuZhong',
      'DaoLu',
      'JianZhu',
      'JianZhuFill',
      'DiMing',
    };
    final basemapEnts = _entities(content)
        .where((e) => basemapLayers.contains(e.first('8')))
        .toList();
    expect(basemapEnts, isEmpty, reason: '离线成册不得输出底图实体');
    // 注意：R2000 合法文件必含 CLASSES 段，其中声明了 `HATCH` 类名（字符串必然出现），
    // 但**不得有 HATCH 实体**。字符串 matching 不足为证，须按实体类型判定（P0-2 教训）。
    expect(_entities(content).any((e) => e.type == 'HATCH'), isFalse,
        reason: '离线成册不得含 HATCH 实体');

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

// ------------------------- 断言辅助 -------------------------

void _assertAllNumbersFinite(List<_Ent> ents) {
  for (final e in ents) {
    for (final p in e.kv) {
      final c = p[0];
      // 10/20/11/21/12/22/13/23/40/41/43/50 等数值组码
      if (c == '10' ||
          c == '20' ||
          c == '11' ||
          c == '21' ||
          c == '12' ||
          c == '22' ||
          c == '13' ||
          c == '23' ||
          c == '40' ||
          c == '41' ||
          c == '43' ||
          c == '50') {
        final d = double.tryParse(p[1]);
        if (d != null) {
          expect(d.isFinite, isTrue, reason: '组码 $c 出现非有限值: ${p[1]}');
        }
      }
    }
  }
}

/// 验证底图：4 等级道路 + 带孔建筑 + 多级地名（自造，独立于工程师 fixture）。
BasemapData _verifyBasemap() {
  List<List<double>> line(double lat0, double lon0, double lat1, double lon1,
      {int n = 5}) {
    final out = <List<double>>[];
    for (var i = 0; i <= n; i++) {
      final t = i / n;
      out.add([lat0 + (lat1 - lat0) * t, lon0 + (lon1 - lon0) * t]);
    }
    return out;
  }

  return BasemapData(
    roads: [
      RoadPoly(line(32.1264, 114.0895, 32.1264, 114.0935, n: 6),
          RoadGrade.trunk, '验证大道'),
      RoadPoly(line(32.1255, 114.0913, 32.1285, 114.0913, n: 6),
          RoadGrade.primary, '验证路'),
      RoadPoly(line(32.1290, 114.0920, 32.1296, 114.0928, n: 3),
          RoadGrade.secondary, '验证支路'),
      RoadPoly(line(32.1240, 114.0940, 32.1248, 114.0948, n: 3),
          RoadGrade.service, ''),
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
      BuildingPoly([
        [
          [32.1250, 114.0930],
          [32.1250, 114.0934],
          [32.1254, 114.0934],
          [32.1254, 114.0930],
        ],
      ], ''),
    ],
    places: [
      const PlaceFeature(
          name: '验证市', lat: 32.1200, lon: 114.0900, level: PlaceLevel.city),
      const PlaceFeature(
          name: '验证村', lat: 32.1285, lon: 114.0922, level: PlaceLevel.village),
      const PlaceFeature(
          name: '验证小区',
          lat: 32.1270,
          lon: 114.0926,
          level: PlaceLevel.residential,
          isArea: true),
    ],
    report: _okReport(roads: 4, b: 2, p: 3),
  );
}
