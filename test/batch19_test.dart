import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/geo/gcj02.dart';
import 'package:ovimap/services/search.dart';
import 'package:ovimap/services/tianditu.dart';
import 'package:ovimap/state/app_state.dart';

/// 第十九批 2 项（R1 天地图检索 GCJ-02→WGS-84 纠偏 / R2 搜索范围本地化）。
/// 全部零网络：GCJ 用纯函数断言；tianditu 出口用 httpGetOverride 注入 mock。
void main() {
  group('R1 GCJ-02 ↔ WGS-84 转换', () {
    test('往返一致性：wgs→gcj→wgs 误差 < 1e-5°（国内多点）', () {
      const points = [
        [32.10, 114.08], // 信阳
        [39.9042, 116.4074], // 北京
        [31.2304, 121.4737], // 上海
        [23.1291, 113.2644], // 广州
        [34.80, 114.35], // 开封附近
        [22.5431, 114.0579], // 深圳
      ];
      for (final p in points) {
        final gcj = Gcj02Converter.wgs84ToGcj02(p[0], p[1]);
        final back = Gcj02Converter.gcj02ToWgs84(gcj[0], gcj[1]);
        expect((back[0] - p[0]).abs(), lessThan(1e-5),
            reason: 'lat 往返不一致 @ $p');
        expect((back[1] - p[1]).abs(), lessThan(1e-5),
            reason: 'lon 往返不一致 @ $p');
      }
    });

    test('偏移量级：信阳 (32.10,114.08) 转换偏移 100~700 米（证明转换发生且合理）', () {
      const lat = 32.10, lon = 114.08;
      final gcj = Gcj02Converter.wgs84ToGcj02(lat, lon);
      final offsetM = SearchService.haversineM(lat, lon, gcj[0], gcj[1]);
      expect(offsetM, greaterThan(100));
      expect(offsetM, lessThan(700));

      // 反向：GCJ→WGS 同样应产生同量级偏移（近似逆变换有效）
      final wgs = Gcj02Converter.gcj02ToWgs84(lat, lon);
      final offsetM2 = SearchService.haversineM(lat, lon, wgs[0], wgs[1]);
      expect(offsetM2, greaterThan(100));
      expect(offsetM2, lessThan(700));
      // 正反向偏移应基本一致（同一点的两个方向的偏移量级相同）
      expect((offsetM - offsetM2).abs(), lessThan(50));
    });

    test('境外坐标原样返回（不偏移）', () {
      expect(Gcj02Converter.outOfChina(40.7128, -74.0060), isTrue); // 纽约
      expect(Gcj02Converter.outOfChina(51.5074, -0.1278), isTrue); // 伦敦
      expect(Gcj02Converter.outOfChina(32.10, 114.08), isFalse); // 信阳境内

      final a = Gcj02Converter.gcj02ToWgs84(40.7128, -74.0060);
      expect(a[0], 40.7128);
      expect(a[1], -74.0060);
      final b = Gcj02Converter.wgs84ToGcj02(51.5074, -0.1278);
      expect(b[0], 51.5074);
      expect(b[1], -0.1278);
    });

    test('北京/上海已知点：偏移量级落在公开参考值的合理区间（300~800 米）', () {
      // 不硬编码精确期望值（防公式版本差异），只断言量级合理。
      final bj = Gcj02Converter.wgs84ToGcj02(39.9042, 116.4074);
      final bjM = SearchService.haversineM(39.9042, 116.4074, bj[0], bj[1]);
      expect(bjM, greaterThan(300));
      expect(bjM, lessThan(800));

      final sh = Gcj02Converter.wgs84ToGcj02(31.2304, 121.4737);
      final shM = SearchService.haversineM(31.2304, 121.4737, sh[0], sh[1]);
      expect(shM, greaterThan(300));
      expect(shM, lessThan(800));
    });
  });

  group('R1 tianditu 出口纠偏（mock http，零网络）', () {
    final uris = <Uri>[];

    http.Response mockOk(String body) => http.Response.bytes(
        utf8.encode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

    Map<String, dynamic> postOf(Uri uri) =>
        jsonDecode(uri.queryParameters['postStr']!) as Map<String, dynamic>;

    setUp(() {
      uris.clear();
    });

    tearDown(() {
      TiandituClient.httpGetOverride = null;
    });

    test('默认（convertGcj=true）：返回的 SearchResult 已被纠偏', () async {
      TiandituClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return mockOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [
            {
              'name': '丰乐园',
              'address': '河南省信阳市浉河区',
              'lonlat': '114.080000,32.100000',
            }
          ],
          'area': null,
        }));
      };
      final res = await TiandituClient.search('丰乐园', 'k',
          mapBound: TiandituClient.nationalBound);
      expect(res, hasLength(1));
      final r = res.first;
      // 已被转换：与原始返回坐标 (32.10, 114.08) 不同，且偏移量级合理
      expect(r.lat, isNot(32.10));
      expect(r.lon, isNot(114.08));
      final offsetM = SearchService.haversineM(32.10, 114.08, r.lat, r.lon);
      expect(offsetM, greaterThan(100));
      expect(offsetM, lessThan(700));
      // 偏移方向一致性：对纠偏结果再正向加密，应回到原始返回坐标（误差 1e-3° 内）
      final back = Gcj02Converter.wgs84ToGcj02(r.lat, r.lon);
      expect((back[0] - 32.10).abs(), lessThan(1e-3));
      expect((back[1] - 114.08).abs(), lessThan(1e-3));
    });

    test('convertGcj=false：原样返回，不做转换', () async {
      TiandituClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return mockOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [
            {
              'name': '丰乐园',
              'address': '',
              'lonlat': '114.080000,32.100000',
            }
          ],
          'area': {'name': '浉河区', 'lonlat': '114.060000,32.120000'},
        }));
      };
      final res = await TiandituClient.search('丰乐园', 'k',
          mapBound: TiandituClient.nationalBound, convertGcj: false);
      expect(res, hasLength(2));
      expect(res[0].lat, 32.10);
      expect(res[0].lon, 114.08);
      // 行政区划命中同样原样
      expect(res[1].lat, 32.12);
      expect(res[1].lon, 114.06);
    });

    test('area 行政区划命中默认也被纠偏', () async {
      TiandituClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return mockOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [],
          'area': {'name': '浉河区', 'lonlat': '114.060000,32.120000'},
        }));
      };
      final res = await TiandituClient.search('浉河区', 'k',
          mapBound: TiandituClient.nationalBound);
      expect(res, hasLength(1));
      expect(res.first.lat, isNot(32.12));
    });

    test('R2 有基准点：mapBound 为基准点 ±0.3°，count 默认 15', () async {
      TiandituClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return mockOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [],
          'area': null,
        }));
      };
      final res = await TiandituClient.search('丰乐园', 'k',
          nearLat: 32.10, nearLon: 114.08);
      expect(res, isEmpty); // 本地/全国都空
      expect(uris, hasLength(2)); // 本地一次 + 全国兜底一次

      final local = postOf(uris[0]);
      expect(local['mapBound'], '113.78,31.8,114.38,32.4'); // ±0.3°
      expect(local['count'], 15);
      final national = postOf(uris[1]);
      expect(national['mapBound'], TiandituClient.nationalBound);
      expect(national['count'], 15);
    });

    test('R2 本地命中：只用本地范围，不发起全国重试', () async {
      TiandituClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return mockOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [
            {'name': '本地小区', 'address': '', 'lonlat': '114.081,32.101'}
          ],
          'area': null,
        }));
      };
      final res = await TiandituClient.search('本地', 'k',
          nearLat: 32.10, nearLon: 114.08);
      expect(res, hasLength(1));
      expect(uris, hasLength(1)); // 本地命中即返回
      expect(postOf(uris[0])['mapBound'], '113.78,31.8,114.38,32.4');
    });

    test('显式传 mapBound 时行为不变：按该范围查一次，不做兜底重试', () async {
      TiandituClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return mockOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [],
          'area': null,
        }));
      };
      final res = await TiandituClient.search('x', 'k',
          mapBound: '113,31,115,33', nearLat: 32.10, nearLon: 114.08);
      expect(res, isEmpty);
      expect(uris, hasLength(1));
      expect(postOf(uris[0])['mapBound'], '113,31,115,33');
    });

    test('poiInBounds：范围与 count 不变（行为兼容），出口纠偏生效', () async {
      TiandituClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return mockOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [
            {'name': '兜底小区', 'address': '', 'lonlat': '114.080,32.100'}
          ],
          'area': null,
        }));
      };
      // bbox = [minLat, minLon, maxLat, maxLon]
      final res = await TiandituClient.poiInBounds(
          [32.0, 113.9, 32.3, 114.3], '小区', 'k');
      expect(uris, hasLength(1));
      // mapBound = minLon,minLat,maxLon,maxLat
      expect(postOf(uris[0])['mapBound'], '113.9,32.0,114.3,32.3');
      expect(postOf(uris[0])['count'], 20);
      expect(res.first.lat, isNot(32.100)); // 已纠偏
    });
  });

  group('R1/R2 接线（设置项 + 消费端源级断言）', () {
    test('AppState.tdtConvertGcj：默认纠偏；wgs84 档关闭并持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
      expect(st.tdtCoordSys, AppState.tdtCoordGcj02);
      expect(st.tdtConvertGcj, isTrue);

      st.setTdtCoordSys(AppState.tdtCoordWgs84);
      expect(st.tdtCoordSys, AppState.tdtCoordWgs84);
      expect(st.tdtConvertGcj, isFalse);
      expect(st.prefs.getString(AppState.prefTdtCoordSys),
          AppState.tdtCoordWgs84);
    });

    test('home_page 搜索：传基准点 + 用户设置的纠偏开关', () async {
      final src = await File('lib/ui/home_page.dart').readAsString();
      // batch18 既有断言保持
      expect(src.contains('nearLat: near[0], nearLon: near[1]'), isTrue);
      // 新增：纠偏开关传入
      expect(src.contains('convertGcj: st.tdtConvertGcj'), isTrue);
    });

    test('dialogs：DXF 导出与 Key 设置对话框接线', () async {
      final src = await File('lib/ui/dialogs.dart').readAsString();
      // DXF 导出按用户设置传纠偏开关（含 dxf.dart 链路参数）
      expect(src.contains('AppState.prefTdtCoordSys'), isTrue);
      expect(src.contains('convertGcj: convertGcj'), isTrue);
      // Key 设置对话框含坐标系选择（默认 GCJ-02 纠偏档）
      expect(src.contains('tdtCoordGcj02'), isTrue);
      expect(src.contains('tdtCoordWgs84'), isTrue);
    });

    test('tianditu.dart 错误注释已修正（原"不做 GCJ/BD 转换"）', () async {
      final src = await File('lib/services/tianditu.dart').readAsString();
      expect(src.contains('不做 GCJ/BD 转换'), isFalse);
      expect(src.contains('GCJ-02'), isTrue);
      expect(src.contains('gcj02ToWgs84'), isTrue);
    });

    test('dxf.dart / basemap.dart 链路参数贯通', () async {
      final dxf = await File('lib/export/dxf.dart').readAsString();
      expect(dxf.contains('bool convertGcj = true'), isTrue);
      expect(dxf.contains('convertGcj: convertGcj'), isTrue);
      final bm = await File('lib/export/basemap.dart').readAsString();
      expect(bm.contains('bool convertGcj = true'), isTrue);
      expect(bm.contains('convertGcj: convertGcj'), isTrue);
    });
  });
}
