// 第二十一批：**地名兜底范围硬裁剪**（用户复现：「矢量图外侧很远处密密麻麻的名字」）
// + **高德内置 key**（开箱即用）。全部零网络、mock 注入。
//
// 覆盖：
//  R1 数据层裁剪：天地图 / 高德两条兜底来源，mock 返回「3 条框内 + 5 条框外几十公里」
//     → 最终 places 只含框内 3 条。
//  R1 使用层裁剪：污染期写入的「远端脏地名」缓存 → 导出后 DXF 的 DiMing 层不含它们。
//  R1 纯函数：cropPlaces 容忍 GCJ 纠偏余量、剔除数公里外。
//  R2 内置 key：kBuiltinAmapKey 常量、AppState.amapKey 未配置回退内置、配置优先用户值。
//  R2 高德优先：内置 key 生效后地名兜底走高德（source 含 +amap）。
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
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/amap.dart';
import 'package:ovimap/services/tianditu.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_dxf_fixture.dart';

// ---------------- 夹具 ----------------

const double kLat = 32.1264;
const double kLon = 114.0913;

List<MapLabel> _labels() => [
      MapLabel(typeId: 'pipe', seq: 1, lat: kLat, lon: kLon, lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe', seq: 2, lat: kLat, lon: kLon + 0.001, lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe', seq: 3, lat: kLat, lon: kLon + 0.002, lineGroupId: 'g'),
    ];

/// 框内 3 条（落在线路外扩 bbox 中心附近，安全）。
const List<(String, double, double)> _inFrame = [
  ('花园一号', 32.1265, 114.0915),
  ('花园二号', 32.1250, 114.0920),
  ('花园三号', 32.1280, 114.0918),
];

/// 框外 5 条：信阳辖区县城，距线路几十公里（用户实测污染数据同源）。
const List<(String, double, double)> _farPlaces = [
  ('息县花园', 32.56, 114.99),
  ('光山花园', 32.01, 114.91),
  ('罗山花园', 31.93, 114.43),
  ('潢川花园', 32.18, 115.36),
  ('商城花园', 31.98, 115.44),
];

http.Response _ok(String body, {int status = 200}) => http.Response(
      body, status,
      headers: const {'content-type': 'application/json; charset=utf-8'});

/// 天地图 v2/search 应答（lonlat = "经度,纬度"）。
String _tdtBody(List<(String, double, double)> pts) => jsonEncode({
      'status': {'infocode': 1000, 'cndesc': '成功'},
      'resultType': 1,
      'pois': [
        for (final p in pts)
          {'name': p.$1, 'address': '', 'lonlat': '${p.$3},${p.$2}'},
      ],
    });

/// 高德 v5/place/polygon 应答（location = "经度,纬度"）。
String _amapBody(List<(String, double, double)> pts) => jsonEncode({
      'status': '1',
      'info': 'OK',
      'infocode': '10000',
      'count': '${pts.length}',
      'pois': [
        for (final p in pts)
          {'id': 'B0FF${p.$1}', 'name': p.$1, 'address': '', 'location': '${p.$3},${p.$2}'},
      ],
    });

/// OSM 各数据集均返回合法空集（地名过少 → 触发兜底）。
Future<http.Response> _emptyOverpass(Uri url,
        {Map<String, String>? headers}) async =>
    _ok('{"version":0.6,"elements":[]}');

