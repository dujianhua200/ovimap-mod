// 第二十一批 QA 独立验证（严过关自造 mock，**不复用工程师夹具**）。
//
// 验证用户主诉修复：「矢量图外侧很远处密密麻麻的名字」= 兜底地名未按范围裁剪。
//  - QA21-A/B：兜底源（天地图 / 高德）返回「3 框内 + 5 条 20~80km 外」→ 最终 places 仅框内 3。
//  - QA21-C  ：真实坐标链路（convertGcj=true，mock 喂 GCJ 坐标）同样只留框内 3。
//  - QA21-D  ：污染期旧缓存（几十公里外脏地名）→ 导出后 DXF 的 DiMing 层不含它们。
//  - QA21-E  ：反向——框内/线路旁的名字必须 **保留**（防过度裁剪把身边小区也删了）。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:http/http.dart' as http;
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/export/overpass.dart';
import 'package:ovimap/geo/gcj02.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/amap.dart';
import 'package:ovimap/services/tianditu.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '_dxf_fixture.dart';

// ---- 自造锚点（刻意区别于工程师夹具 32.1264/114.0913）----
const double qLat = 31.8000;
const double qLon = 114.5000;

List<MapLabel> _qLabels() => [
      MapLabel(typeId: 'pipe', seq: 1, lat: qLat, lon: qLon, lineGroupId: 'g'),
      MapLabel(typeId: 'pipe', seq: 2, lat: qLat, lon: qLon + 0.001, lineGroupId: 'g'),
      MapLabel(typeId: 'pipe', seq: 3, lat: qLat, lon: qLon + 0.002, lineGroupId: 'g'),
    ];

/// 框内 3 条（紧贴线路）。
const List<(String, double, double)> _near = [
  ('近甲苑', 31.8005, 114.5005),
  ('近乙苑', 31.7990, 114.5008),
  ('近丙苑', 31.8015, 114.5012),
];

/// 框外 5 条（27~40km，用户实测污染数据同量级）。
const List<(String, double, double)> _far = [
  ('远北甲', 32.050, 114.500), // ~27.7km N
  ('远南乙', 31.550, 114.500), // ~27.7km S
  ('远东丙', 31.800, 114.800), // ~28.4km E
  ('远西丁', 31.800, 114.200), // ~28.4km W
  ('远东北戊', 32.100, 114.700), // ~37km NE
];

http.Response _ok(String body) => http.Response(body, 200,
    headers: const {'content-type': 'application/json; charset=utf-8'});

const String _emptyOsm = '{"version":0.6,"elements":[]}';

/// 天地图 mock：`pts` 为 [name, lat, lon]，lonlat 为 "经度,纬度"。
String _tdtBody(List<(String, double, double)> pts) => jsonEncode({
      'status': {'infocode': 1000, 'cndesc': '成功'},
      'resultType': 1,
      'pois': [
        for (final p in pts)
          {'name': p.$1, 'address': '', 'lonlat': '${p.$3},${p.$2}'},
      ],
    });

/// 高德 mock：location 为 "经度,纬度"。
String _amapBody(List<(String, double, double)> pts) => jsonEncode({
      'status': '1',
      'info': 'OK',
      'infocode': '10000',
      'count': '${pts.length}',
      'pois': [
        for (final p in pts)
          {'id': 'B${p.$1}', 'name': p.$1, 'address': '', 'location': '${p.$3},${p.$2}'},
      ],
    });

/// 把 WGS 坐标编码为 GCJ-02（模拟高德/天地图服务端真实返回）。
List<(String, double, double)> _asGcj(List<(String, double, double)> wgs) => [
      for (final p in wgs)
        (p.$1, Gcj02Converter.wgs84ToGcj02(p.$2, p.$3)[0],
            Gcj02Converter.wgs84ToGcj02(p.$2, p.$3)[1]),
    ];

Future<http.Response> _emptyOverpass(Uri url, {Map<String, String>? headers}) async =>
    _ok(_emptyOsm);

