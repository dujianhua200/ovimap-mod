// ============================================================================
// DXF 底图制图微调（第 4 批）对抗测试 —— 合成数据、零网络。
//
//   ① 路名放"双线之间"（中心线上）+ 每约 200 米一处 + 宋体（SongTi 样式）+ 字号 clamp
//   ② 路名按等级过滤（默认 trunk/primary/secondary/tertiary/residential；
//      service/other 不标；showMinorRoadNames 放开；几何 DaoLuBian 一律保留）
//   ③ 建筑填充默认关（buildingFill=false 不输出 JianZhuFill 实体；true 走原逻辑）
//   ④ 道路中心线删除（任何版本、任何参数都不得输出 DaoLuZhong 实体）
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
}

/// 仅解析 ENTITIES 段（排除表段/块定义）。
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

List<_Ent> _on(List<_Ent> ents, String type, String layer) => ents
    .where((e) => e.type == type && (e.first('8') ?? '') == layer)
    .toList();

/// 某图层上的全部多段线（R2000=LWPOLYLINE / R12=经典 POLYLINE）。
List<_Ent> _polysOn(List<_Ent> ents, String layer) => ents
    .where((e) =>
        (e.type == 'LWPOLYLINE' || e.type == 'POLYLINE') &&
        (e.first('8') ?? '') == layer)
    .toList();

// ------------------------- 数据工厂 -------------------------

const double kLat = 32.1264;
const double kLon = 114.0913;
final double kScaleX = 111320.0 * math.cos(kLat * math.pi / 180);

/// 三个点（跨度 0.002° ≈ 188m）→ 出图比例钉在 1:1000。
List<MapLabel> _poles() => [
      MapLabel(typeId: 'pipe', seq: 1, lat: kLat, lon: kLon, lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe',
          seq: 2,
          lat: kLat,
          lon: kLon + 0.001,
          lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe',
          seq: 3,
          lat: kLat,
          lon: kLon + 0.002,
          lineGroupId: 'g'),
    ];

BasemapFetchReport _ok({int roads = 0, int b = 0, int p = 0}) =>
    BasemapFetchReport(
      roads: DatasetReport(FetchState.ok, count: roads),
      buildings: DatasetReport(FetchState.ok, count: b),
      places: DatasetReport(FetchState.ok, count: p),
    );

/// 水平直线道路（同一纬度 → 笛卡尔 y=0，即中心线）。
RoadPoly _hRoad(RoadGrade grade, String name, double lon0, double lon1,
        {int n = 8}) =>
    RoadPoly(
      [
        for (var i = 0; i <= n; i++)
          [kLat, lon0 + (lon1 - lon0) * i / n],
      ],
      grade,
      name,
    );

/// 斜向直线道路（45°）。
RoadPoly _diagRoad(RoadGrade grade, String name, bool reversed) {
  const len = 500.0;
  final dLat = len / 110540.0;
  final dLon = len / kScaleX;
  final a = [kLat, kLon];
  final b = [kLat + dLat, kLon + dLon];
  final pts = reversed ? [b, a] : [a, b];
  return RoadPoly([
    for (var i = 0; i <= 6; i++)
      [
        pts[0][0] + (pts[1][0] - pts[0][0]) * i / 6,
        pts[0][1] + (pts[1][1] - pts[0][1]) * i / 6,
      ],
  ], grade, name);
}

BasemapData _bm(List<RoadPoly> roads, {List<BuildingPoly> buildings = const []}) =>
    BasemapData(
      roads: roads,
      buildings: buildings,
      places: const [],
      report: _ok(roads: roads.length, b: buildings.length),
    );

BuildingPoly _building() => BuildingPoly(const [
      [
        [32.1268, 114.0918],
        [32.1268, 114.0924],
        [32.1273, 114.0924],
        [32.1273, 114.0918],
      ],
    ], '微调楼');

