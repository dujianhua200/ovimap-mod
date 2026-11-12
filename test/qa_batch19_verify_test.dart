import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ovimap/geo/gcj02.dart';
import 'package:ovimap/services/tianditu.dart';

/// QA 第十九批独立验证（不依赖工程师的 fixture / 参考值）：
/// - 正向加密为 QA 自写参考实现（Lee Chao 公开算法，独立于被测代码），
///   仅用被测的 `gcj02ToWgs84` 做逆变换对拍。
/// - tianditu mock 为 QA 自造响应（坐标由参考实现正向加密已知 wgs 点得到）。
void main() {
  // ===== QA 独立参考实现：WGS-84 → GCJ-02 正向加密 =====
  const refA = 6378245.0;
  const refEE = 0.00669342162296594323;

  double refTransformLat(double x, double y) {
    var ret = -100.0 +
        2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
    ret += (20.0 * math.sin(y * math.pi) +
            40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0;
    ret += (160.0 * math.sin(y / 12.0 * math.pi) +
            320.0 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0;
    return ret;
  }

  double refTransformLon(double x, double y) {
    var ret = 300.0 +
        x + 2.0 * y + 0.1 * x * x + 0.1 * x * y +
        0.1 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
    ret += (20.0 * math.sin(x * math.pi) +
            40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0;
    ret += (150.0 * math.sin(x / 12.0 * math.pi) +
            300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0;
    return ret;
  }

  List<double> refWgsToGcj(double lat, double lon) {
    var dLat = refTransformLat(lon - 105.0, lat - 35.0);
    var dLon = refTransformLon(lon - 105.0, lat - 35.0);
    final radLat = lat / 180.0 * math.pi;
    var magic = math.sin(radLat);
    magic = 1 - refEE * magic * magic;
    final sqrtMagic = math.sqrt(magic);
    dLat = (dLat * 180.0) /
        ((refA * (1 - refEE)) / (magic * sqrtMagic) * math.pi);
    dLon = (dLon * 180.0) / (refA / sqrtMagic * math.cos(radLat) * math.pi);
    return [lat + dLat, lon + dLon];
  }

  group('B. GCJ-02 逆变换独立对拍（QA 参考实现正向 → 被测代码逆向）', () {
    // 5 个国内点（含主理人指定 4 点 + 边界深圳）
    const points = <String, List<double>>{
      '信阳': [32.1, 114.08],
      '北京': [39.9, 116.4],
      '广州': [23.1, 113.3],
      '乌鲁木齐': [43.8, 87.6],
      '哈尔滨': [45.8, 126.5],
      '深圳/香港边界': [22.5, 114.0],
    };

    for (final entry in points.entries) {
      test('${entry.key} ${entry.value}: 逆变换还原误差 < 1e-4°', () {
        final wgs = entry.value;
        final gcj = refWgsToGcj(wgs[0], wgs[1]);
        final back = Gcj02Converter.gcj02ToWgs84(gcj[0], gcj[1]);
        final dLat = (back[0] - wgs[0]).abs();
        final dLon = (back[1] - wgs[1]).abs();
        expect(dLat, lessThan(1e-4), reason: '${entry.key} lat 还原误差 $dLat');
        expect(dLon, lessThan(1e-4), reason: '${entry.key} lon 还原误差 $dLon');
      });
    }

    test('信阳偏移量级：gcj02ToWgs84 输入输出差 100~700 米', () {
      final out = Gcj02Converter.gcj02ToWgs84(32.1, 114.08);
      // haversine（米）
      double havM(double la1, double lo1, double la2, double lo2) {
        const r = 6371000.0;
        final dLa = (la2 - la1) * math.pi / 180.0;
        final dLo = (lo2 - lo1) * math.pi / 180.0;
        final a = math.sin(dLa / 2) * math.sin(dLa / 2) +
            math.cos(la1 * math.pi / 180) *
                math.cos(la2 * math.pi / 180) *
                math.sin(dLo / 2) * math.sin(dLo / 2);
        return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
      }

      final m = havM(32.1, 114.08, out[0], out[1]);
      expect(m, greaterThan(100), reason: '信阳纠偏偏移 $m m');
      expect(m, lessThan(700), reason: '信阳纠偏偏移 $m m');
    });

    test('境外（纽约/伦敦/东京）原样返回', () {
      const overseas = <List<double>>[
        [40.7128, -74.006], // 纽约
        [51.5074, -0.1278], // 伦敦
        [35.6762, 139.6503], // 东京
      ];
      for (final p in overseas) {
        final r = Gcj02Converter.gcj02ToWgs84(p[0], p[1]);
        expect(r[0], p[0], reason: '境外 lat 应原样');
        expect(r[1], p[1], reason: '境外 lon 应原样');
        expect(Gcj02Converter.outOfChina(p[0], p[1]), isTrue);
      }
    });

    test('边界/异常输入不崩：NaN/Infinity/边界点', () {
      // NaN：不抛异常（返回 NaN 即视为不崩）
      final nan = Gcj02Converter.gcj02ToWgs84(double.nan, double.nan);
      expect(nan.length, 2);
      // Infinity：境外判定 → 原样
      final inf = Gcj02Converter.gcj02ToWgs84(double.infinity, 114.0);
      expect(inf[0], double.infinity);
      final inf2 = Gcj02Converter.gcj02ToWgs84(32.1, double.negativeInfinity);
      expect(inf2[1], double.negativeInfinity);
      // 边界点不崩
      Gcj02Converter.gcj02ToWgs84(0.9, 72.1);
      Gcj02Converter.gcj02ToWgs84(55.8, 137.8);
      Gcj02Converter.gcj02ToWgs84(0.0, 0.0);
    });
  });

  group('C. tianditu 出口纠偏对抗（QA 自造 mock：正向加密已知 wgs 点）', () {
    final uris = <Uri>[];

    http.Response mockOk(String body) => http.Response.bytes(
        utf8.encode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

    setUp(() => uris.clear());
    tearDown(() => TiandituClient.httpGetOverride = null);

    test('默认 convertGcj=true：poi 坐标还原为原 wgs（<2e-4°）', () async {
      const wgs = [32.1234, 114.0567];
      final gcj = refWgsToGcj(wgs[0], wgs[1]);
      TiandituClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return mockOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [
            {
              'name': 'QA测试小区',
              'address': '信阳',
              'lonlat': '${gcj[1].toStringAsFixed(6)},${gcj[0].toStringAsFixed(6)}',
            }
          ],
          'area': null,
        }));
      };
      final res = await TiandituClient.search('QA测试', 'k',
          mapBound: TiandituClient.nationalBound);
      expect(res, hasLength(1));
      expect((res.first.lat - wgs[0]).abs(), lessThan(2e-4),
          reason: 'poi lat 未还原到原 wgs');
      expect((res.first.lon - wgs[1]).abs(), lessThan(2e-4),
          reason: 'poi lon 未还原到原 wgs');
    });

    test('convertGcj=false：返回原始 gcj 坐标（不转换）', () async {
      const wgs = [32.1234, 114.0567];
      final gcj = refWgsToGcj(wgs[0], wgs[1]);
      TiandituClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return mockOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [
            {
              'name': 'QA测试小区',
              'address': '',
              'lonlat': '${gcj[1].toStringAsFixed(6)},${gcj[0].toStringAsFixed(6)}',
            }
          ],
          'area': null,
        }));
      };
      final res = await TiandituClient.search('QA测试', 'k',
          mapBound: TiandituClient.nationalBound, convertGcj: false);
      expect(res, hasLength(1));
      // mock 坐标按 6 位小数序列化，故以 1e-6 容差比对（未转换应等于 gcj 原值）
      expect((res.first.lat - gcj[0]).abs(), lessThan(1e-6));
      expect((res.first.lon - gcj[1]).abs(), lessThan(1e-6));
      // 且确实不等于原 wgs 点（转换关闭 = 原样保留 gcj）
      expect((res.first.lat - wgs[0]).abs(), greaterThan(0.001));
    });

    test('area 行政区划命中：默认同样被纠偏', () async {
      const wgs = [32.4321, 114.0912];
      final gcj = refWgsToGcj(wgs[0], wgs[1]);
      TiandituClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return mockOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [],
          'area': {
            'name': 'QA区',
            'lonlat': '${gcj[1].toStringAsFixed(6)},${gcj[0].toStringAsFixed(6)}',
          },
        }));
      };
      final res = await TiandituClient.search('QA区', 'k',
          mapBound: TiandituClient.nationalBound);
      expect(res, hasLength(1));
      expect((res.first.lat - wgs[0]).abs(), lessThan(2e-4),
          reason: 'area lat 未还原');
      expect((res.first.lon - wgs[1]).abs(), lessThan(2e-4),
          reason: 'area lon 未还原');
    });
  });

  group('D. 两段式 mapBound（QA 独立复算）', () {
    final uris = <Uri>[];

    http.Response mockOk(String body) => http.Response.bytes(
        utf8.encode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

    Map<String, dynamic> postOf(Uri uri) =>
        jsonDecode(uri.queryParameters['postStr']!) as Map<String, dynamic>;

    setUp(() => uris.clear());
    tearDown(() => TiandituClient.httpGetOverride = null);

    test('有基准点：首查 mapBound = 基准±0.3°（独立格式化，非复用期望串）', () async {
      // 基准点 32.1,114.08 → 期望 113.78,31.8,114.38,32.4（独立拼串核对）
      const baseLat = 32.1, baseLon = 114.08;
      final expected =
          '${baseLon - 0.3},${baseLat - 0.3},${baseLon + 0.3},${baseLat + 0.3}';
      expect(expected, '113.78,31.8,114.38,32.4'); // 与工程师示例交叉核对一致

      TiandituClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return mockOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [],
          'area': null,
        }));
      };
      await TiandituClient.search('丰乐园', 'k',
          nearLat: baseLat, nearLon: baseLon);
      expect(uris, hasLength(2)); // 本地空 → 全国兜底
      expect(postOf(uris[0])['mapBound'], expected);
      expect(postOf(uris[0])['count'], 15);
      expect(postOf(uris[1])['mapBound'], '73,3,135,54');
    });

    test('本地命中：只发一次请求（本地范围）', () async {
      TiandituClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return mockOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [
            {'name': 'X', 'address': '', 'lonlat': '114.081,32.101'}
          ],
          'area': null,
        }));
      };
      final res = await TiandituClient.search('X', 'k',
          nearLat: 32.1, nearLon: 114.08);
      expect(res, hasLength(1));
      expect(uris, hasLength(1));
      expect(postOf(uris[0])['mapBound'], '113.78,31.8,114.38,32.4');
    });

    test('显式 mapBound：不做两段式（与 nearLat/nearLon 同时给也只查显式范围）', () async {
      TiandituClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return mockOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [],
          'area': null,
        }));
      };
      await TiandituClient.search('x', 'k',
          mapBound: '113,31,115,33', nearLat: 32.1, nearLon: 114.08);
      expect(uris, hasLength(1));
      expect(postOf(uris[0])['mapBound'], '113,31,115,33');
    });
  });
}
