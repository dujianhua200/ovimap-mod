// 第二十一批（修正）：**高德 polygon 顶点坐标系**（WGS-84 bbox → GCJ-02 再拼串）
// + **地名裁剪容差收到 100m**。零网络、mock 注入。
//
// 背景（QA 独立验证发现的关键真 Bug）：
//   高德按 **GCJ-02** 解读 polygon 顶点，旧代码直接拿 WGS-84 bbox 原值拼串 →
//   检索区整体偏移 ~600m（漏框内东北、多收西南）。修后：convertGcj=true 时，
//   bbox 四角各自 wgs84ToGcj02 后取分量极值构成覆盖框再拼「左下|右上」。
//
// 注：既有测试侧（batch20_test / qa_batch20_indep_test / batch21_place_crop_test）
//     的 mock/断言由 QA 同批同步修正；本文件为工程师源码侧独立对拍。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/geo/gcj02.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/amap.dart';

http.Response _ok(String body, {int status = 200}) => http.Response(
      body, status,
      headers: const {'content-type': 'application/json; charset=utf-8'});

/// 与 `AmapClient.poiInBounds` 相同的四角转 GCJ 覆盖框算法（对拍用）。
/// 返回 `[latMin, lonMin, latMax, lonMax]`（GCJ-02）。
List<double> _expectedGcjCover(List<double> bbox) {
  final corners = <List<double>>[
    [bbox[0], bbox[1]], // 左下
    [bbox[0], bbox[3]], // 右下
    [bbox[2], bbox[1]], // 左上
    [bbox[2], bbox[3]], // 右上
  ];
  var latMin = 90.0, latMax = -90.0, lonMin = 180.0, lonMax = -180.0;
  for (final c in corners) {
    final p = Gcj02Converter.wgs84ToGcj02(c[0], c[1]);
    if (p[0] < latMin) latMin = p[0];
    if (p[0] > latMax) latMax = p[0];
    if (p[1] < lonMin) lonMin = p[1];
    if (p[1] > lonMax) lonMax = p[1];
  }
  return [latMin, lonMin, latMax, lonMax];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => AmapClient.httpGetOverride = null);
  tearDown(() => AmapClient.httpGetOverride = null);

  // ==================== 高德 polygon 顶点坐标系 ====================

  group('高德 polygon 顶点须先转 GCJ-02（QA 发现的关键真 Bug）', () {
    test('convertGcj=true：polygon 顶点 = bbox 四角 GCJ 覆盖框（与 wgs84ToGcj02 对拍）',
        () async {
      Uri? seen;
      AmapClient.httpGetOverride = (url) async {
        seen = url;
        return _ok(
            '{"status":"1","info":"OK","infocode":"10000","pois":[]}');
      };
      final bbox = <double>[32.10, 114.00, 32.20, 114.10]; // WGS-84
      await AmapClient.poiInBounds(bbox, '小区', 'k');
      final poly = seen!.queryParameters['polygon']!;

      final exp = _expectedGcjCover(bbox);
      // exp = [latMin, lonMin, latMax, lonMax] → 左下(lon,lat)|右上(lon,lat)
      final expected = '${exp[1]},${exp[0]}|${exp[3]},${exp[2]}';
      expect(poly, expected,
          reason: 'polygon 顶点必须是把四角各自转 GCJ 后的覆盖框');

      // 必须与"未转换的 WGS 原值"不同——否则等于没转（旧 Bug）。
      expect(poly, isNot('${bbox[1]},${bbox[0]}|${bbox[3]},${bbox[2]}'),
          reason: '不得再用 WGS 原值拼 polygon（旧 Bug：检索区偏移 ~600m）');

      // 仍是「左下 | 右上」的轴对齐框（lon/lat 各自递增）。
      final parts = poly.split('|');
      final l0 = parts[0].split(','), l1 = parts[1].split(',');
      expect(double.parse(l0[0]), lessThan(double.parse(l1[0])),
          reason: '左顶点经度 < 右顶点经度');
      expect(double.parse(l0[1]), lessThan(double.parse(l1[1])),
          reason: '下顶点纬度 < 上顶点纬度');
      expect(seen!.host, 'restapi.amap.com');
      expect(seen!.path, '/v5/place/polygon');
      expect(seen!.queryParameters['keywords'], '小区');
    });

    test('convertGcj=false：polygon 保持 WGS-84 原值（"原样返回"语义）', () async {
      Uri? seen;
      AmapClient.httpGetOverride = (url) async {
        seen = url;
        return _ok(
            '{"status":"1","info":"OK","infocode":"10000","pois":[]}');
      };
      final bbox = <double>[32.10, 114.00, 32.20, 114.10];
      await AmapClient.poiInBounds(bbox, '小区', 'k', convertGcj: false);
      expect(seen!.queryParameters['polygon'], '114.0,32.1|114.1,32.2',
          reason: 'convertGcj=false 时不转换，保持 WGS 原值（对照/测试用）');
    });

    test('转换后检索框确实平移到 GCJ 空间（覆盖原 WGS 框的 GCJ 像）', () async {
      // 取一个真实信阳 bbox，验证转换非平凡且量级正确（该地区 GCJ 相对 WGS
      // 约 +0.0057° 经 / −0.0019° 纬 ≈ 数百米；方向随地域不同，只校验量级+对拍）。
      Uri? seen;
      AmapClient.httpGetOverride = (url) async {
        seen = url;
        return _ok('{"status":"1","info":"OK","infocode":"10000","pois":[]}');
      };
      final bbox = <double>[32.1237, 114.0881, 32.1291, 114.0965];
      await AmapClient.poiInBounds(bbox, '小区', 'k');
      final poly = seen!.queryParameters['polygon']!;
      final exp = _expectedGcjCover(bbox);
      expect((exp[1] - bbox[1]).abs(), greaterThan(0.004),
          reason: '经度偏移应为数百米量级');
      expect((exp[0] - bbox[0]).abs(), greaterThan(0.0010),
          reason: '纬度偏移应为百米量级');
      expect(poly, '${exp[1]},${exp[0]}|${exp[3]},${exp[2]}');
    });
  });

  // ==================== 地名裁剪容差（100m） ====================

  group('地名裁剪容差收到 100m', () {
    List<MapLabel> labels() => [
          MapLabel(
              typeId: 'pipe', seq: 1, lat: 32.1264, lon: 114.0913, lineGroupId: 'g'),
          MapLabel(
              typeId: 'pipe', seq: 2, lat: 32.1264, lon: 114.0933, lineGroupId: 'g'),
        ];

    test('常量 = 100m', () {
      expect(BasemapFetcher.placeCropTolM, 100.0);
    });

    test('bbox 外 ~80m（容差内）保留；外 ~500m（远超容差）剔除', () {
      final bbox = BasemapFetcher.boundsOf(labels(), 300);
      final midLat = (bbox[0] + bbox[2]) / 2;
      final cosLat = math.cos(midLat * math.pi / 180.0).abs();
      final midLon = (bbox[1] + bbox[3]) / 2;

      final inside = PlaceFeature(
          name: '框内', lat: midLat, lon: midLon,
          level: PlaceLevel.residential);
      final near = PlaceFeature(
          name: '外80m',
          lat: bbox[2] + 80.0 / 110540.0, // 北向外 ~80m（< 100m 容差）
          lon: midLon,
          level: PlaceLevel.residential);
      final nearEast = PlaceFeature(
          name: '外东80m',
          lat: midLat,
          lon: bbox[3] + 80.0 / (111320.0 * cosLat), // 东向外 ~80m
          level: PlaceLevel.residential);
      final far = PlaceFeature(
          name: '外500m',
          lat: bbox[2] + 500.0 / 110540.0, // 北向外 ~500m（>> 100m）
          lon: midLon,
          level: PlaceLevel.residential);

      final kept = BasemapFetcher.cropPlaces(
          [inside, near, nearEast, far], bbox).map((p) => p.name).toSet();
      expect(kept, containsAll(['框内', '外80m', '外东80m']));
      expect(kept, isNot(contains('外500m')),
          reason: '500m 远超 100m 容差，必须剔除');
    });

    test('几十公里外的远端地名必被剔除（用户复现根因）', () {
      final bbox = BasemapFetcher.boundsOf(labels(), 300);
      final farPlaces = [
        PlaceFeature(
            name: '息县', lat: 32.56, lon: 114.99, level: PlaceLevel.village),
        PlaceFeature(
            name: '光山', lat: 32.01, lon: 114.91, level: PlaceLevel.village),
        PlaceFeature(
            name: '商城', lat: 31.98, lon: 115.44, level: PlaceLevel.village),
      ];
      expect(BasemapFetcher.cropPlaces(farPlaces, bbox), isEmpty);
    });
  });
}
