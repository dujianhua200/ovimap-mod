// 第二十二批：本地底图「只导出范围内」修复的回归测试（零网络）。
//
// 背景（用户实测）：导入 `信阳矢量底图_整市.geojson`（18MB / 44599 要素）后，
// 导出 DXF 每次约 50MB——线路一旦落在底图数据空白处，裁剪结果为空即「回退全量」，
// 把整个信阳的矢量都写进了图里。
//
// 本文件锁定三条修复：
//   R1 去掉「裁剪为空则回退全量」（空就用空底图 + 中文 warning）；
//   R2 道路按 bbox 裁剪几何（只保留框内段，长路可拆成多段）；
//   R3 进入渲染前的要素数防御性上限（超限按「距线路最近优先」截断）。
//
// 与既有 fixture / 在线抓取路径完全无关；不触网。
import 'dart:io';

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

/// 极简实体解析：按组码 0 切分实体，收集其后的 (code,value) 对。
class _E {
  final String type;
  final List<List<String>> kv = [];
  _E(this.type);
  String? first(String c) {
    for (final p in kv) {
      if (p[0] == c) return p[1].trim();
    }
    return null;
  }
}

List<_E> _parse(String t) {
  final lines = t.replaceAll('\r\n', '\n').split('\n');
  final out = <_E>[];
  _E? cur;
  var i = 0;
  while (i + 1 < lines.length) {
    final code = lines[i].trim();
    final val = lines[i + 1];
    if (code == '0') {
      cur = _E(val.trim());
      out.add(cur);
    } else if (cur != null) {
      cur.kv.add([code, val]);
    }
    i += 2;
  }
  return out;
}

/// 统计某图层上的**绘图实体**数（排除 POLYLINE 的 VERTEX/SEQEND 子实体，
/// 否则 R12 下顶点会被重复计入，导致计数虚高）。
int _cnt(List<_E> ents, String layer) => ents
    .where((e) =>
        e.type != 'VERTEX' && e.type != 'SEQEND' && e.first('8') == layer)
    .length;

int _bmEnts(List<_E> ents) =>
    _cnt(ents, 'DaoLuBian') + _cnt(ents, 'JianZhu') + _cnt(ents, 'DiMing');

// ---- 合成底图构件 ----

List<List<double>> _line(double lat0, double lon0, double lat1, double lon1, int n) {
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
        buildings:
            DatasetReport(FetchState.ok, source: 'local', count: buildings.length),
        places:
            DatasetReport(FetchState.ok, source: 'local', count: places.length),
      ),
    );

