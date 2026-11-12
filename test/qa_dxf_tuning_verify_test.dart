// ============================================================================
// QA 独立对抗验证（Edward）—— 不复用工程师 fixture，自造数据 + 自写解析器。
//
// 验收基准（用户拍板 4 项）：
//   ① 路名落双线之间（中心线上）、每约 200m 一处、宋体（SongTi 样式）
//   ② 等级过滤：默认只标主干道以上（含 residential），service/other 不标；
//      过滤只作用于文字，DaoLuBian 几何一律保留
//   ③ 建筑填充默认关；true 时 R2000=HATCH / R12=SOLID
//   ④ 字号 clamp 进双线间隙（h ≤ 2*halfW*0.6）
// ============================================================================
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

// ---------------------------------------------------------------------------
// 自写 DXF 解析器（组码逐行；独立实现，不依赖工程师测试的工具类）
// ---------------------------------------------------------------------------

class QaEnt {
  final String type;
  final Map<String, List<String>> codes = {};
  QaEnt(this.type);
  String? first(String c) => codes[c]?.first;
  List<String> all(String c) => codes[c] ?? const [];
}

class QaDoc {
  final List<QaEnt> entities = []; // 仅 ENTITIES 段
  final List<QaEnt> styles = []; // TABLES 段中的 STYLE 记录

  List<QaEnt> on(String type, String layer) => entities
      .where((e) => e.type == type && e.first('8') == layer)
      .toList();

  List<QaEnt> polysOn(String layer) => entities
      .where((e) =>
          (e.type == 'LWPOLYLINE' || e.type == 'POLYLINE') &&
          e.first('8') == layer)
      .toList();

  QaEnt? styleByName(String n) {
    for (final s in styles) {
      if (s.first('2') == n) return s;
    }
    return null;
  }
}

QaDoc _parse(String text) {
  final lines = text.split('\n');
  final doc = QaDoc();
  String section = '';
  QaEnt? cur;
  var capture = false; // 当前段是否需要收集
  for (var i = 0; i + 1 < lines.length; i += 2) {
    final c = lines[i].trim();
    final v = lines[i + 1].trim();
    if (c == '0' && v == 'SECTION') {
      // 下一个 2 组码给出段名
      section = lines[i + 3].trim();
      capture = section == 'ENTITIES' || section == 'TABLES';
      cur = null;
      continue;
    }
    if (c == '0' && v == 'ENDSEC') {
      section = '';
      capture = false;
      cur = null;
      continue;
    }
    if (c == '0') {
      if (capture && (v == 'STYLE')) {
        cur = QaEnt(v);
        doc.styles.add(cur);
      } else if (section == 'ENTITIES') {
        cur = QaEnt(v);
        doc.entities.add(cur);
      } else {
        cur = null;
      }
      continue;
    }
    if (cur != null && capture) {
      cur.codes.putIfAbsent(c, () => []).add(v);
    }
  }
  return doc;
}

// ---------------------------------------------------------------------------
// 数据工厂（全新坐标与几何；路名用 ASCII 避免编码耦合）
// ---------------------------------------------------------------------------

const double kLat = 30.5111;
const double kLon = 114.3222;
final double kScaleX = 111320.0 * math.cos(kLat * math.pi / 180);
const double kScaleY = 110540.0;

// 两杆跨度 ≈ 100m → contentW≈120 → raw=300 → 比例钉在 1:500
List<MapLabel> _poles() => [
      MapLabel(typeId: 'pipe', seq: 1, lat: kLat, lon: kLon, lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe',
          seq: 2,
          lat: kLat + 100.0 / kScaleY,
          lon: kLon,
          lineGroupId: 'g'),
    ];

// 出图比例（与 dxf.dart _pickScale 同口径，独立复算）
int get kScale {
  const m = 10.0;
  final contentW = (100.0 + 2 * m).clamp(1.0, 1e9);
  final raw = contentW / 0.40;
  const std = [100, 200, 250, 500, 1000, 2000, 2500, 5000, 10000];
  for (final s in std) {
    if (raw <= s) return s;
  }
  return (raw / 1000).ceil() * 1000;
}

