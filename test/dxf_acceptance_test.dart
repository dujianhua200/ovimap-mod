// 验收清单 A1–A10 中**可自动化**项的判定（几何/图层/编码/失败三态）。
// 使用注入的合成 BasemapData，**不依赖网络**。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '_dxf_fixture.dart';

/// 解析某图层上的全部 LWPOLYLINE 点集。
List<List<List<double>>> _lwPolylines(String text, String layer) {
  final lines = text.split('\n');
  final out = <List<List<double>>>[];
  for (var i = 0; i + 1 < lines.length; i += 2) {
    if (lines[i].trim() != '0' || lines[i + 1].trim() != 'LWPOLYLINE') continue;
    var isTarget = false;
    final pts = <List<double>>[];
    double? x;
    for (var j = i + 2; j + 1 < lines.length; j += 2) {
      final c = lines[j].trim();
      if (c == '0') break;
      final v = lines[j + 1].trim();
      if (c == '8') {
        isTarget = v == layer;
      } else if (c == '10') {
        x = double.tryParse(v);
      } else if (c == '20' && x != null) {
        pts.add([x, double.tryParse(v) ?? 0]);
        x = null;
      }
    }
    if (isTarget && pts.isNotEmpty) out.add(pts);
  }
  return out;
}

/// 复刻 DxfExporter._pickScale（仅按线路范围较长边，A3 宽 0.40m）。
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