MapLabel _pole(double lat, double lon, [int seq = 1]) =>
    MapLabel(typeId: 'pipe', seq: seq, lat: lat, lon: lon, lineGroupId: 'g');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ============ R1：去掉「回退全量」 ============
  group('R1 回退全量已消除', () {
    test('框内无底图要素 → 空底图（不回退全量）+ 中文 warning，体积远小于全量', () async {
      final dir = Directory.systemTemp.createTempSync('ovimap_cropfix');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);

      // 底图要素全部集中在约 100km 外的 (33.0,115.0)（模拟「线路落在数据空白处」）。
      const farLat = 33.0, farLon = 115.0;
      final roads = <RoadPoly>[
        for (var i = 0; i < 200; i++)
          _road(
              _line(farLat + i * 0.0002, farLon, farLat + i * 0.0002,
                  farLon + 0.002, 4),
              RoadGrade.trunk,
              '远路$i'),
      ];
      final buildings = <BuildingPoly>[
        for (var i = 0; i < 100; i++)
          _square(farLat + i * 0.0003, farLon + i * 0.0003, 0.001),
      ];
      final places = <PlaceFeature>[
        for (var i = 0; i < 100; i++)
          _place(farLat + i * 0.0004, farLon + i * 0.0004, '远村$i'),
      ];
      final full = _mk(roads, buildings, places);
      final fullCount = roads.length + buildings.length + places.length;

      // 线路在信阳市区附近（与底图要素相距 ~100km）。
      final labels = <MapLabel>[_pole(32.1300, 114.0800, 1), _pole(32.1304, 114.0806, 2)];

      // 修复后：rangeM=50 → 框内无任何底图 → 空底图（绝不回退全量）。
      final after = await DxfExporter.export(
        name: 'crop_after',
        labels: labels,
        includeSurroundings: true,
        localBasemap: full,
        rangeM: 50,
      );
      final eAfter = _parse(gbk_bytes.decode(after.file.readAsBytesSync()));
      expect(_cnt(eAfter, 'DaoLuBian'), 0, reason: '框内无道路，不得回退全量写底图道路');
      expect(_cnt(eAfter, 'JianZhu'), 0, reason: '框内无建筑，不得回退全量');
      expect(_cnt(eAfter, 'JianZhuFill'), 0);
      expect(_cnt(eAfter, 'DiMing'), 0, reason: '框内无地名，不得回退全量');
      expect(
          after.warnings.any((w) => w.contains('范围内无底图数据')), isTrue,
          reason: '必须给出「范围内无底图数据」中文 warning：${after.warnings}');

      // 「修复前」等价物：直接注入完整底图（basemap 参数跳过裁剪）→ 全量进入 DXF。
      final before = await DxfExporter.export(
        name: 'crop_before',
        labels: labels,
        includeSurroundings: true,
        basemap: full, // 跳过裁剪 = 旧「回退全量」效果
        rangeM: 50,
      );
      final eBefore = _parse(gbk_bytes.decode(before.file.readAsBytesSync()));
      final afterBmEnts = _bmEnts(eAfter);
      final beforeBmEnts = _bmEnts(eBefore);
      // ignore: avoid_print
      print('R1 对比：修复前(full=$fullCount 要素) bmEnts=$beforeBmEnts '
          'size=${before.file.lengthSync()} vs 修复后(size=${after.file.lengthSync()})');

      expect(beforeBmEnts, greaterThan(100), reason: '对照全量应有大量底图实体');
      expect(afterBmEnts, 0);
      expect(after.file.lengthSync(), lessThan(before.file.lengthSync()),
          reason: '修复后 DXF 必须远小于「回退全量」');

      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ============ R2：cropTo 几何裁剪 ============
  group('R2 cropTo 几何裁剪（纯函数，零网络）', () {
    test('② 农村空白场景：框外要素一条都不进，框内近要素保留', () {
      final labels = <MapLabel>[_pole(32.1300, 114.0800)];
      final bbox = BasemapFetcher.boundsOf(labels, 300);

      final nearRoad =
          _road(_line(32.1300, 114.0800, 32.1300, 114.0805, 3), RoadGrade.trunk, '近路');
      final nearB = _square(32.1302, 114.0801, 0.0002);
      final nearP = _place(32.1301, 114.0802, '近村');

      final roads = <RoadPoly>[
        nearRoad,
        for (var i = 0; i < 300; i++)
          _road(_line(33.0 + i * 0.001, 115.0, 33.0 + i * 0.001, 115.002, 3),
              RoadGrade.trunk, '远路$i'),
      ];
      final buildings = <BuildingPoly>[
        nearB,
        for (var i = 0; i < 300; i++) _square(33.0 + i * 0.001, 115.0, 0.0005),
      ];
      final places = <PlaceFeature>[
        nearP,
        for (var i = 0; i < 300; i++) _place(33.0 + i * 0.001, 115.0, '远村$i'),
      ];

      final c = GeoJsonImporter.cropTo(_mk(roads, buildings, places), bbox);

      expect(c.roads.length, 1, reason: '只应保留框内近路');
      expect(c.buildings.length, 1, reason: '只应保留框内近建筑');
      expect(c.places.length, 1, reason: '只应保留框内地名');
      expect(c.roads.single.name, '近路');
      expect(c.places.single.name, '近村');

      // 输出坐标必须全部落在框内（框外要素一条都不进）。
      for (final r in c.roads) {
        for (final p in r.pts) {
          expect(p[0] >= bbox[0] - 1e-9 && p[0] <= bbox[2] + 1e-9, isTrue,
              reason: '道路含框外纬度 $p');
          expect(p[1] >= bbox[1] - 1e-9 && p[1] <= bbox[3] + 1e-9, isTrue,
              reason: '道路含框外经度 $p');
        }
      }
    });

    test('③ 长道路按框裁剪：只保留框内段、顶点显著减少、无框外坐标', () {
      final labels = <MapLabel>[_pole(32.1300, 114.0800)];
      final bbox = BasemapFetcher.boundsOf(labels, 50); // 约 100m 见方

      // 一条从南到北 41 点的长路（lat 32.1280→32.1320），远超 50m 框。
      final long = _line(32.1280, 114.0800, 32.1320, 114.0800, 40);
      final bm = _mk([_road(long, RoadGrade.trunk, '长路')], [], []);

      final c = GeoJsonImporter.cropTo(bm, bbox);
      expect(c.roads.length, 1, reason: '框内为一段连续几何');
      final out = c.roads.single.pts;
      expect(out.length, lessThan(long.length), reason: '顶点数应显著减少');
      expect(out.length, lessThan(20), reason: '只保留框内段（原 41 点）');
      expect(c.roads.single.name, '长路');
      for (final p in out) {
        expect(p[0] >= bbox[0] - 1e-9 && p[0] <= bbox[2] + 1e-9, isTrue,
            reason: '不得含框外纬度 $p');
        expect(p[1] >= bbox[1] - 1e-9 && p[1] <= bbox[3] + 1e-9, isTrue,
            reason: '不得含框外经度 $p');
        // 框（约 100m 见方）之外数公里的坐标绝不出现。
        expect(p[0] > 32.1290 && p[0] < 32.1310, isTrue);
      }
    });

    test('③b 穿出再穿入的长路 → 裁成多段', () {
      const bbox = <double>[32.1295, 114.0795, 32.1305, 114.0805];
      final pts = <List<double>>[
        [32.1300, 114.0790], // 框外（西）
        [32.1300, 114.0798], // 框内
        [32.1300, 114.0800], // 框内
        [32.1320, 114.0800], // 框外（北）
        [32.1300, 114.0802], // 框内（重新穿入）
        [32.1300, 114.0810], // 框外（东）
      ];
      final bm = _mk([_road(pts, RoadGrade.primary, '折返路')], [], []);
      final c = GeoJsonImporter.cropTo(bm, bbox);
      expect(c.roads.length, 2, reason: '穿出再穿入应裁成两段独立几何');
      for (final r in c.roads) {
        expect(r.name, '折返路');
        for (final p in r.pts) {
          expect(p[0] >= bbox[0] - 1e-9 && p[0] <= bbox[2] + 1e-9, isTrue);
          expect(p[1] >= bbox[1] - 1e-9 && p[1] <= bbox[3] + 1e-9, isTrue);
        }
      }
    });

    test('④ 框内道路/建筑/地名必须保留（防过度裁剪）', () {
      final labels = <MapLabel>[_pole(32.1300, 114.0800)];
      final bbox = BasemapFetcher.boundsOf(labels, 300);

      final keepRoad =
          _road(_line(32.1300, 114.0800, 32.1300, 114.0808, 4), RoadGrade.primary, '保留路');
      final keepB = _square(32.1301, 114.0801, 0.0002);
      final keepP = _place(32.1300, 114.0803, '保留村');
      final bm = _mk([
        keepRoad,
        _road(_line(33.0, 115.0, 33.0, 115.002, 4), RoadGrade.trunk, '远路'),
      ], [
        keepB,
        _square(33.0, 115.0, 0.001),
      ], [
        keepP,
        _place(33.0, 115.0, '远村'),
      ]);

      final c = GeoJsonImporter.cropTo(bm, bbox);
      expect(c.roads.length, 1);
      expect(c.roads.single.name, '保留路');
      expect(c.buildings.length, 1);
      expect(c.places.length, 1);
      expect(c.places.single.name, '保留村');
    });

    test('④b 端到端：框内数据在 DXF 中正常出图', () async {
      final dir = Directory.systemTemp.createTempSync('ovimap_keep');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);

      final bm = _mk([
        _road(_line(32.1300, 114.0800, 32.1300, 114.0808, 4), RoadGrade.primary, '保留路'),
      ], [
        _square(32.1301, 114.0801, 0.0002),
      ], [
        _place(32.1300, 114.0803, '保留村'),
      ]);

      final r = await DxfExporter.export(
        name: 'keep',
        labels: <MapLabel>[_pole(32.1300, 114.0800), _pole(32.1302, 114.0806, 2)],
        includeSurroundings: true,
        localBasemap: bm,
        rangeM: 300,
      );
      final e = _parse(gbk_bytes.decode(r.file.readAsBytesSync()));
      expect(_cnt(e, 'DaoLuBian'), greaterThan(0), reason: '框内道路应出图');
      expect(_cnt(e, 'JianZhu'), greaterThan(0), reason: '框内建筑应出图');
      expect(_cnt(e, 'DiMing'), greaterThan(0), reason: '框内地名应出图');

      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ============ R3：要素数防御性上限 ============
  group('R3 要素数防御性上限', () {
    test('⑤a capFeatures：超限按「距线路最近优先」截断 + 中文 warning', () {
      final route = <List<double>>[
        [32.1300, 114.0800]
      ];
      // 400 个近要素 + 100 个远要素（均在框外/框内不影响本单测，直接调 capFeatures）。
      final roads = <RoadPoly>[
        for (var i = 0; i < 400; i++)
          _road([
            [32.1300 + i * 1e-7, 114.0800]
          ], RoadGrade.other, 'N$i'),
        for (var i = 0; i < 100; i++)
          _road([
            [33.0 + i * 0.001, 115.0]
          ], RoadGrade.other, 'F$i'),
      ];
      final bm = _mk(roads, [], []);
      final warnings = <String>[];
      final capped = GeoJsonImporter.capFeatures(bm,
          routePts: route, cap: 200, warnings: warnings);

      expect(capped.roads.length, 200, reason: '应截断到上限 200');
      expect(warnings.length, 1);
      expect(warnings.single, contains('上限'));
      expect(warnings.single, contains('200'));
      // 保留的都是距线路最近的（名字以 N 开头，远的 F 全被丢弃）。
      expect(capped.roads.every((r) => r.name.startsWith('N')), isTrue,
          reason: '应先丢弃远要素');
    });

    test('⑤b DXF 级：超上限输入被截断，DXF 仍可产出', () async {
      final dir = Directory.systemTemp.createTempSync('ovimap_cap');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);

      // 生产默认上限必须是 20000（改动即需评审）。
      expect(GeoJsonImporter.defaultFeatureCap, 20000,
          reason: '生产默认上限应为 20000 条');

      final labels = <MapLabel>[_pole(32.1300, 114.0800)];
      // 200 个框内地名；本用例注入小上限 50 以快速验证 DXF 侧接线（生产默认 20000）。
      final places = <PlaceFeature>[
        for (var i = 0; i < 200; i++)
          _place(32.1300 + (i % 20) * 1e-6, 114.0800 + (i ~/ 20) * 1e-6, 'P$i'),
      ];
      final bm = _mk([], [], places);

      final r = await DxfExporter.export(
        name: 'cap',
        labels: labels,
        includeSurroundings: true,
        localBasemap: bm,
        localBasemapFeatureCap: 50,
      );
      final e = _parse(gbk_bytes.decode(r.file.readAsBytesSync()));
      expect(_cnt(e, 'DiMing'), 50, reason: '应被截断到注入上限 50');
      expect(r.warnings.any((w) => w.contains('上限')), isTrue,
          reason: '应给出上限截断 warning：${r.warnings}');

      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ============ ⑥：真实 18MB 整市文件端到端（文件缺失则跳过） ============
  group('⑥ 真实整市文件端到端', () {
    test('信阳市区 50m → 输出实体数很小、文件远小于 50MB', () async {
      final real = File(
          '${Platform.environment['HOME']}/Desktop/信阳矢量底图_整市.geojson');
      if (!real.existsSync()) {
        // ignore: avoid_print
        print('SKIP ⑥：真实文件不存在（$real）');
        return;
      }
      final dir = Directory.systemTemp.createTempSync('ovimap_real');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);

      final bm = GeoJsonImporter.parse(real.readAsStringSync());
      final full = bm.roads.length + bm.buildings.length + bm.places.length;

      // 信阳市区（用户实测该点 50m 内有 道路 2 / 建筑 22）。
      final labels = <MapLabel>[
        _pole(32.1301, 114.0814, 1),
        _pole(32.1305, 114.0817, 2),
      ];
      final r = await DxfExporter.export(
        name: 'real_city',
        labels: labels,
        includeSurroundings: true,
        localBasemap: bm,
        rangeM: 50,
      );
      final e = _parse(gbk_bytes.decode(r.file.readAsBytesSync()));
      final size = r.file.lengthSync();
      // ignore: avoid_print
      print('⑥ 真实文件：fullFeatures=$full （道路 ${bm.roads.length}/'
          '建筑 ${bm.buildings.length}/地名 ${bm.places.length}）；'
          '50m→ bmEnts=${_bmEnts(e)} size=$size bytes');

      expect(full, greaterThan(40000), reason: '真实整市文件要素规模应 > 4 万');
      expect(_bmEnts(e), lessThan(1000),
          reason: '50m 范围只应带出极少量要素（绝不含框外全量）');
      expect(size, lessThan(5 * 1024 * 1024),
          reason: '绝不再是 ~50MB 全量导出');

      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