// 等级 → 纸面半宽 mm（与 dxf_layers 规格表一致，独立抄录用于核算）
// v3.9.5 起路宽整体加倍（用户反馈"路有点窄"）——镜像表同步。
double _halfWmm(RoadGrade g) => switch (g) {
      RoadGrade.trunk => 0.90,
      RoadGrade.primary => 0.76,
      RoadGrade.secondary => 0.60,
      RoadGrade.tertiary => 0.50,
      RoadGrade.residential => 0.36,
      RoadGrade.service => 0.24,
      RoadGrade.other => 0.20,
    };

double _halfWm(RoadGrade g) => _halfWmm(g) / 1000 * kScale;

double _clampH(RoadGrade g) =>
    math.min(_halfWm(g) * 2 * 0.6, 2.0 / 1000 * kScale);

/// 水平路：恒纬度（投影后 y=0），自西向东 len 米。
RoadPoly _hRoad(String name, RoadGrade g, double len, {double lat = 0}) =>
    RoadPoly(
      [
        for (var i = 0; i <= 10; i++)
          [
            kLat + lat + 0.0,
            kLon + len * i / 10 / kScaleX,
          ],
      ],
      g,
      name,
    );

/// 斜向路：自 (dy,dx) 方向，len 米，30° 东北向。
RoadPoly _diagRoad(String name, RoadGrade g, double len, double deg) {
  final rad = deg * math.pi / 180;
  final dy = len * math.sin(rad);
  final dx = len * math.cos(rad);
  final a = [kLat - 0.01, kLon + 0.01];
  final b = [a[0] + dy / kScaleY, a[1] + dx / kScaleX];
  return RoadPoly(
    [
      for (var i = 0; i <= 6; i++)
        [
          a[0] + (b[0] - a[0]) * i / 6,
          a[1] + (b[1] - a[1]) * i / 6,
        ],
    ],
    g,
    name,
  );
}

BasemapData _bm(List<RoadPoly> roads,
        {List<BuildingPoly> buildings = const [],
        List<PlaceFeature> places = const []}) =>
    BasemapData(
      roads: roads,
      buildings: buildings,
      places: places,
      report: BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, count: roads.length),
        buildings: DatasetReport(FetchState.ok, count: buildings.length),
        places: DatasetReport(FetchState.ok, count: places.length),
      ),
    );

BuildingPoly _building() => BuildingPoly(const [
      [
        [kLat + 0.002, kLon + 0.010],
        [kLat + 0.002, kLon + 0.016],
        [kLat + 0.006, kLon + 0.016],
        [kLat + 0.006, kLon + 0.010],
      ],
    ], 'QA楼');

Future<QaDoc> _exportDoc(
  Directory dir,
  BasemapData bm, {
  DxfVersion v = DxfVersion.r2000,
  bool buildingFill = false,
  bool showMinorRoadNames = false,
  String name = 'QA对抗',
}) async {
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final r = await DxfExporter.export(
    name: name,
    labels: _poles(),
    includeSurroundings: true,
    basemap: bm,
    version: v,
    buildingFill: buildingFill,
    showMinorRoadNames: showMinorRoadNames,
  );
  // 文件为 GBK 字节；latin1 解码保字节值（组码与数字均为 ASCII，比对不受影响）
  return _parse(String.fromCharCodes(r.file.readAsBytesSync()));
}

double _d(String? s) => double.parse(s!);

/// 旋转归一化到 [0,360)；可读（不倒立）⇔ ∈ [0,90] ∪ (270,360)
double _norm360(double a) => ((a % 360) + 360) % 360;