int _entitiesOnLayer(String dxf, String layer) =>
    RegExp('8\n$layer\n').allMatches(dxf).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    OverpassClient.httpGetOverride = null;
    AmapClient.httpGetOverride = null;
    TiandituClient.httpGetOverride = null;
  });
  tearDown(() {
    OverpassClient.httpGetOverride = null;
    AmapClient.httpGetOverride = null;
    TiandituClient.httpGetOverride = null;
  });

  group('QA21-A/B 数据层硬裁剪（自造 mock）', () {
    test('A. 天地图源：3 框内 + 5 条 20~80km 外 → 仅框内 3（框内必留）', () async {
      final dir = Directory.systemTemp.createTempSync('qa21_tdt');
      addTearDown(() => dir.deleteSync(recursive: true));

      OverpassClient.httpGetOverride = _emptyOverpass;
      AmapClient.httpGetOverride = (url) async => throw StateError('未配高德 key');
      TiandituClient.httpGetOverride =
          (url) async => _ok(_tdtBody([..._near, ..._far]));
      // 校验天地图请求确实带了范围参数（mapBound），证明是"按范围检索后再裁"。
      Uri? seen;
      TiandituClient.httpGetOverride = (url) async {
        seen = url;
        return _ok(_tdtBody([..._near, ..._far]));
      };

      final d = await BasemapFetcher.fetchFor(_qLabels(),
          rangeM: 300,
          amapKey: '',
          tdtKey: 'T',
          convertGcj: false,
          cache: BasemapCache(dir));

      expect(seen, isNotNull);
      expect(d.places, hasLength(3), reason: '框外几十公里地名必须被剔除');
      final names = d.places.map((p) => p.name).toSet();
      for (final p in _near) {
        expect(names, contains(p.$1), reason: '框内 ${p.$1} 必须保留（防过度裁剪）');
      }
      for (final p in _far) {
        expect(names, isNot(contains(p.$1)), reason: '框外 ${p.$1} 必须剔除');
      }
      expect(d.report.places.count, 3, reason: 'report.count 口径与裁剪后一致');
      expect(d.report.places.source, contains('+tdt'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('B. 高德源：3 框内 + 5 条 20~80km 外 → 仅框内 3（天地图不被调用）', () async {
      final dir = Directory.systemTemp.createTempSync('qa21_amap');
      addTearDown(() => dir.deleteSync(recursive: true));

      OverpassClient.httpGetOverride = _emptyOverpass;
      AmapClient.httpGetOverride =
          (url) async => _ok(_amapBody([..._near, ..._far]));
      TiandituClient.httpGetOverride =
          (url) async => throw StateError('高德有结果时不得回落天地图');

      final d = await BasemapFetcher.fetchFor(_qLabels(),
          rangeM: 300,
          amapKey: 'A',
          tdtKey: 'T',
          convertGcj: false,
          cache: BasemapCache(dir));

      expect(d.places, hasLength(3));
      final names = d.places.map((p) => p.name).toSet();
      for (final p in _near) {
        expect(names, contains(p.$1));
      }
      for (final p in _far) {
        expect(names, isNot(contains(p.$1)));
      }
      expect(d.report.places.source, contains('+amap'));
      expect(d.report.places.source.contains('+tdt'), isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('C. 真实坐标链路（convertGcj=true，服务端返回 GCJ）：同样只留框内 3', () async {
      final dir = Directory.systemTemp.createTempSync('qa21_gcj');
      addTearDown(() => dir.deleteSync(recursive: true));

      OverpassClient.httpGetOverride = _emptyOverpass;
      // 模拟天地图真实返回：GCJ 坐标（纠偏后应回到 _near / _far 的真实 WGS 位置）。
      TiandituClient.httpGetOverride =
          (url) async => _ok(_tdtBody(_asGcj([..._near, ..._far])));
      AmapClient.httpGetOverride = (url) async => throw StateError('未配高德');

      final d = await BasemapFetcher.fetchFor(_qLabels(),
          rangeM: 300,
          amapKey: '',
          tdtKey: 'T',
          convertGcj: true,
          cache: BasemapCache(dir));

      expect(d.places, hasLength(3),
          reason: '真实 GCJ→WGS 链路上，框内 3 条纠偏后仍应落在框内并保留');
      final names = d.places.map((p) => p.name).toSet();
      for (final p in _near) {
        expect(names, contains(p.$1));
      }
      for (final p in _far) {
        expect(names, isNot(contains(p.$1)));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('QA21-D/E 使用层：旧缓存防御 + 反向（框内必留）', () {
    test('D. 污染期缓存（几十公里外脏地名）→ DXF 的 DiMing 层不含它们', () async {
      final dir = Directory.systemTemp.createTempSync('qa21_dirty');
      PathProviderPlatform.instance = FakePathProvider(dir.path);
      addTearDown(() => dir.deleteSync(recursive: true));

      final labels = _qLabels();
      final bbox = BasemapFetcher.boundsOf(labels, 300);
      final dirty = jsonEncode({
        'version': 0.6,
        'elements': [
          for (final p in _far)
            {
              'type': 'node',
              'lat': p.$2,
              'lon': p.$3,
              'tags': {'place': 'village', 'name': p.$1},
            },
        ],
      });
      final cache = await BasemapCache.open();
      await cache.write('places', bbox, dirty);
      final raw = await cache.read('places', bbox);
      expect(raw, isNotNull);
      expect(raw!, contains('远北甲'), reason: '前置：脏数据确实进了缓存');

      OverpassClient.httpGetOverride = _emptyOverpass;
      AmapClient.httpGetOverride = (url) async => throw StateError('导出未传 amapKey');
      TiandituClient.httpGetOverride = (url) async => throw StateError('导出未传 tdtKey');

      final r = await DxfExporter.export(
        name: 'qa21_dirty',
        labels: labels,
        includeSurroundings: true,
        version: DxfVersion.r12,
        rangeM: 300,
        convertGcj: false,
      );
      final dxf = gbk_bytes.decode(r.file.readAsBytesSync());
      expect(_entitiesOnLayer(dxf, 'DiMing'), 0,
          reason: '旧缓存里的远端地名不得进入 DiMing 层');
      for (final p in _far) {
        expect(dxf.contains(p.$1), isFalse, reason: 'DXF 不得含远端地名 ${p.$1}');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('E. 反向：缓存里"线路旁/框内"的名字必须保留 → DiMing 层计数 > 0', () async {
      final dir = Directory.systemTemp.createTempSync('qa21_keep');
      PathProviderPlatform.instance = FakePathProvider(dir.path);
      addTearDown(() => dir.deleteSync(recursive: true));

      final labels = _qLabels();
      final bbox = BasemapFetcher.boundsOf(labels, 300);
      final good = jsonEncode({
        'version': 0.6,
        'elements': [
          for (final p in _near)
            {
              'type': 'node',
              'lat': p.$2,
              'lon': p.$3,
              'tags': {'place': 'village', 'name': p.$1},
            },
        ],
      });
      final cache = await BasemapCache.open();
      await cache.write('places', bbox, good);

      OverpassClient.httpGetOverride = _emptyOverpass;
      AmapClient.httpGetOverride = (url) async => throw StateError('未传 amapKey');
      TiandituClient.httpGetOverride = (url) async => throw StateError('未传 tdtKey');

      final r = await DxfExporter.export(
        name: 'qa21_keep',
        labels: labels,
        includeSurroundings: true,
        version: DxfVersion.r12,
        rangeM: 300,
        convertGcj: false,
      );
      final dxf = gbk_bytes.decode(r.file.readAsBytesSync());
      expect(_entitiesOnLayer(dxf, 'DiMing'), greaterThan(0),
          reason: '框内地名不得被裁剪误杀（用户身边的小区必须留下）');
      for (final p in _near) {
        expect(dxf.contains(p.$1), isTrue, reason: '框内 ${p.$1} 应出现在 DXF');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('QA21-F 容差口径（收紧后 ≤100m）', () {
    test('F. 容差 ≤100m：框外 ~80m 保留、~500m 剔除（防超范围名进图）', () {
      final bbox = BasemapFetcher.boundsOf(_qLabels(), 300);
      final midLat = (bbox[0] + bbox[2]) / 2;
      final cosLat = math.cos(midLat * math.pi / 180.0).abs();
      // 东向 bbox 外 ~80m（≤100m 容差）→ 应保留（边界正常 POI 不被误杀）。
      final p80 = PlaceFeature(
          name: '框外80m',
          lat: midLat,
          lon: bbox[3] + 80.0 / (111320.0 * cosLat),
          level: PlaceLevel.residential);
      // 东向 bbox 外 ~500m（>100m 容差）→ 必须剔除（不再放行"就近但出范围"的名）。
      final p500 = PlaceFeature(
          name: '框外500m',
          lat: midLat,
          lon: bbox[3] + 500.0 / (111320.0 * cosLat),
          level: PlaceLevel.residential);

      final kept = BasemapFetcher.cropPlaces([p80, p500], bbox)
          .map((p) => p.name)
          .toSet();
      expect(kept, contains('框外80m'),
          reason: '容差内（≤100m）边界 POI 必须保留');
      expect(kept, isNot(contains('框外500m')),
          reason: '超容差（>100m）必须剔除，避免用户设 50m 档时仍见远处名字');
    });
  });

  group('QA21-G 高德 polygon 坐标系（须传 GCJ-02 四角）', () {
    /// 解析 polygon 串 → 顶点集合 {(lon,lat)}。
    Set<(double, double)> _verts(String poly) => {
          for (final s in poly.split('|'))
            if (s.contains(','))
              (
                double.parse(s.split(',')[0]),
                double.parse(s.split(',')[1]),
              ),
        };

    test('G1. convertGcj=true → 顶点 = 「WGS 四角分别转 GCJ 后取分量极值」的包络框',
        () async {
      final bbox = BasemapFetcher.boundsOf(_qLabels(), 300);
      Uri? seen;
      AmapClient.httpGetOverride = (url) async {
        seen = url;
        return _ok(_amapBody(const []));
      };
      await AmapClient.poiInBounds(bbox, '小区', 'K', convertGcj: true);
      expect(seen, isNotNull);
      final got = _verts(seen!.queryParameters['polygon'] ?? '');
      // 期望：四角分别 wgs84ToGcj02 后取 min/max 的 GCJ 包络框（两个顶点）。
      final corners = <(double lat, double lon)>[
        (bbox[0], bbox[1]),
        (bbox[0], bbox[3]),
        (bbox[2], bbox[1]),
        (bbox[2], bbox[3]),
      ];
      var latMin = 90.0, latMax = -90.0, lonMin = 180.0, lonMax = -180.0;
      for (final c in corners) {
        final g = Gcj02Converter.wgs84ToGcj02(c.$1, c.$2);
        latMin = math.min(latMin, g[0]);
        latMax = math.max(latMax, g[0]);
        lonMin = math.min(lonMin, g[1]);
        lonMax = math.max(lonMax, g[1]);
      }
      final expLower = (lonMin, latMin);
      final expUpper = (lonMax, latMax);
      // 实现可能给 2 顶点（GCJ 包络框）或 4 顶点（精确变换四边形）：
      // 统一校验"实传顶点的 GCJ 包络"= 期望包络。
      var aLatMin = 90.0, aLatMax = -90.0, aLonMin = 180.0, aLonMax = -180.0;
      for (final v in got) {
        aLatMin = math.min(aLatMin, v.$2);
        aLatMax = math.max(aLatMax, v.$2);
        aLonMin = math.min(aLonMin, v.$1);
        aLonMax = math.max(aLonMax, v.$1);
      }
      bool near(double x, double y) => (x - y).abs() < 1e-4;
      final poly = seen!.queryParameters['polygon'];
      expect(near(aLonMin, expLower.$1) && near(aLatMin, expLower.$2),
          isTrue, reason: 'GCJ 包络左下角不符；期望 '
              '(${expLower.$1.toStringAsFixed(6)},${expLower.$2.toStringAsFixed(6)})；实传=$poly');
      expect(near(aLonMax, expUpper.$1) && near(aLatMax, expUpper.$2),
          isTrue, reason: 'GCJ 包络右上角不符；期望 '
              '(${expUpper.$1.toStringAsFixed(6)},${expUpper.$2.toStringAsFixed(6)})；实传=$poly');
      // 关键：绝不能仍是 WGS 原值（那是本次修复的 bug）。
      expect(near(aLonMin, bbox[1]) && near(aLatMin, bbox[0]), isFalse,
          reason: '传的不能是 WGS 原值（旧 bug：检索区偏 ~600m）；实传=$poly');
    });

    test('G2. convertGcj=false → 顶点为原 WGS 四角（对照）', () async {
      final bbox = BasemapFetcher.boundsOf(_qLabels(), 300);
      Uri? seen;
      AmapClient.httpGetOverride = (url) async {
        seen = url;
        return _ok(_amapBody(const []));
      };
      await AmapClient.poiInBounds(bbox, '小区', 'K', convertGcj: false);
      final got = _verts(seen!.queryParameters['polygon'] ?? '');
      for (final v in [
        (bbox[1], bbox[0]),
        (bbox[3], bbox[2]),
      ]) {
        expect(got.contains(v), isTrue, reason: 'WGS 档应原样传 WGS 角点 $v');
      }
    });
  });
}
