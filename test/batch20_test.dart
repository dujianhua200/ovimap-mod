// 第二十批：**建筑/道路导不出**回归验证 + **高德搜索接入**（全部零网络，mock 注入）。
//
// 覆盖：
//  R1-1 roads/buildings 全链路三路径（注入 basemap / fetchFor 缓存命中 / 抓取）
//  R1-2 Overpass 端点清理、超时竞速、全失败重试
//  R1-3 导出前"抓到了什么"（BasemapFetchReport 汇总/状态行）
//  R2   高德解析（location 字符串 → [lat,lon] + GCJ→WGS）、搜索源优先级与降级、
//       DXF 地名兜底高德优先、设置项持久化
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/export/overpass.dart';
import 'package:ovimap/geo/gcj02.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/amap.dart';
import 'package:ovimap/services/search.dart';
import 'package:ovimap/services/tianditu.dart';
import 'package:ovimap/state/app_state.dart';

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

String _roadsJson() => jsonEncode({
      'elements': [
        {
          'type': 'way',
          'geometry': [
            {'lat': kLat, 'lon': kLon - 0.002},
            {'lat': kLat, 'lon': kLon + 0.003},
          ],
          'tags': {'highway': 'trunk', 'name': '主干道'}
        },
        {
          'type': 'way',
          'geometry': [
            {'lat': kLat - 0.001, 'lon': kLon},
            {'lat': kLat + 0.002, 'lon': kLon},
          ],
          'tags': {'highway': 'primary', 'name': '人民路'}
        },
      ]
    });

String _buildingsJson() => jsonEncode({
      'elements': [
        {
          'type': 'way',
          'geometry': [
            {'lat': 32.1268, 'lon': 114.0918},
            {'lat': 32.1268, 'lon': 114.0924},
            {'lat': 32.1273, 'lon': 114.0924},
            {'lat': 32.1273, 'lon': 114.0918},
          ],
          'tags': {'building': 'yes', 'name': '李庄1号楼'}
        },
        {
          'type': 'way',
          'geometry': [
            {'lat': 32.1252, 'lon': 114.0930},
            {'lat': 32.1252, 'lon': 114.0935},
            {'lat': 32.1257, 'lon': 114.0935},
            {'lat': 32.1257, 'lon': 114.0930},
          ],
          'tags': {'building': 'house', 'name': '李庄2号楼'}
        },
      ]
    });

const String _emptyJson = '{"elements":[]}';

/// 空壳镜像的真实应答形态（osm.ch 实测：200 + 268B + elements=[]）。
const String emptyElementsJson = '{"elements":[]}';

/// 按查询内容分发的 Overpass mock：`highway` → 道路，`building` → 建筑，其余空。
void _mockOverpass({int failTimes = 0}) {
  var calls = 0;
  OverpassClient.httpGetOverride = (url, {headers}) async {
    calls++;
    if (calls <= failTimes) {
      throw const HttpException('mock 网络不可达');
    }
    final data = url.queryParameters['data'] ?? '';
    final String body;
    if (data.contains('"highway"')) {
      body = _roadsJson();
    } else if (data.contains('"building"')) {
      body = _buildingsJson();
    } else {
      body = _emptyJson;
    }
    return _ok(body, status: 200);
  };
}