Future<String> _exportText(
  Directory dir,
  BasemapData bm, {
  DxfVersion v = DxfVersion.r2000,
  bool buildingFill = false,
  bool showMinorRoadNames = false,
  String name = '微调',
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
  return latin1.decode(r.file.readAsBytesSync());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==========================================================================
  // ③+④ 默认路径：无建筑填充实体、无道路中心线实体（轮廓/描边照常）
  // ==========================================================================
  test('默认导出（R12/R2000）无 JianZhuFill 实体、无 DaoLuZhong 实体；轮廓与双线描边保留',
      () async {
    final dir = Directory.systemTemp.createTempSync('tune_default');
    final bm = _bm([
      _hRoad(RoadGrade.trunk, '主干道', kLon - 0.001, kLon + 0.004),
      _hRoad(RoadGrade.primary, '人民路', kLon - 0.001, kLon + 0.004),
    ], buildings: [_building()]);

    for (final v in DxfVersion.values) {
      final text = await _exportText(dir, bm, v: v, name: '默认路径');
      final ents = _entities(text);
      // ③ 无填充实体：R2000 无 HATCH，R12 无 SOLID
      expect(ents.any((e) => e.type == 'HATCH'), isFalse,
          reason: '${v.name}: 默认不应输出 HATCH');
      expect(ents.any((e) => e.type == 'SOLID'), isFalse,
          reason: '${v.name}: 默认不应输出 SOLID');
      expect(_on(ents, 'HATCH', 'JianZhuFill'), isEmpty);
      expect(_on(ents, 'LWPOLYLINE', 'JianZhuFill'), isEmpty);
      // ④ 无中心线实体
      expect(_on(ents, 'LWPOLYLINE', 'DaoLuZhong'), isEmpty,
          reason: '${v.name}: DaoLuZhong 实体应已删除');
      expect(_on(ents, 'POLYLINE', 'DaoLuZhong'), isEmpty,
          reason: '${v.name}: DaoLuZhong 实体应已删除（R12）');
      // 建筑轮廓 / 道路双线描边 / 建筑名 / 路名保留
      expect(_polysOn(ents, 'JianZhu'), isNotEmpty,
          reason: '${v.name}: 建筑轮廓应保留');
      expect(_polysOn(ents, 'DaoLuBian'), isNotEmpty,
          reason: '${v.name}: 道路双线描边应保留');
      expect(_on(ents, 'TEXT', 'DaoLu'), isNotEmpty,
          reason: '${v.name}: 主干/次干路名应标注');
    }
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('buildingFill: true 时恢复填充：R2000=HATCH / R12=SOLID', () async {
    final dir = Directory.systemTemp.createTempSync('tune_fill');
    final bm = _bm([_hRoad(RoadGrade.trunk, '主干道', kLon, kLon + 0.003)],
        buildings: [_building()]);

    final t20 = await _exportText(dir, bm, v: DxfVersion.r2000,
        buildingFill: true, name: '填充开R2');
    expect(_on(_entities(t20), 'HATCH', 'JianZhuFill'), isNotEmpty);

    final t12 = await _exportText(dir, bm, v: DxfVersion.r12,
        buildingFill: true, name: '填充开R1');
    expect(_on(_entities(t12), 'SOLID', 'JianZhuFill'), isNotEmpty);
    expect(_entities(t12).any((e) => e.type == 'HATCH'), isFalse);

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ==========================================================================
  // ① 路名在双线之间：TEXT y 与中线重合（|y| ≤ halfW），字号 ≤ 2*halfW*0.6
  // ==========================================================================
  test('路名 TEXT 落在道路中心线上（双线之间），字号被 clamp 进双线间隙', () async {
    final dir = Directory.systemTemp.createTempSync('tune_center');
    final bm = _bm([_hRoad(RoadGrade.trunk, '验收大道', kLon - 0.001, kLon + 0.004)]);
    final text = await _exportText(dir, bm, name: '路名居中');
    final texts = _on(_entities(text), 'TEXT', 'DaoLu');
    expect(texts, isNotEmpty, reason: '应有路名 TEXT');

    // 比例 1:1000（0.002° 跨度 3 杆）→ trunk 半宽 = 0.90mm/1000×1000 = 0.9m（v3.9.5 加倍）
    const halfW = 0.90 / 1000.0 * 1000;
    for (final t in texts) {
      final y = double.parse(t.first('20')!);
      final h = double.parse(t.first('40')!);
      expect(y.abs(), lessThanOrEqualTo(halfW + 1e-6),
          reason: '路名 y=$y 超出双线之间（±$halfW）');
      expect(h, lessThanOrEqualTo(2 * halfW * 0.6 + 1e-6),
          reason: '字号 h=$h 未被 clamp 进双线间隙');
      expect(h, greaterThan(0));
    }
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('路名每约 200 米一处：1000m 直路 → 5 处，位置均匀（弧长中点式分布）', () async {
    final dir = Directory.systemTemp.createTempSync('tune_200m');
    final lonSpan = 1000.0 / kScaleX; // 1000m 直路
    final bm = _bm([_hRoad(RoadGrade.trunk, '千米大道', kLon, kLon + lonSpan)]);
    final text = await _exportText(dir, bm, name: '间隔两百');
    final texts = _on(_entities(text), 'TEXT', 'DaoLu');
    expect(texts.length, 5, reason: '1000m 应标 5 处，实测 ${texts.length}');

    final xs = texts.map((t) => double.parse(t.first('10')!)).toList()..sort();
    final ys = texts.map((t) => double.parse(t.first('20')!)).toList();
    // 均匀分布：第 i 处在弧长 1000*(2i-1)/(2*5) = 100,300,...,900
    for (var i = 0; i < xs.length; i++) {
      expect(xs[i], closeTo(100.0 + 200.0 * i, 0.01),
          reason: '第 ${i + 1} 处应在弧长 ${100 + 200 * i}m，实测 ${xs[i]}');
      expect(ys[i], closeTo(0, 1e-6), reason: '应落在中心线上');
    }
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('路名宋体：STYLE 表含 SongTi + simsun.ttc；DaoLu 层 TEXT 引用 SongTi，其他文字样式不变',
      () async {
    final dir = Directory.systemTemp.createTempSync('tune_songti');
    final bm = _bm([_hRoad(RoadGrade.trunk, '宋体大道', kLon, kLon + 0.003)],
        buildings: [_building()]);
    for (final v in DxfVersion.values) {
      final text = await _exportText(dir, bm, v: v, name: '宋体路');
      // STYLE 表：新增 SongTi（ASCII 样式名）+ simsun.ttc；既有 SimSun 保持不变
      expect(text, contains('2\nSongTi\n'), reason: '${v.name}: 缺 SongTi 样式');
      expect(text, contains('3\nsimsun.ttc\n'), reason: '${v.name}: SongTi 字体文件错');
      expect(text, contains('2\nSimSun\n'), reason: '${v.name}: 既有 SimSun 应保留');
      // DaoLu 层路名 TEXT 全部引用 SongTi（组码 7）
      final roadTexts = _on(_entities(text), 'TEXT', 'DaoLu');
      expect(roadTexts, isNotEmpty);
      for (final t in roadTexts) {
        expect(t.first('7'), 'SongTi', reason: '${v.name}: 路名应引用 SongTi');
      }
      // 其他文字（JuLi 距离标注）仍为 SimSun，不得被波及
      final juliTexts = _on(_entities(text), 'TEXT', 'JuLi');
      expect(juliTexts, isNotEmpty, reason: '${v.name}: 应存在距离标注');
      for (final t in juliTexts) {
        expect(t.first('7'), 'SimSun', reason: '${v.name}: 业务文字样式不应改变');
      }
      // 建筑名文字无 7 组码（既有样式不动，不应引用 SongTi）
      for (final t in _on(_entities(text), 'TEXT', 'JianZhu')) {
        expect(t.first('7'), isNull, reason: '${v.name}: 建筑名样式不应改变');
      }
    }
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('路名角度不倒立：斜向/反向道路的旋转角 ∈ (-90, 90]', () async {
    final dir = Directory.systemTemp.createTempSync('tune_angle');
    for (final reversed in [false, true]) {
      final bm = _bm([_diagRoad(RoadGrade.trunk, '斜向大道', reversed)]);
      final text = await _exportText(dir, bm, name: '角度核查');
      final texts = _on(_entities(text), 'TEXT', 'DaoLu');
      expect(texts, isNotEmpty, reason: 'reversed=$reversed 应有路名');
      for (final t in texts) {
        final a = double.parse(t.first('50')!);
        expect(a, greaterThan(-90.0), reason: 'reversed=$reversed 角度 $a 倒立');
        expect(a, lessThanOrEqualTo(90.0), reason: 'reversed=$reversed 角度 $a 倒立');
      }
    }
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ==========================================================================
  // ② 等级过滤 + 塞不下兜底
  // ==========================================================================
  test('等级过滤：service 默认无路名（几何保留）；showMinorRoadNames 放开；residential 默认保留',
      () async {
    final dir = Directory.systemTemp.createTempSync('tune_grade');
    final service = _bm([_hRoad(RoadGrade.service, '内部服务道', kLon, kLon + 0.003)]);

    // 默认：service 不标路名，但双线描边（几何）必须保留
    final tDef = await _exportText(dir, service, name: '服务路默认');
    expect(_on(_entities(tDef), 'TEXT', 'DaoLu'), isEmpty,
        reason: 'service 道路默认不应标注路名');
    expect(_on(_entities(tDef), 'LWPOLYLINE', 'DaoLuBian'), isNotEmpty,
        reason: '道路几何（DaoLuBian）不得因路名过滤而丢失');
    // 放开开关：service 也标
    final tAll = await _exportText(dir, service,
        showMinorRoadNames: true, name: '服务路放开');
    expect(_on(_entities(tAll), 'TEXT', 'DaoLu'), isNotEmpty,
        reason: 'showMinorRoadNames: true 时 service 应标注');

    // residential 默认保留（用户要求"尽量多保留路名"）
    final resi = _bm([_hRoad(RoadGrade.residential, '小区路', kLon, kLon + 0.003)]);
    final tResi = await _exportText(dir, resi, name: '小区路默认');
    expect(_on(_entities(tResi), 'TEXT', 'DaoLu'), isNotEmpty,
        reason: 'residential 默认应保留路名');

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('极窄路（other 级）默认无路名；放开后字号被 clamp 进窄间隙（塞不下不硬塞）', () async {
    final dir = Directory.systemTemp.createTempSync('tune_narrow');
    final bm = _bm([_hRoad(RoadGrade.other, '窄巷', kLon, kLon + 0.003)]);

    // 默认：other 不标
    final tDef = await _exportText(dir, bm, name: '窄路默认');
    expect(_on(_entities(tDef), 'TEXT', 'DaoLu'), isEmpty,
        reason: 'other 级道路默认不应标注路名');

    // 放开：标注存在，但字号必须 clamp 进双线间隙（other 半宽 0.20mm，v3.9.5 加倍）
    final tAll = await _exportText(dir, bm, showMinorRoadNames: true, name: '窄路放开');
    final texts = _on(_entities(tAll), 'TEXT', 'DaoLu');
    expect(texts, isNotEmpty);
    const halfW = 0.20 / 1000.0 * 1000; // other 半宽（米，比例 1:1000；v3.9.5 加倍）
    for (final t in texts) {
      final y = double.parse(t.first('20')!);
      final h = double.parse(t.first('40')!);
      expect(y.abs(), lessThanOrEqualTo(halfW + 1e-6),
          reason: '窄路路名 y=$y 超出双线之间');
      expect(h, lessThanOrEqualTo(2 * halfW * 0.6 + 1e-6),
          reason: '窄路字号 h=$h 未被 clamp');
    }
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('UI 接线：DXF 选项对话框含「小路也标路名」开关，默认关并传入 export', () {
    // 轻量源级断言（与 qa_indep 的源码取证同口径）：确认 UI 默认值与传参链路。
    final src = File('lib/ui/dialogs.dart').readAsStringSync();
    // 默认值：不勾（false）——与导出层 showMinorRoadNames 默认 false 一致
    expect(src.contains("opt('dxfMinorRoadNames', false)"), isTrue,
        reason: 'UI 开关 dxfMinorRoadNames 默认应为关');
    // 勾选状态传递到导出：showMinorRoadNames: minorRoadNames
    expect(src.contains('showMinorRoadNames: minorRoadNames'), isTrue,
        reason: '勾选「小路也标路名」应传入 export(showMinorRoadNames: true)');
    // 偏好持久化：勾选状态下次沿用
    expect(src.contains("prefs.setBool('dxfMinorRoadNames', minorRoadNames)"),
        isTrue, reason: '勾选状态应持久化（下次默认沿用）');
  });
}