/// 实体在文本中的出现顺序（按 `0\n<type>\n` 起始索引）。
List<List<String>> _entities(String text) {
  final lines = text.split('\n');
  final out = <List<String>>[];
  var cur = <String>[];
  var started = false;
  for (var i = 0; i + 1 < lines.length; i += 2) {
    final c = lines[i].trim();
    final v = lines[i + 1].trim();
    if (c == '0') {
      if (started) out.add(cur);
      cur = [v];
      started = true;
    } else if (started) {
      cur.add(c);
      cur.add(v);
    }
  }
  if (started) out.add(cur);
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('A1/A3/A4/A5/A6/A10：建筑成片可辨、道路分级不粘连、地名可读、中文不乱码',
      () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_accept');
    PathProviderPlatform.instance = FakePathProvider(dir.path);

    final r = await DxfExporter.export(
      name: '验收样例',
      labels: buildFixtureLabels(),
      includeSurroundings: true,
      basemap: buildSyntheticBasemap(),
      version: DxfVersion.r2000,
      buildingFill: true, // 显式开启：本用例继续断言 HATCH 填充路径正确
    );
    final bytes = r.file.readAsBytesSync();
    final text = latin1.decode(bytes);
    final decoded = gbk_bytes.decode(bytes);

    // A1 建筑轮廓成片可辨：轮廓 + 填充（HATCH）均存在
    expect(text, contains('JianZhu'));
    expect(text, contains('JianZhuFill'));
    expect(text, contains('HATCH'));

    // A3 道路 ≥3 可见等级：图层真彩色（420）≥3（中心线已删除，分级由双线描边宽度表达）
    final colors = <int>{};
    for (final c in RegExp(r'420\n(\d+)\n').allMatches(text)) {
      colors.add(int.parse(c.group(1)!));
    }
    expect(colors.length, greaterThanOrEqualTo(3));

    // A4 道路"瘦"下来：双线描边成对（每条路 2 条），且不与真实路宽 1:1
    final casing = _lwPolylines(text, 'DaoLuBian');
    expect(casing.length, greaterThanOrEqualTo(2));

    // A5 地名可读：DiMing 层有文字，名为小区/村/市
    expect(text, contains('DiMing'));
    expect(decoded, contains('李庄村'));
    expect(decoded, contains('和谐花园'));

    // A6 绘制顺序：DXF 中「后写者在上层」——底图必须先写、业务层后写，
    // 业务层（杆路/配线）才能置顶、不被底图（尤其建筑填充 HATCH/SOLID）盖住。
    const basemapLayers = {
      'DaoLuBian',
      'DaoLuZhong',
      'DaoLu',
      'JianZhu',
      'JianZhuFill',
      'DiMing',
    };
    const bizLayers = {'GanLu', 'PeiXianTu'};
    final ents = _entities(text);
    int? firstBiz, lastBasemap;
    for (var i = 0; i < ents.length; i++) {
      final kv = ents[i];
      String? layer;
      for (var j = 1; j + 1 < kv.length; j += 2) {
        if (kv[j] == '8') layer = kv[j + 1];
      }
      if (layer == null) continue;
      if (basemapLayers.contains(layer)) lastBasemap = i;
      if (bizLayers.contains(layer)) firstBiz ??= i;
    }
    expect(firstBiz, isNotNull, reason: '应有业务层实体（GanLu/PeiXianTu）');
    expect(lastBasemap, isNotNull, reason: '应有底图实体（道路/建筑/地名）');
    expect(lastBasemap! < firstBiz!, isTrue,
        reason: 'A6 顺序违规：底图实体最末出现在 idx=$lastBasemap，业务实体首现于 idx=$firstBiz；'
            'DXF 后写者在上层，底图后写会盖住杆路/配线（业务须置顶）');

    // A10 中文不乱码（GBK/ANSI_936）
    expect(decoded, contains('ANSI_936'));
    expect(decoded.contains('\uFFFD'), isFalse);
    expect(bytes, containsAllInOrder([0xC0, 0xEE]));

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('A2/A4 关键：底图线宽按「纸面毫米 ÷ 1000 × 出图比例」换算，不再 1:1 用真实路宽',
      () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_accept_w');
    PathProviderPlatform.instance = FakePathProvider(dir.path);

    const baseLat = 32.1264;
    const baseLon = 114.0913;
    final labels = [
      MapLabel(typeId: 'pipe', seq: 1, lat: baseLat, lon: baseLon, lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe', seq: 2, lat: baseLat, lon: baseLon + 0.001, lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe', seq: 3, lat: baseLat, lon: baseLon + 0.002, lineGroupId: 'g'),
    ];
    // 仅一条水平 trunk，cart y=0 → 双线描边应在 ±expectedHalf（米）处
    final trivialRoad = RoadPoly(const [
      [baseLat, baseLon - 0.002],
      [baseLat, baseLon],
      [baseLat, baseLon + 0.003],
    ], RoadGrade.trunk, '主干道');
    final bm = BasemapData(
      roads: [trivialRoad],
      buildings: const [],
      places: const [],
      report: const BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, count: 1),
        buildings: DatasetReport(FetchState.ok, count: 0),
        places: DatasetReport(FetchState.ok, count: 0),
      ),
    );

    final r = await DxfExporter.export(
      name: '线宽换算',
      labels: labels,
      includeSurroundings: true,
      basemap: bm,
      version: DxfVersion.r2000,
    );
    final text = latin1.decode(r.file.readAsBytesSync());

    // 复算线路比例尺
    final scaleX = 111320.0 * math.cos(baseLat * math.pi / 180);
    final minX = 0.0;
    final maxX = (baseLon + 0.002 - baseLon) * scaleX;
    final scale = _pickScale(minX, 0, maxX, 0);

    // trunk 半宽 0.90mm（v3.9.5 加倍）→ 图纸米 = 0.90/1000*scale
    final expectHalf = 0.90 / 1000.0 * scale;

    final casing = _lwPolylines(text, 'DaoLuBian');
    expect(casing, isNotEmpty, reason: '应生成双线描边');
    // 所有描边点 |y| 应 ≈ expectHalf（成对 ±）
    var maxAbsY = 0.0;
    for (final line in casing) {
      for (final p in line) {
        if (p[1].abs() > maxAbsY) maxAbsY = p[1].abs();
      }
    }
    expect(maxAbsY, closeTo(expectHalf, 0.02),
        reason: '描边偏移应为 纸面毫米×比例（$expectHalf m），实测 $maxAbsY m');
    // 关键反向断言：绝不是旧逻辑的"真实路宽 12m"（半宽 6m）
    expect(maxAbsY, lessThan(2.0),
        reason: '不得沿用真实路宽 1:1（否则半宽达数米，路太粗复发）');

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('A2/O4 南北向线路：比例尺按较长边估算，线宽换算正确（不被 X≈0 拖到最小档）',
      () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_accept_ns');
    PathProviderPlatform.instance = FakePathProvider(dir.path);

    const baseLat = 32.1264;
    const baseLon = 114.0913;
    // 南北走向：经度不变（包围盒跨度 X≈0），纬度变化 0.002°
    final labels = [
      MapLabel(typeId: 'pipe', seq: 1, lat: baseLat, lon: baseLon, lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe',
          seq: 2,
          lat: baseLat + 0.001,
          lon: baseLon,
          lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe',
          seq: 3,
          lat: baseLat + 0.002,
          lon: baseLon,
          lineGroupId: 'g'),
    ];
    // 一条南北向 trunk（cart x≈0、y 变化）→ 双线描边应在 x=±expectedHalf 处
    final nsRoad = RoadPoly(const [
      [baseLat - 0.002, baseLon],
      [baseLat, baseLon],
      [baseLat + 0.003, baseLon],
    ], RoadGrade.trunk, '南北主干');
    final bm = BasemapData(
      roads: [nsRoad],
      buildings: const [],
      places: const [],
      report: const BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, count: 1),
        buildings: DatasetReport(FetchState.ok, count: 0),
        places: DatasetReport(FetchState.ok, count: 0),
      ),
    );

    final r = await DxfExporter.export(
      name: '南北线宽',
      labels: labels,
      includeSurroundings: true,
      basemap: bm,
      version: DxfVersion.r2000,
    );
    final text = latin1.decode(r.file.readAsBytesSync());

    // 复算：经度不变 → 跨度X=0；纬度跨度 0.002° → 跨度Y（较长边）
    const scaleY = 110540.0;
    final spanY = (baseLat + 0.002 - baseLat) * scaleY;
    final scale = _pickScale(0, 0, 0, spanY);
    // O4：必须按较长边（Y）估到 1:1000，而非按 X≈0 拖到 1:100（线宽会缩到 1/10）
    expect(scale, 1000, reason: '南北向线路应按 Y 跨度估为 1:1000');

    final expectHalf = 0.90 / 1000.0 * scale;
    final casing = _lwPolylines(text, 'DaoLuBian');
    expect(casing, isNotEmpty, reason: '应生成南北向双线描边');
    // 南北向：垂直偏移发生在 X 方向
    var maxAbsX = 0.0;
    for (final line in casing) {
      for (final p in line) {
        if (p[0].abs() > maxAbsX) maxAbsX = p[0].abs();
      }
    }
    expect(maxAbsX, closeTo(expectHalf, 0.02),
        reason: '南北向描边偏移应为 纸面毫米×比例（$expectHalf m），实测 $maxAbsX m');
    expect(maxAbsX, lessThan(2.0), reason: '不得沿用真实路宽 1:1');

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('A9 失败可见可解释：底图失败三态进入 DxfExportResult.warnings', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_accept_fail');
    PathProviderPlatform.instance = FakePathProvider(dir.path);

    const failedBm = BasemapData(
      roads: [],
      buildings: [],
      places: [],
      report: BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, count: 0),
        buildings: DatasetReport(FetchState.failed, error: '网络不可达，无缓存'),
        places: DatasetReport(FetchState.failed, error: '网络不可达，无缓存'),
      ),
    );

    final r = await DxfExporter.export(
      name: '失败可见',
      labels: buildFixtureLabels(),
      includeSurroundings: true,
      basemap: failedBm,
      version: DxfVersion.r2000,
    );
    expect(r.report, isNotNull);
    expect(r.report!.anyFailed, isTrue);
    expect(r.warnings.any((s) => s.contains('建筑轮廓')), isTrue);
    expect(r.warnings.any((s) => s.contains('地名')), isTrue);
    expect(r.warnings.any((s) => s.contains('刷新底图')), isTrue);
    // 失败不抛错，文件照常生成
    expect(r.file.existsSync(), isTrue);

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('A7/R12 红线：R12 输出严禁 370/420/LWPOLYLINE/HATCH', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_accept_r12');
    PathProviderPlatform.instance = FakePathProvider(dir.path);

    final r = await DxfExporter.export(
      name: 'R12红线',
      labels: buildFixtureLabels(),
      includeSurroundings: true,
      basemap: buildSyntheticBasemap(),
      version: DxfVersion.r12,
    );
    final text = latin1.decode(r.file.readAsBytesSync());
    expect(text, isNot(contains('\n370\n')));
    expect(text, isNot(contains('\n420\n')));
    expect(text, isNot(contains('LWPOLYLINE')));
    expect(text, isNot(contains('HATCH')));

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