/// 构造 mock 响应：**必须显式声明 utf-8**，否则 http.Response 默认按 Latin-1 编码，
/// 中文 JSON（"主干道"/"李庄小区"）会抛 "Contains invalid characters"。
http.Response _ok(String body, {int status = 200}) =>
    http.Response(body, status,
        headers: const {'content-type': 'application/json; charset=utf-8'});

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

  // ============ R1-1：roads/buildings 端到端三路径 ============

  group('R1-1 建筑/道路端到端（第十九批后无回归）', () {
    test('路径①：注入 basemap → DXF 出 DaoLuBian / JianZhu 实体', () async {
      final dir = Directory.systemTemp.createTempSync('ovimap_b20_inject');
      PathProviderPlatform.instance = FakePathProvider(dir.path);
      addTearDown(() => dir.deleteSync(recursive: true));

      final r = await DxfExporter.export(
        name: '注入路径',
        labels: _labels(),
        includeSurroundings: true,
        rangeM: 300,
        basemap: buildSyntheticBasemap(),
        version: DxfVersion.r2000,
      );
      final text = latin1.decode(r.file.readAsBytesSync());
      expect(_entitiesOnLayer(text, 'DaoLuBian'), greaterThan(0),
          reason: '道路矢量（DaoLuBian 层）必须有实体');
      expect(_entitiesOnLayer(text, 'JianZhu'), greaterThan(0),
          reason: '建筑轮廓（JianZhu 层）必须有实体');
    });

    test('路径②：fetchFor 缓存命中 → roads/buildings 正常产出（cached）', () async {
      final dir = Directory.systemTemp.createTempSync('ovimap_b20_cache');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cache = BasemapCache(dir);
      final bbox = BasemapFetcher.boundsOf(_labels(), 300);
      // 预置一条覆盖请求 bbox 的更大范围缓存
      await cache.write('roads',
          [bbox[0] - 0.01, bbox[1] - 0.01, bbox[2] + 0.01, bbox[3] + 0.01],
          _roadsJson());
      await cache.write('buildings',
          [bbox[0] - 0.01, bbox[1] - 0.01, bbox[2] + 0.01, bbox[3] + 0.01],
          _buildingsJson());
      await cache.write('places',
          [bbox[0] - 0.01, bbox[1] - 0.01, bbox[2] + 0.01, bbox[3] + 0.01],
          _emptyJson);

      final data = await BasemapFetcher.fetchFor(_labels(),
          rangeM: 300, cache: cache);
      expect(data.roads.length, 2, reason: '缓存道路应被解析出来');
      expect(data.buildings.length, 2, reason: '缓存建筑应被解析出来');
      expect(data.report.roads.state, FetchState.cached);
      expect(data.report.buildings.state, FetchState.cached);
      expect(data.report.hasVector, isTrue);
      expect(data.report.summaryLine, contains('道路 2 项'));
      expect(data.report.summaryLine, contains('建筑 2 项'));
    });

    test('路径③：抓取（mock Overpass）→ DXF 出 DaoLuBian / JianZhu 实体', () async {
      final dir = Directory.systemTemp.createTempSync('ovimap_b20_fetch');
      PathProviderPlatform.instance = FakePathProvider(dir.path);
      addTearDown(() => dir.deleteSync(recursive: true));
      _mockOverpass();

      final data = await BasemapFetcher.fetchFor(_labels(), rangeM: 300);
      expect(data.report.roads.state, FetchState.ok);
      expect(data.report.buildings.state, FetchState.ok);
      expect(data.roads.length, 2);
      expect(data.buildings.length, 2);

      // 同一个 bbox 二次导出应命中缓存，仍出实体
      final r = await DxfExporter.export(
        name: '抓取路径',
        labels: _labels(),
        includeSurroundings: true,
        rangeM: 300,
        version: DxfVersion.r2000,
      );
      final text = latin1.decode(r.file.readAsBytesSync());
      expect(_entitiesOnLayer(text, 'DaoLuBian'), greaterThan(0));
      expect(_entitiesOnLayer(text, 'JianZhu'), greaterThan(0));
    });

    test('R1-3 抓取结果可见：失败项带原因、汇总与状态行齐全', () {
      const report = BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, source: 'overpass', count: 128),
        buildings:
            DatasetReport(FetchState.failed, error: 'overpass 所有端点均失败'),
        places: DatasetReport(FetchState.cached,
            source: 'cache', count: 12, error: '网络超时'),
      );
      expect(report.summaryLine, '道路 128 项 / 建筑 0 项 / 地名 12 项');
      expect(report.hasVector, isTrue);
      final lines = report.statusLines();
      expect(lines, hasLength(3));
      expect(lines[0], '道路 128 项');
      expect(lines[1], contains('建筑 未获取'));
      expect(lines[1], contains('所有端点均失败'));
      expect(lines[2], contains('缓存'));
      expect(lines[2], contains('网络超时'));
      // 既有 toWarnings 语义不变
      expect(report.toWarnings().any((s) => s.contains('刷新底图')), isTrue);
    });
  });

  // ============ R1-2：抓取可靠性 ============

  group('R1-2 Overpass 端点与重试', () {
    test('端点列表：空壳/已死端点全部下线，保留实测能返回真实数据的镜像', () {
      final eps = OverpassEndpoints.builtin();
      expect(eps.length, greaterThanOrEqualTo(5));
      // 保留：实测 elements > 0 的可用镜像
      expect(eps.any((e) => e.contains('overpass-api.de')), isTrue);
      expect(eps.any((e) => e.contains('maps.mail.ru')), isTrue);
      expect(eps.any((e) => e.contains('overpass.openstreetmap.fr')), isTrue);
      expect(eps.any((e) => e.contains('z.overpass-api.de')), isTrue);
      // 下线：空壳（200 最快但恒 elements=[]）/ 已死 / 长期超时，一个都不许回来
      for (final bad in OverpassEndpoints.retired) {
        expect(eps, isNot(contains(bad)), reason: '$bad 已下线，不得再参与抓取');
      }
      expect(eps, isNot(contains(OverpassEndpoints.retiredOsmCh)),
          reason: 'osm.ch 是空壳镜像（抢答致 0 道路/0 建筑），必须移除');
      expect(eps, isNot(contains(OverpassEndpoints.retiredOsmRu)));
      expect(eps, isNot(contains(OverpassEndpoints.retiredOsmJp)));
      expect(eps, isNot(contains(OverpassEndpoints.retiredPrivateCoffee)));
      // 自定义并入去重仍然有效
      final resolved = OverpassEndpoints.resolve('https://x.example/api\n'
          'https://x.example/api');
      expect(resolved.where((e) => e == 'https://x.example/api').length, 1);
    });

    test('P0：空 elements 的「空壳镜像」不得赢下竞速（慢但真实的端点胜出）', () async {
      // 复刻 QA 实测：osm.ch 0.05s 返回 {"elements":[]}，真实镜像 300ms 后有数据
      OverpassClient.httpGetOverride = (url, {headers}) async {
        if (url.host == 'empty.example') {
          return _ok(emptyElementsJson); // 最快，但空
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return _ok(_roadsJson());
      };
      final sw = Stopwatch()..start();
      final body = await OverpassClient.fetchRaw('[out:json];',
          endpoints: const [
            'https://empty.example/api/interpreter',
            'https://real.example/api/interpreter',
          ],
          timeout: const Duration(seconds: 3));
      sw.stop();
      expect(body, _roadsJson(), reason: '空答案不得抢答，必须等有数据的端点');
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(250));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('P0：全部端点都返回空 elements → 才用空答案收场（ok + 0 项）', () async {
      OverpassClient.httpGetOverride =
          (url, {headers}) async => _ok(emptyElementsJson);
      final body = await OverpassClient.fetchRaw('[out:json];',
          endpoints: const [
            'https://a.example/api/interpreter',
            'https://b.example/api/interpreter',
          ],
          timeout: const Duration(milliseconds: 300));
      expect(body, emptyElementsJson);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('O1：4 端点硬失败 + 1 端点空答案 → 触发（且只触发一轮）重试并拿到数据',
        () async {
      final eps = const [
        'https://f1.example/api',
        'https://f2.example/api',
        'https://f3.example/api',
        'https://f4.example/api',
        'https://empty.example/api', // 唯一"答上来"的端点：第一轮给空，第二轮给真数据
      ];
      var calls = 0;
      var round = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        if (url.host.startsWith('f')) {
          throw const HttpException('mock 504');
        }
        round = calls; // 记录该空端点的调用序号
        if (calls <= 5) return _ok(emptyElementsJson); // 第一轮：空
        return _ok(_roadsJson()); // 重试轮：真数据
      };
      final sw = Stopwatch()..start();
      final r = await OverpassClient.fetchRawDetailed('[out:json];',
          endpoints: eps, timeout: const Duration(milliseconds: 300));
      sw.stop();
      expect(calls, eps.length * 2,
          reason: '硬失败 + 空答案收场 → 必须再抢一轮（2 × 端点数）');
      expect(round, greaterThan(5));
      expect(r.body, _roadsJson(), reason: '重试轮应拿到真实数据');
      expect(r.emptyFallback, isFalse);
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(1000),
          reason: '确实走了 1.2s 重试间隔（说明真重试了，不是直接返回）');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('O1：全部端点都返回 200 空 → **绝不**重试（wall-clock 卡死防 72s 劣化）',
        () async {
      final eps = const [
        'https://a.example/api',
        'https://b.example/api',
        'https://c.example/api',
        'https://d.example/api',
        'https://e.example/api',
      ];
      var calls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        return _ok(emptyElementsJson);
      };
      final sw = Stopwatch()..start();
      final r = await OverpassClient.fetchRawDetailed('[out:json];',
          endpoints: eps,
          timeout: const Duration(milliseconds: 300),
          retries: 1);
      sw.stop();
      expect(calls, eps.length, reason: '全是 200 空 = 真没数据，一轮就够');
      expect(r.emptyFallback, isTrue);
      expect(r.hardFailures, 0);
      expect(sw.elapsedMilliseconds, lessThan(1000),
          reason: '不得白等 1.2s 重试间隔（实测 ${sw.elapsedMilliseconds}ms）');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('O1：全硬失败（无空答案）→ 仍按既有策略重试一轮并抛异常', () async {
      final eps = const [
        'https://a.example/api',
        'https://b.example/api',
        'https://c.example/api',
      ];
      var calls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        throw const HttpException('mock 全灭');
      };
      await expectLater(
          OverpassClient.fetchRawDetailed('[out:json];',
              endpoints: eps, timeout: const Duration(milliseconds: 200)),
          throwsA(isA<HttpException>()));
      expect(calls, eps.length * 2);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('O1：重试轮同样空 + 仍有硬失败 → 不再无限重试，返回空答案', () async {
      final eps = const [
        'https://f1.example/api',
        'https://empty.example/api',
      ];
      var calls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        if (url.host.startsWith('f')) throw const HttpException('mock 504');
        return _ok(emptyElementsJson);
      };
      final r = await OverpassClient.fetchRawDetailed('[out:json];',
          endpoints: eps, timeout: const Duration(milliseconds: 200));
      expect(calls, 4, reason: '首轮 + 重试轮各 2 次，之后必须收敛');
      expect(r.emptyFallback, isTrue);
      expect(r.hardFailures, greaterThan(0));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('P0：美化的空 elements 排版（多行空白）也能识别为空答案', () {
      expect(OverpassClient.hasEmptyElements('{"elements": []}'), isTrue);
      expect(OverpassClient.hasEmptyElements('{"elements":[\n\n]}'), isTrue);
      expect(OverpassClient.hasEmptyElements('{"elements" : [ ]}'), isTrue);
      expect(
          OverpassClient.hasEmptyElements(
              '{"elements":[{"type":"way"}]}'),
          isFalse);
      expect(OverpassClient.hasEmptyElements(_roadsJson()), isFalse);
    });

    test('P0：fetchFor 端到端——真实端点列表下，空壳抢答不再导致 0 道路/0 建筑',
        () async {
      final dir = Directory.systemTemp.createTempSync('ovimap_b20_shell');
      addTearDown(() => dir.deleteSync(recursive: true));
      // 复刻 QA 实测时序：多数镜像立刻返回空 elements，只有一个镜像 250ms 后给真数据。
      // 修复前：空 answers 立刻 complete → 0 条；修复后：空答案不赢，等真数据。
      OverpassClient.httpGetOverride = (url, {headers}) async {
        if (!url.host.contains('kumi')) return _ok(emptyElementsJson);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final data = url.queryParameters['data'] ?? '';
        return _ok(data.contains('"building"') ? _buildingsJson() : _roadsJson());
      };
      final data = await BasemapFetcher.fetchFor(_labels(),
          rangeM: 300, cache: BasemapCache(dir));
      expect(data.roads.length, 2, reason: '真实端点必须赢过空壳答案');
      expect(data.buildings.length, 2, reason: '真实端点必须赢过空壳答案');
      expect(data.report.roads.state, FetchState.ok);
      expect(data.report.anyEmptyAnswer, isFalse,
          reason: '最终采用真数据时不得标记 emptyAnswer');
      expect(data.report.hasVector, isTrue);
      expect(data.report.summaryLine, '道路 2 项 / 建筑 2 项 / 地名 0 项');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('P1：count=0 且 emptyAnswer → 状态行不再谎称"该范围内无数据"', () {
      const emptyRep = BasemapFetchReport(
        roads: DatasetReport(FetchState.ok,
            source: 'overpass', count: 0, emptyAnswer: true),
        buildings: DatasetReport(FetchState.ok,
            source: 'overpass', count: 0, emptyAnswer: true),
        places: DatasetReport(FetchState.ok, source: 'overpass', count: 0),
      );
      final lines = emptyRep.statusLines();
      expect(lines[0], contains('数据源返回空'));
      expect(lines[0], contains('疑似底图镜像故障'));
      expect(lines[0], isNot(contains('该范围内无数据')),
          reason: '不得把镜像故障误导成用户的范围问题');
      expect(emptyRep.anyEmptyAnswer, isTrue);
      expect(emptyRep.hasVector, isFalse);
      // toWarnings 同步修正
      expect(emptyRep.toWarnings().any((s) => s.contains('数据源返回空')), isTrue);

      // 对照：真的无病变范围空（农业生产区）仍走原文案
      const noDataRep = BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, source: 'overpass', count: 0),
        buildings: DatasetReport(FetchState.ok, source: 'overpass', count: 0),
        places: DatasetReport(FetchState.ok, source: 'overpass', count: 0),
      );
      expect(noDataRep.statusLines()[0], contains('该范围内无数据'));
      expect(noDataRep.anyEmptyAnswer, isFalse);
    });

    test('竞速：首个成功即返回，失败端点不阻塞', () async {
      OverpassClient.httpGetOverride = (url, {headers}) async {
        if (url.host.contains('kumi')) {
          return _ok('', status: 500); // 明确失败
        }
        return _ok(_roadsJson(), status: 200);
      };
      final body = await OverpassClient.fetchRaw('[out:json];');
      expect(body, _roadsJson());
    });

    test('单端点超时不拖累：慢端点挂住，快端点仍及时返回', () async {
      OverpassClient.httpGetOverride = (url, {headers}) async {
        if (url.host.contains('kumi')) {
          // 永不返回：模拟不可达镜像（由 .timeout 放弃）
          return Completer<http.Response>().future;
        }
        return _ok(_roadsJson(), status: 200);
      };
      final sw = Stopwatch()..start();
      final body = await OverpassClient.fetchRaw('[out:json];',
          timeout: const Duration(milliseconds: 300));
      sw.stop();
      expect(body, _roadsJson());
      expect(sw.elapsedMilliseconds, lessThan(3000),
          reason: '不得被挂住的端点拖到超时');
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('全端点失败 → 整轮重试 1 次（2 端点 × 2 轮 = 4 次）后判失败', () async {
      var calls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        throw const HttpException('mock 全灭');
      };
      await expectLater(
          OverpassClient.fetchRaw('[out:json];',
              endpoints: const ['https://a.example/api', 'https://b.example/api'],
              timeout: const Duration(milliseconds: 200)),
          throwsA(isA<HttpException>()));
      expect(calls, 4, reason: '首轮 2 次全灭后应再重试一轮');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('首轮全灭、重试轮成功 → 返回内容（不再"导不出"）', () async {
      var calls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        if (calls <= 2) throw const HttpException('mock 首轮全灭');
        return _ok(_roadsJson(), status: 200);
      };
      final body = await OverpassClient.fetchRaw('[out:json];',
          endpoints: const ['https://a.example/api', 'https://b.example/api'],
          timeout: const Duration(milliseconds: 200));
      expect(body, _roadsJson());
      expect(calls, greaterThan(2));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('O1①：4 端点硬失败 + 1 端点空答案 → 必须触发重试且能拿到数据', () async {
      final eps = const [
        'https://f1.example/api',
        'https://f2.example/api',
        'https://f3.example/api',
        'https://f4.example/api',
        'https://empty.example/api', // 唯一能答的：第一轮给空，第二轮给真数据
      ];
      var calls = 0;
      var emptyCalls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        if (url.host.startsWith('f')) {
          throw const HttpException('实测：504 / 连接失败');
        }
        emptyCalls++;
        // 第一轮只回空壳；重试轮才回真数据（模拟"镜像刚缓过来"）
        return _ok(emptyCalls == 1 ? emptyElementsJson : _roadsJson());
      };
      final body = await OverpassClient.fetchRaw('[out:json];',
          endpoints: eps, timeout: const Duration(milliseconds: 300));
      expect(calls, eps.length * 2,
          reason: '有硬失败 + 空答案收场 = 值得再抢一轮（2 × 端点数）');
      expect(body, _roadsJson(), reason: '重试轮必须把真数据抢回来');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('O1②：5 端点全部 200 空（真·无数据）→ 不重试，不白等', () async {
      final eps = const [
        'https://a.example/api',
        'https://b.example/api',
        'https://c.example/api',
        'https://d.example/api',
        'https://e.example/api',
      ];
      var calls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        return _ok(emptyElementsJson);
      };
      final sw = Stopwatch()..start();
      final body = await OverpassClient.fetchRaw('[out:json];',
          endpoints: eps, timeout: const Duration(milliseconds: 300));
      sw.stop();
      expect(calls, eps.length,
          reason: '全部 200 空 = 该范围确实无数据，重试只是白等');
      expect(body, emptyElementsJson);
      expect(sw.elapsedMilliseconds, lessThan(1000),
          reason: '不得白等 1.2s 重试延迟（实测 ${sw.elapsedMilliseconds}ms）');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('O1③：全端点硬失败 → 仍按既有策略重试（调用数 = 2 × 端点数）', () async {
      final eps = const [
        'https://a.example/api',
        'https://b.example/api',
        'https://c.example/api',
        'https://d.example/api',
        'https://e.example/api',
      ];
      var calls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        throw const HttpException('mock 全灭');
      };
      await expectLater(
          OverpassClient.fetchRaw('[out:json];',
              endpoints: eps, timeout: const Duration(milliseconds: 200)),
          throwsA(isA<HttpException>()));
      expect(calls, eps.length * 2, reason: '硬失败路径的重试策略不得被破坏');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('200 但非数据应答（无 elements / html 错误页）不得赢下竞速', () async {
      // 形态①：错误页 / 限流提示（旧用例，保留）
      OverpassClient.httpGetOverride =
          (url, {headers}) async => _ok('<html>rate limited</html>');
      await expectLater(
          OverpassClient.fetchRaw('[out:json];',
              endpoints: const ['https://a.example/api'],
              timeout: const Duration(milliseconds: 200)),
          throwsA(isA<HttpException>()));
      // 形态②：JSON 但没有 elements 字段（如 {"foo":1} / {"remark":"..."}）
      OverpassClient.httpGetOverride =
          (url, {headers}) async => _ok('{"foo":1}');
      await expectLater(
          OverpassClient.fetchRaw('[out:json];',
              endpoints: const ['https://a.example/api'],
              timeout: const Duration(milliseconds: 200)),
          throwsA(isA<HttpException>()));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('空结果不落缓存（避免"空壳 200"把底图永久毒化）', () async {
      final dir = Directory.systemTemp.createTempSync('ovimap_b20_empty');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cache = BasemapCache(dir);
      var calls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        return _ok(_emptyJson);
      };
      final bbox = BasemapFetcher.boundsOf(_labels(), 300);
      final d1 = await BasemapFetcher.fetchFor(_labels(),
          rangeM: 300, cache: cache);
      expect(d1.roads, isEmpty);
      expect(d1.report.roads.state, FetchState.ok);
      expect(d1.report.anyEmptyAnswer, isTrue,
          reason: '全端点返回空时必须标记 emptyAnswer，UI 才能提示重试而非"范围无数据"');
      expect(d1.report.statusLines().first, contains('数据源返回空'));
      expect(await cache.read('roads', bbox), isNull,
          reason: '空结果不得写入近乎永久的项目级缓存');
      final d2 = await BasemapFetcher.fetchFor(_labels(),
          rangeM: 300, cache: cache);
      expect(d2.roads, isEmpty);
      expect(calls, greaterThan(6), reason: '第二次应重新联网抓取，而非命中空缓存');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('fetchFor：抓取全失败且无缓存 → failed 且带原因（不静默空）', () async {
      final dir = Directory.systemTemp.createTempSync('ovimap_b20_fail');
      addTearDown(() => dir.deleteSync(recursive: true));
      OverpassClient.httpGetOverride = (url, {headers}) async {
        throw const HttpException('mock 不可达');
      };
      final data = await BasemapFetcher.fetchFor(_labels(),
          rangeM: 300, cache: BasemapCache(dir));
      expect(data.report.roads.state, FetchState.failed);
      expect(data.report.buildings.state, FetchState.failed);
      expect(data.report.hasVector, isFalse);
      expect(data.report.statusLines().first, contains('未获取'));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ============ R2：高德解析 ============

  group('R2 高德解析与参数', () {
    test('parseLocation："lng,lat" → [lat, lon]', () {
      expect(AmapClient.parseLocation('114.080000,32.100000'), [32.1, 114.08]);
      expect(AmapClient.parseLocation(''), isNull);
      expect(AmapClient.parseLocation('abc'), isNull);
      expect(AmapClient.parseLocation('114.08'), isNull);
    });

    test('关键词搜索：sortrule=distance + location=lng,lat + key 传入', () async {
      final uris = <Uri>[];
      AmapClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return _ok(jsonEncode({
          'status': '1',
          'info': 'OK',
          'infocode': '10000',
          'pois': [
            {
              'name': '李庄小区',
              'address': '信阳市',
              'location': '114.080000,32.100000'
            }
          ],
        }), status: 200);
      };
      final res = await AmapClient.search('李庄', 'AMAP_KEY',
          region: '信阳', cityLimit: true, nearLat: 32.1, nearLon: 114.08);
      expect(uris, hasLength(1));
      expect(uris[0].host, 'restapi.amap.com');
      expect(uris[0].path, '/v5/place/text');
      expect(uris[0].queryParameters['key'], 'AMAP_KEY');
      expect(uris[0].queryParameters['keywords'], '李庄');
      expect(uris[0].queryParameters['region'], '信阳');
      expect(uris[0].queryParameters['city_limit'], 'true');
      expect(uris[0].queryParameters['sortrule'], 'distance');
      final loc = uris[0].queryParameters['location']!.split(',');
      // 基准点已正向加密为 GCJ-02（偏移 ≤ 约 1km），故用 0.02° 容差
      expect(double.parse(loc[0]), closeTo(114.08, 0.02)); // 经度在前
      expect(double.parse(loc[1]), closeTo(32.1, 0.02)); // 纬度在后
      expect(res.first.name, '李庄小区');
    });

    test('GCJ-02 → WGS-84：返回坐标纠偏（与 tianditu 同口径）', () async {
      const wgsLat = 32.1, wgsLon = 114.08;
      final gcj = Gcj02Converter.wgs84ToGcj02(wgsLat, wgsLon);
      AmapClient.httpGetOverride = (uri) async => _ok(jsonEncode({
            'status': '1',
            'info': 'OK',
            'infocode': '10000',
            'pois': [
              {
                'name': '纠偏点',
                'address': '',
                'location': '${gcj[1]},${gcj[0]}'
              }
            ],
          }), status: 200);
      final res = await AmapClient.poiInBounds(
          [32.0, 114.0, 32.2, 114.2], '小区', 'K');
      expect(res, hasLength(1));
      expect(res.first.lat, closeTo(wgsLat, 1e-4));
      expect(res.first.lon, closeTo(wgsLon, 1e-4));

      // 关闭纠偏 → 原样返回 GCJ 坐标
      AmapClient.httpGetOverride = (uri) async => _ok(jsonEncode({
            'status': '1',
            'info': 'OK',
            'infocode': '10000',
            'pois': [
              {'name': '原样点', 'address': '', 'location': '${gcj[1]},${gcj[0]}'}
            ],
          }), status: 200);
      final raw = await AmapClient.poiInBounds(
          [32.0, 114.0, 32.2, 114.2], '小区', 'K',
          convertGcj: false);
      expect(raw.first.lat, closeTo(gcj[0], 1e-9));
    });

    test('矩形搜索：polygon = 左下|右上（lng,lat），keywords/page_size 传入',
        () async {
      final uris = <Uri>[];
      AmapClient.httpGetOverride = (uri) async {
        uris.add(uri);
        return _ok(jsonEncode({
          'status': '1',
          'info': 'OK',
          'infocode': '10000',
          'pois': [],
        }), status: 200);
      };
      // 本用例只验参数顺序/格式；坐标转换另有用例覆盖 → 关闭纠偏，断言原 WGS 值。
      await AmapClient.poiInBounds([32.0, 114.0, 32.3, 114.4], '小区', 'K',
          convertGcj: false);
      expect(uris[0].path, '/v5/place/polygon');
      final poly = uris[0].queryParameters['polygon']!;
      final pts = poly.split('|');
      expect(pts, hasLength(2));
      expect(pts[0].split(',').first, '114.0'); // 左下经
      expect(pts[0].split(',').last, '32.0'); // 左下纬
      expect(pts[1].split(',').first, '114.4'); // 右上经
      expect(pts[1].split(',').last, '32.3'); // 右上纬
      expect(uris[0].queryParameters['keywords'], '小区');
      expect(uris[0].queryParameters['page_size'], '20');
    });

    test('无效 key（INVALID_USER_KEY）→ 抛异常，绝不静默返回空', () async {
      AmapClient.httpGetOverride = (uri) async => _ok(jsonEncode({
            'status': '0',
            'info': 'INVALID_USER_KEY',
            'infocode': '10001',
          }), status: 200);
      await expectLater(AmapClient.search('x', 'bad'),
          throwsA(isA<Exception>()));
      AmapClient.httpGetOverride = (uri) async => _ok('err', status: 500);
      await expectLater(AmapClient.search('x', 'k'), throwsA(isA<Exception>()));
    });
  });

  // ============ R2：搜索源优先级与降级 ============

  group('R2 搜索源优先级（高德 > 天地图 > Nominatim > Photon）', () {
    test('配置了高德 key → 只用高德（天地图不被调用）', () async {
      var tdtCalls = 0;
      AmapClient.httpGetOverride = (uri) async => _ok(jsonEncode({
            'status': '1',
            'info': 'OK',
            'infocode': '10000',
            'pois': [
              {'name': '高德小区', 'address': 'a', 'location': '114.0801,32.1001'}
            ],
          }), status: 200);
      TiandituClient.httpGetOverride = (uri) async {
        tdtCalls++;
        return _ok('{}', status: 200);
      };
      final res = await SearchService.search('李庄',
          amapKey: 'A', tdtKey: 'T', nearLat: 32.1, nearLon: 114.08);
      expect(res, hasLength(1));
      expect(res.first.name, '高德小区');
      expect(tdtCalls, 0, reason: '高德命中即不再走天地图');
    });

    test('高德失败 → 自动降级天地图；高德返回空 → 同样降级', () async {
      // ① 高德抛异常
      AmapClient.httpGetOverride =
          (uri) async => throw const HttpException('amap down');
      var tdtCalls = 0;
      TiandituClient.httpGetOverride = (uri) async {
        tdtCalls++;
        return _ok(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [
            {'name': '天地图小区', 'address': '', 'lonlat': '114.0800,32.1000'}
          ],
          'area': null,
        }), status: 200);
      };
      var res = await SearchService.search('李庄',
          amapKey: 'A', tdtKey: 'T', nearLat: 32.1, nearLon: 114.08);
      expect(tdtCalls, greaterThan(0));
      expect(res.any((r) => r.name == '天地图小区'), isTrue);

      // ② 高德返回空数组 → 也降级
      tdtCalls = 0;
      AmapClient.httpGetOverride = (uri) async => _ok(jsonEncode({
            'status': '1',
            'info': 'OK',
            'infocode': '10000',
            'pois': [],
          }), status: 200);
      res = await SearchService.search('李庄',
          amapKey: 'A', tdtKey: 'T', nearLat: 32.1, nearLon: 114.08);
      expect(tdtCalls, greaterThan(0));
      expect(res.any((r) => r.name == '天地图小区'), isTrue);
    });

    test('未配置高德 key → 行为与旧版一致（仍走天地图）', () async {
      var tdtCalls = 0;
      AmapClient.httpGetOverride = (uri) async {
        throw StateError('未配置高德 key 时不应调用高德');
      };
      TiandituClient.httpGetOverride = (uri) async {
        tdtCalls++;
        return _ok(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [
            {'name': '天地图小区', 'address': '', 'lonlat': '114.0800,32.1000'}
          ],
          'area': null,
        }), status: 200);
      };
      final res = await SearchService.search('李庄',
          tdtKey: 'T', nearLat: 32.1, nearLon: 114.08);
      expect(tdtCalls, greaterThan(0));
      expect(res.first.name, '天地图小区');
    });

    test('结果按距基准点升序（高德 sortrule + 本地 sortByDistance 双保险）',
        () async {
      final near = Gcj02Converter.wgs84ToGcj02(32.1, 114.08);
      String locOf(double lat, double lon) {
        final g = Gcj02Converter.wgs84ToGcj02(lat, lon);
        return '${g[1]},${g[0]}';
      }

      AmapClient.httpGetOverride = (uri) async => _ok(jsonEncode({
            'status': '1',
            'info': 'OK',
            'infocode': '10000',
            'pois': [
              // 故意倒序返回：远 → 近
              {'name': '远', 'address': '', 'location': locOf(32.30, 114.28)},
              {'name': '近', 'address': '', 'location': locOf(32.101, 114.081)},
              {'name': '中', 'address': '', 'location': locOf(32.15, 114.12)},
            ],
          }), status: 200);
      final res = await SearchService.search('x',
          amapKey: 'A', nearLat: near[0], nearLon: near[1]);
      expect(res.map((r) => r.name).toList(), ['近', '中', '远']);
    });
  });

  // ============ R2：DXF 地名兜底高德优先 ============

  group('R2 DXF 地名兜底：高德优先、回落天地图', () {
    Future<BasemapData> fetchWith({
      required String amapKey,
      required String tdtKey,
    }) async {
      final dir = Directory.systemTemp.createTempSync('ovimap_b20_poi');
      addTearDown(() => dir.deleteSync(recursive: true));
      _mockOverpass(); // OSM 三数据集：道路/建筑有数据，地名为空
      // 兜底 mock 坐标按 WGS 意图给（"线路旁的地名"），关闭纠偏以免被当作
      // GCJ-02 再纠偏后偏移 ~600m 误落 bbox 外（本组只测源优先级/降级）。
      return BasemapFetcher.fetchFor(_labels(),
          rangeM: 300,
          amapKey: amapKey,
          tdtKey: tdtKey,
          convertGcj: false,
          cache: BasemapCache(dir));
    }

    test('配了高德 key → 兜底走高德（source 记 +amap，天地图不调用）', () async {
      var tdtCalls = 0;
      AmapClient.httpGetOverride = (uri) async => _ok(jsonEncode({
            'status': '1',
            'info': 'OK',
            'infocode': '10000',
            'pois': [
              {'name': '高德花园', 'address': '', 'location': '114.0915,32.1266'}
            ],
          }), status: 200);
      TiandituClient.httpGetOverride = (uri) async {
        tdtCalls++;
        return _ok('{}', status: 200);
      };
      final data = await fetchWith(
          amapKey: 'A', tdtKey: 'T'
);
      expect(tdtCalls, 0);
      expect(data.places.any((p) => p.name == '高德花园'), isTrue);
      expect(data.report.places.source, contains('+amap'));
    });

    test('未配高德 key → 仍走天地图（行为与第十九批一致）', () async {
      var tdtCalls = 0;
      AmapClient.httpGetOverride =
          (uri) async => throw StateError('未配 key 不应调用高德');
      TiandituClient.httpGetOverride = (uri) async {
        tdtCalls++;
        return _ok(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [
            {'name': '天地图花园', 'address': '', 'lonlat': '114.0915,32.1266'}
          ],
          'area': null,
        }), status: 200);
      };
      final data = await fetchWith(
          amapKey: '', tdtKey: 'T'
);
      expect(tdtCalls, greaterThan(0));
      expect(data.places.any((p) => p.name == '天地图花园'), isTrue);
      expect(data.report.places.source, contains('+tdt'));
    });

    test('高德失败/无结果 → 自动回落天地图', () async {
      var tdtCalls = 0;
      AmapClient.httpGetOverride =
          (uri) async => throw const HttpException('amap down');
      TiandituClient.httpGetOverride = (uri) async {
        tdtCalls++;
        return _ok(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': '成功'},
          'pois': [
            {'name': '回落小区', 'address': '', 'lonlat': '114.0915,32.1266'}
          ],
          'area': null,
        }), status: 200);
      };
      final data = await fetchWith(
          amapKey: 'A', tdtKey: 'T'
);
      expect(tdtCalls, greaterThan(0));
      expect(data.places.any((p) => p.name == '回落小区'), isTrue);
      expect(data.report.places.source, contains('+tdt'));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ============ R2：设置项持久化 ============

  group('R2 高德 Key 设置项', () {
    test('默认回退内置 key（开箱即用）；可保存 / 清空并持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
      // 第二十一批：高德内置 key，未配置时 AppState.amapKey 回退内置值（开箱即用）。
      expect(st.userAmapKey, '', reason: '用户未显式配置时原始值为空');
      expect(st.amapKey, AppState.builtinAmapKey,
          reason: '未配置即回退内置高德 key');

      st.setAmapKey('my-amap-key');
      expect(st.amapKey, 'my-amap-key');
      expect(st.prefs.getString(AppState.prefAmapKey), 'my-amap-key');

      st.setAmapKey('  trimmed  ');
      expect(st.amapKey, 'trimmed');

      st.setAmapKey('');
      expect(st.userAmapKey, '', reason: '清空后用户原始值为空');
      expect(st.amapKey, AppState.builtinAmapKey,
          reason: '清空后恢复使用内置高德 key');
      expect(st.prefs.getString(AppState.prefAmapKey), '');
    });

    test('天地图既有设置项不受影响（回归）', () async {
      SharedPreferences.setMockInitialValues({});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
      expect(st.tdtCoordSys, AppState.tdtCoordGcj02);
      expect(st.tdtConvertGcj, isTrue);
      st.setTdtCoordSys(AppState.tdtCoordWgs84);
      expect(st.tdtConvertGcj, isFalse);
      expect(st.tiandituKey, AppState.builtinTdtKey);
    });
  });

  // ============ 接线断言 ============

  group('R2 接线（源级断言）', () {
    test('home_page：搜索传入高德 key（高德优先）', () async {
      final src = await File('lib/ui/home_page.dart').readAsString();
      expect(src.contains('amapKey: st.amapKey'), isTrue);
      expect(src.contains('convertGcj: st.tdtConvertGcj'), isTrue);
    });

    test('dialogs / settings：高德 Key 设置入口与导出链路接线', () async {
      final dlg = await File('lib/ui/dialogs.dart').readAsString();
      expect(dlg.contains('showAmapKeyDialog'), isTrue);
      expect(dlg.contains('amapKey: amapKey'), isTrue);
      expect(dlg.contains('BasemapFetcher.fetchFor'), isTrue,
          reason: 'DXF 导出前应提供底图检测结果');
      final menu = await File('lib/ui/settings_menu.dart').readAsString();
      expect(menu.contains('高德 Key 设置'), isTrue);
      final dxf = await File('lib/export/dxf.dart').readAsString();
      expect(dxf.contains('String amapKey = \'\''), isTrue);
      expect(dxf.contains('amapKey: amapKey'), isTrue);
      final state = await File('lib/state/app_state.dart').readAsString();
      expect(state.contains("static const prefAmapKey = 'amapKey'"), isTrue);
    });
  });
}