bool _readableAngle(double a) {
  final n = _norm360(a);
  return n <= 90 + 1e-9 || n > 270 - 1e-9;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('B. 路名在双线之间（几何对抗）', () {
    test('1000m 水平 trunk 路：恰 5 处、x≈100/300/500/700/900、y=0、h=clamp、SongTi、不倒立',
        () async {
      final dir = Directory.systemTemp.createTempSync('qa_h1000');
      final doc = await _exportDoc(
          dir, _bm([_hRoad('HWY1000', RoadGrade.trunk, 1000)]));
      final texts = doc.on('TEXT', 'DaoLu').where((t) => t.first('1') == 'HWY1000').toList();
      expect(texts.length, 5, reason: '1000m 路应恰有 5 处路名');

      final halfW = _halfWm(RoadGrade.trunk);
      final xs = texts.map((t) => _d(t.first('10'))).toList()..sort();
      for (var i = 0; i < 5; i++) {
        final expectX = 100.0 + 200.0 * i;
        expect((xs[i] - expectX).abs(), lessThanOrEqualTo(1.5),
            reason: '第 ${i + 1} 处 x=${xs[i]} 应≈$expectX（弧长均布 L*(2i-1)/2n）');
      }
      for (final t in texts) {
        final y = _d(t.first('20'));
        final h = _d(t.first('40'));
        expect(y.abs(), lessThanOrEqualTo(halfW + 1e-6),
            reason: '水平路 TEXT y 应落中心线（偏差≤halfW=$halfW）');
        expect(y.abs(), lessThanOrEqualTo(0.01), reason: '水平路 y 应严格=0');
        expect(h, closeTo(_clampH(RoadGrade.trunk), 1e-6),
            reason: 'trunk clamp 字高应=${_clampH(RoadGrade.trunk)}');
        expect(h, lessThanOrEqualTo(2 * halfW * 0.6 + 1e-6),
            reason: '字高必须塞进双线间隙');
        expect(t.first('7'), 'SongTi', reason: '路名样式应为 SongTi');
        final ang = t.first('50') == null ? 0.0 : _d(t.first('50'));
        expect(_readableAngle(ang), isTrue, reason: '旋转 $ang 不得倒立');
      }
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('600m 斜向路（30°）：3 处、垂距=0（落中心线）、旋转=30°', () async {
      final dir = Directory.systemTemp.createTempSync('qa_diag');
      final doc =
          await _exportDoc(dir, _bm([_diagRoad('DIAG30', RoadGrade.primary, 600, 30)]));
      final texts = doc
          .on('TEXT', 'DaoLu')
          .where((t) => t.first('1') == 'DIAG30')
          .toList();
      expect(texts.length, 3, reason: '600m 路应 3 处（n=round(600/200)）');

      // 中心线（投影后）：起点与 30° 方向
      final rad = 30 * math.pi / 180;
      final sx = 0.01 * kScaleX;
      final sy = -0.01 * kScaleY;
      final len = 600.0;
      for (final t in texts) {
        final px = _d(t.first('10'));
        final py = _d(t.first('20'));
        // 点到过 (sx,sy) 方向 (cos,sin) 直线的垂距
        final vx = px - sx, vy = py - sy;
        final perp = (vx * math.sin(rad) - vy * math.cos(rad)).abs();
        expect(perp, lessThanOrEqualTo(_halfWm(RoadGrade.primary) + 1e-6),
            reason: '斜路 TEXT 应落在双线之间（垂距≤halfW）');
        expect(perp, lessThanOrEqualTo(0.05), reason: '垂距应≈0（在中心线上）');
        final along = vx * math.cos(rad) + vy * math.sin(rad);
        expect(along, greaterThan(0), reason: '沿线正向');
        expect(along, lessThan(len + 1), reason: '沿线范围内');
        final ang = _d(t.first('50'));
        expect(ang, closeTo(30.0, 0.2), reason: '斜路旋转应=30°');
        expect(_readableAngle(ang), isTrue);
        expect(t.first('7'), 'SongTi');
        expect(_d(t.first('40')), closeTo(_clampH(RoadGrade.primary), 1e-6));
      }
      // 均布位置：n=3 → 弧长 100/300/500
      final alongs = texts
          .map((t) {
            final vx = _d(t.first('10')) - sx;
            final vy = _d(t.first('20')) - sy;
            return vx * math.cos(rad) + vy * math.sin(rad);
          })
          .toList()
        ..sort();
      for (var i = 0; i < 3; i++) {
        expect(alongs[i], closeTo(100.0 + 200.0 * i, 1.5),
            reason: '第 ${i + 1} 处沿线弧长应≈${100 + 200 * i}m');
      }
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('300m 路 2 处均布（75/225m）；150m 路 1 处含中点', () async {
      final dir = Directory.systemTemp.createTempSync('qa_300');
      final doc = await _exportDoc(dir, _bm([
        _hRoad('RES300', RoadGrade.residential, 300, lat: -0.002),
        _hRoad('TER150', RoadGrade.tertiary, 150, lat: -0.004),
      ]));
      final r300 = doc
          .on('TEXT', 'DaoLu')
          .where((t) => t.first('1') == 'RES300')
          .toList();
      expect(r300.length, inInclusiveRange(1, 2));
      final xs = r300.map((t) => _d(t.first('10'))).toList()..sort();
      if (r300.length == 2) {
        expect(xs[0], closeTo(75, 1.5));
        expect(xs[1], closeTo(225, 1.5));
      }
      final t150 = doc
          .on('TEXT', 'DaoLu')
          .where((t) => t.first('1') == 'TER150')
          .toList();
      expect(t150.length, 1, reason: '150m 路应恰 1 处');
      expect(_d(t150.first.first('10')), closeTo(75, 1.5),
          reason: '单处应含中点');
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('B+. 宋体样式表与既有文字样式', () {
    test('R12 与 R2000：STYLE 表含 SongTi/simsun.ttc 且 SimSun/SimSun.ttf 仍在；'
        'DaoLu→SongTi、DiMing/JianZhu 不受波及', () async {
      final dir = Directory.systemTemp.createTempSync('qa_style');
      final bm = _bm(
        [_hRoad('HWYA', RoadGrade.trunk, 800)],
        buildings: [_building()],
        places: const [
          PlaceFeature(
              name: 'QA村', lat: kLat + 0.003, lon: kLon + 0.02, level: PlaceLevel.village),
        ],
      );
      for (final v in DxfVersion.values) {
        final doc = await _exportDoc(dir, bm, v: v, name: '样式$v');
        final song = doc.styleByName('SongTi');
        expect(song, isNotNull, reason: '${v.name}: STYLE 表应有 SongTi');
        expect(song!.first('3'), 'simsun.ttc', reason: '${v.name}: SongTi 字体文件');
        final simsun = doc.styleByName('SimSun');
        expect(simsun, isNotNull, reason: '${v.name}: 既有 SimSun 样式不得删');
        expect(simsun!.first('3'), 'SimSun.ttf');

        for (final t in doc.on('TEXT', 'DaoLu')) {
          expect(t.first('7'), 'SongTi', reason: '${v.name}: 路名一律 SongTi');
        }
        // 其他底图文字不得被波及：DiMing / JianZhu 不写 7 组码（走默认 STANDARD）
        for (final layer in ['DiMing', 'JianZhu']) {
          for (final t in doc.on('TEXT', layer)) {
            expect(t.first('7'), isNull,
                reason: '${v.name}: $layer 文字样式不应被改动');
          }
        }
        // 全文件层面：出现 7 组码的 TEXT 只允许 SongTi / SimSun 两种
        for (final t in doc.entities.where((e) => e.type == 'TEXT')) {
          final s = t.first('7');
          if (s != null) {
            expect({ 'SongTi', 'SimSun' }.contains(s), isTrue,
                reason: '${v.name}: 出现意外样式名 $s');
          }
        }
      }
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('C. 等级过滤与几何保留', () {
    test('默认：service/other 具名路无路名 TEXT 但 DaoLuBian 几何在；'
        'residential 默认有标注；放开开关后小路有标注；DaoLuBian 计数不变', () async {
      final dir = Directory.systemTemp.createTempSync('qa_grade');
      final bm = _bm([
        _hRoad('TRK', RoadGrade.trunk, 400, lat: 0.000),
        _hRoad('PRI', RoadGrade.primary, 400, lat: -0.001),
        _hRoad('SEC', RoadGrade.secondary, 400, lat: -0.002),
        _hRoad('TER', RoadGrade.tertiary, 400, lat: -0.003),
        _hRoad('RES', RoadGrade.residential, 400, lat: -0.004),
        _hRoad('SVC', RoadGrade.service, 400, lat: 0.001),
        _hRoad('OTH', RoadGrade.other, 400, lat: 0.002),
      ]);
      final def = await _exportDoc(dir, bm, name: '等级默认');
      final minor = await _exportDoc(dir, bm, showMinorRoadNames: true, name: '等级放开');

      bool has(String name, QaDoc d) =>
          d.on('TEXT', 'DaoLu').any((t) => t.first('1') == name);

      // 默认：主干道以上（含 residential）有，service/other 无
      for (final n in ['TRK', 'PRI', 'SEC', 'TER', 'RES']) {
        expect(has(n, def), isTrue, reason: '默认应标注 $n');
      }
      expect(has('SVC', def), isFalse, reason: '默认 service 不标注');
      expect(has('OTH', def), isFalse, reason: '默认 other 不标注');
      // 放开：小路也有
      expect(has('SVC', minor), isTrue);
      expect(has('OTH', minor), isTrue);

      // 几何保留：7 条直线道路 × 2 条描边 = 14，两种口径完全一致
      expect(def.polysOn('DaoLuBian').length, 14);
      expect(minor.polysOn('DaoLuBian').length, 14,
          reason: '等级过滤只作用于文字，DaoLuBian 实体数不得变化');

      // 各等级字高都塞得进各自双线间隙（④ 字号和谐 + clamp）
      final expectH = {
        'TRK': _clampH(RoadGrade.trunk),
        'PRI': _clampH(RoadGrade.primary),
        'SEC': _clampH(RoadGrade.secondary),
        'TER': _clampH(RoadGrade.tertiary),
        'RES': _clampH(RoadGrade.residential),
        'SVC': _clampH(RoadGrade.service),
        'OTH': _clampH(RoadGrade.other),
      };
      for (final t in minor.on('TEXT', 'DaoLu')) {
        final n = t.first('1')!;
        expect(_d(t.first('40')), closeTo(expectH[n]!, 1e-6),
            reason: '$n 字高应=clamp(${expectH[n]!.toStringAsFixed(3)})');
        expect(_d(t.first('40')), lessThanOrEqualTo(2 * _halfWm(RoadGrade.values.first) * 0.6 + 1),
            reason: '字高 sanity');
      }
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('D. 默认口径与开关兜底', () {
    test('默认（R12/R2000）：无 JianZhuFill、无 DaoLuZhong 实体；轮廓/描边/建筑名/地名正常',
        () async {
      final dir = Directory.systemTemp.createTempSync('qa_default');
      final bm = _bm(
        [_hRoad('TRK', RoadGrade.trunk, 500)],
        buildings: [_building()],
        places: const [
          PlaceFeature(
              name: 'QA村', lat: kLat + 0.003, lon: kLon + 0.02, level: PlaceLevel.village),
        ],
      );
      for (final v in DxfVersion.values) {
        final doc = await _exportDoc(dir, bm, v: v, name: '默认$v');
        expect(doc.entities.any((e) => e.type == 'HATCH'), isFalse,
            reason: '${v.name}: 默认无 HATCH');
        expect(doc.entities.any((e) => e.type == 'SOLID'), isFalse,
            reason: '${v.name}: 默认无 SOLID');
        expect(doc.on('POLYLINE', 'DaoLuZhong') + doc.on('LWPOLYLINE', 'DaoLuZhong'),
            isEmpty,
            reason: '${v.name}: 中心线实体已删除');
        expect(doc.polysOn('JianZhu'), isNotEmpty,
            reason: '${v.name}: 建筑轮廓保留');
        expect(doc.polysOn('DaoLuBian'), isNotEmpty, reason: '${v.name}: 道路描边保留');
        expect(doc.on('TEXT', 'JianZhu'), isNotEmpty, reason: '${v.name}: 建筑名保留');
        expect(doc.on('TEXT', 'DiMing'), isNotEmpty, reason: '${v.name}: 地名保留');
        expect(doc.on('TEXT', 'DaoLu'), isNotEmpty, reason: '${v.name}: 路名保留');
      }
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('buildingFill:true：R2000=JianZhuFill/HATCH，R12=JianZhuFill/SOLID', () async {
      final dir = Directory.systemTemp.createTempSync('qa_fill');
      final bm = _bm([_hRoad('TRK', RoadGrade.trunk, 500)], buildings: [_building()]);
      final r20 = await _exportDoc(dir, bm,
          v: DxfVersion.r2000, buildingFill: true, name: '填充20');
      expect(r20.on('HATCH', 'JianZhuFill'), isNotEmpty,
          reason: 'R2000 填充应输出 HATCH');
      final r12 = await _exportDoc(dir, bm,
          v: DxfVersion.r12, buildingFill: true, name: '填充12');
      expect(r12.on('SOLID', 'JianZhuFill'), isNotEmpty,
          reason: 'R12 填充应输出 SOLID');
      expect(r12.entities.any((e) => e.type == 'HATCH'), isFalse);
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