/// DXF 文本中某图层上的实体数（组码 8 = 图层名）。
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

  // ==================== R1：数据层范围硬裁剪 ====================

  group('R1 地名兜底范围硬裁剪（天地图 / 高德）', () {
    test('天地图来源：3 框内 + 5 框外 → places 只含框内 3 条', () async {
      final dir = Directory.systemTemp.createTempSync('ovimap_b21_tdt');
      addTearDown(() => dir.deleteSync(recursive: true));

      OverpassClient.httpGetOverride = _emptyOverpass;
      AmapClient.httpGetOverride =
          (url) async => throw StateError('未配高德 key 时不应调用高德');
      // 天地图每个关键词都返回同样的 3 框内 + 5 框外（共 8 条）。
      TiandituClient.httpGetOverride =
          (url) async => _ok(_tdtBody([..._inFrame, ..._farPlaces]));

      final data = await BasemapFetcher.fetchFor(
        _labels(),
        rangeM: 300,
        amapKey: '',
        tdtKey: 't',
        convertGcj: false, // 关闭纠偏 → mock 坐标原样，判定确定
        cache: BasemapCache(dir),
      );

      expect(data.places, hasLength(3),
          reason: '框外几十公里的地名必须被裁掉（用户复现根因）');
      final names = data.places.map((p) => p.name).toSet();
      for (final p in _inFrame) {
        expect(names, contains(p.$1), reason: '框内 ${p.$1} 应保留');
      }
      for (final p in _farPlaces) {
        expect(names, isNot(contains(p.$1)), reason: '框外 ${p.$1} 必须剔除');
      }
      expect(data.report.places.count, 3, reason: 'report.count 与裁剪后口径一致');
      expect(data.report.places.source, contains('+tdt'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('高德来源：3 框内 + 5 框外 → places 只含框内 3 条（天地图不被调用）', () async {
      final dir = Directory.systemTemp.createTempSync('ovimap_b21_amap');
      addTearDown(() => dir.deleteSync(recursive: true));

      OverpassClient.httpGetOverride = _emptyOverpass;
      // 高德每个关键词都返回 3 框内 + 5 框外。
      AmapClient.httpGetOverride =
          (url) async => _ok(_amapBody([..._inFrame, ..._farPlaces]));
      TiandituClient.httpGetOverride =
          (url) async => throw StateError('高德有结果时不得回落天地图');

      final data = await BasemapFetcher.fetchFor(
        _labels(),
        rangeM: 300,
        amapKey: 'A',
        tdtKey: 't',
        convertGcj: false,
        cache: BasemapCache(dir),
      );

      expect(data.places, hasLength(3), reason: '高德 polygonsearch 同样走统一裁剪');
      final names = data.places.map((p) => p.name).toSet();
      for (final p in _inFrame) {
        expect(names, contains(p.$1));
      }
      for (final p in _farPlaces) {
        expect(names, isNot(contains(p.$1)));
      }
      expect(data.report.places.source, contains('+amap'));
      expect(data.report.places.source.contains('+tdt'), isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('cropPlaces 纯函数：容差内(≤100m)保留、超出(>100m)剔除', () {
      final bbox = BasemapFetcher.boundsOf(_labels(), 300);
      final midLat = (bbox[0] + bbox[2]) / 2;
      final cosLat = math.cos(midLat * math.pi / 180.0).abs();
      final midLon = (bbox[1] + bbox[3]) / 2;

      final inside = PlaceFeature(
          name: '框内', lat: midLat, lon: midLon,
          level: PlaceLevel.residential);
      // 容差内（bbox 外 ~80m，≤ placeCropTolM=100m）应保留：避免边界正常 POI 被误杀。
      final inTol = PlaceFeature(
          name: '容差内80m',
          lat: midLat,
          lon: bbox[3] + 80.0 / (111320.0 * cosLat),
          level: PlaceLevel.residential);
      // 超出容差（bbox 外 ~500m）必须剔除——收紧后不再放行"就近但出范围"的名字。
      final outTol = PlaceFeature(
          name: '超容差500m',
          lat: midLat,
          lon: bbox[3] + 500.0 / (111320.0 * cosLat),
          level: PlaceLevel.residential);
      // 数公里外（远超容差）必须剔除。
      final farNorth = PlaceFeature(
          name: '远方北',
          lat: bbox[2] + 5000.0 / 110540.0, // 北向 ~5km
          lon: midLon,
          level: PlaceLevel.residential);
      final farEast = PlaceFeature(
          name: '远方东',
          lat: midLat,
          lon: bbox[3] + 5000.0 / (111320.0 * cosLat), // 东向 ~5km
          level: PlaceLevel.residential);

      final kept = BasemapFetcher.cropPlaces(
          [inside, inTol, outTol, farNorth, farEast], bbox);
      final keptNames = kept.map((p) => p.name).toSet();
      expect(keptNames, containsAll(['框内', '容差内80m']));
      expect(keptNames, isNot(contains('超容差500m')));
      expect(keptNames, isNot(contains('远方北')));
      expect(keptNames, isNot(contains('远方东')));
    });
  });

  // ==================== R1：使用层（旧缓存）防御 ====================

  group('R1 旧缓存防御：污染期远端地名词不进 DXF', () {
    test('缓存含 5 条远端地名 → 导出后 DiMing 层不含它们', () async {
      final dir = Directory.systemTemp.createTempSync('ovimap_b21_dirty');
      PathProviderPlatform.instance = FakePathProvider(dir.path);
      addTearDown(() => dir.deleteSync(recursive: true));

      final labels = _labels();
      final bbox = BasemapFetcher.boundsOf(labels, 300);

      // 构造"污染期"写入的地名缓存：全部是框外几十公里的远端地名。
      final dirtyJson = jsonEncode({
        'version': 0.6,
        'elements': [
          for (final p in _farPlaces)
            {
              'type': 'node',
              'lat': p.$2,
              'lon': p.$3,
              'tags': {'place': 'village', 'name': p.$1},
            },
        ],
      });
      final cache = await BasemapCache.open();
      await cache.write('places', bbox, dirtyJson);

      // 前置确认：脏数据确实进了缓存（否则本用例失去意义）。
      final raw = await cache.read('places', bbox);
      expect(raw, isNotNull);
      expect(raw!, contains('息县'));

      // 打开/导出：不注入 basemap → 命中上面缓存，走 fetchFor 出口裁剪兜底。
      OverpassClient.httpGetOverride = _emptyOverpass;
      AmapClient.httpGetOverride =
          (url) async => throw StateError('导出未传 amapKey，不应调用高德');
      TiandituClient.httpGetOverride =
          (url) async => throw StateError('导出未传 tdtKey，不应调用天地图');

      final r = await DxfExporter.export(
        name: '污染缓存防御',
        labels: labels,
        includeSurroundings: true,
        version: DxfVersion.r12,
        rangeM: 300,
        // 关键：不传 basemap / localBasemap → 由 fetchFor 读缓存
      );

      final dxf = gbk_bytes.decode(r.file.readAsBytesSync());
      expect(_entitiesOnLayer(dxf, 'DiMing'), 0,
          reason: '旧缓存里的远端地名不得出现在 DXF 的 DiMing 层');
      for (final p in _farPlaces) {
        expect(dxf.contains(p.$1), isFalse,
            reason: 'DXF 不得含远端地名：${p.$1}');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ==================== R2：内置高德 key ====================

  group('R2 内置高德 key（开箱即用）', () {
    test('kBuiltinAmapKey 常量存在且与 AppState.builtinAmapKey 同源', () {
      // 仓库公开后内置 key 不入库（v3.9.2）：常量保留为「配置位」（空串），
      // 只断言同源关系，绝不把密钥写进源码。
      expect(kBuiltinAmapKey, isA<String>());
      expect(AppState.builtinAmapKey, kBuiltinAmapKey);
    });

    test('AppState.amapKey：未配置回退内置；配置后优先用户值', () async {
      SharedPreferences.setMockInitialValues({});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());

      expect(st.userAmapKey, '');
      expect(st.amapKey, kBuiltinAmapKey, reason: '未配置 → 内置 key');

      st.setAmapKey('my-amap-key');
      expect(st.userAmapKey, 'my-amap-key');
      expect(st.amapKey, 'my-amap-key', reason: '配置后 → 用户值优先');

      st.setAmapKey('');
      expect(st.amapKey, kBuiltinAmapKey, reason: '清空 → 恢复内置 key');
    });

    // 仓库公开后内置 key 为空（v3.9.2）：本用例改为「用户填了自己的 key」路径，
    // 语义不变——有 key 就走高德，不回落天地图。
    test('配置了高德 key 后地名兜底走高德（source 含 +amap）', () async {
      SharedPreferences.setMockInitialValues({'amapKey': 'user_test_key'});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
      expect(st.amapKey, 'user_test_key');

      final dir = Directory.systemTemp.createTempSync('ovimap_b21_builtin');
      addTearDown(() => dir.deleteSync(recursive: true));

      OverpassClient.httpGetOverride = _emptyOverpass;
      AmapClient.httpGetOverride =
          (url) async => _ok(_amapBody(_inFrame)); // 只返回框内
      TiandituClient.httpGetOverride =
          (url) async => throw StateError('配置了高德 key 时不应回落天地图');

      final data = await BasemapFetcher.fetchFor(
        _labels(),
        rangeM: 300,
        amapKey: st.amapKey, // = 用户配置的 key
        tdtKey: 't',
        convertGcj: false,
        cache: BasemapCache(dir),
      );

      expect(data.places, hasLength(3));
      expect(data.report.places.source, contains('+amap'),
          reason: '配置了 key → 地名兜底自动走高德');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
