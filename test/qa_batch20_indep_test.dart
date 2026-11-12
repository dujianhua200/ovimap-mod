// QA 独立验证（第二十批）：底图可靠性 + 高德接入。
//
// **独立性说明**：本文件由 QA 独立编写，**不复用** batch20_test.dart 的 fixture
// 或任何既有 helper。所有 mock 数据、标量、GCJ 参考实现均在本文件内自造，
// 目的是对工程师自测做交叉验证，而非复述。
//
// 覆盖：
//  B 空结果不落缓存（含**真实 osm.ch 空壳应答**回归）
//  C 端点清单与重试策略
//  D 建筑/道路端到端三路径 + 全失败降级
//  E 高德接入（解析 / GCJ 纠偏 / 失败降级 / 优先级 / 未配 key 回归 / polygon 顺序）
//  F 红线（语义未被放宽）
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/export/overpass.dart';
import 'package:ovimap/geo/gcj02.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/amap.dart';
import 'package:ovimap/services/search.dart';
import 'package:ovimap/services/tianditu.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class QaPathProvider extends PathProviderPlatform {
  final String root;
  QaPathProvider(this.root);
  @override
  Future<String?> getExternalStoragePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

http.Response qaOk(String body, {int status = 200}) => http.Response(
      body, status,
      headers: const {'content-type': 'application/json; charset=utf-8'});

// ============================ QA 自造 fixture ============================

// 真实的一次 overpass.osm.ch 应答（QA 于本机实测抓取，2026-09-13）：
// HTTP 200 / 268 字节 / 含 `"elements"` 但元素数组为空 /
// `timestamp_osm_base` 为异常的 "34"。
// **这是第二十批「空壳 200 闸门」按 `contains('"elements"')` 判定的漏网形态。**
const String qaOsmChEmptyBody = '{\n'
    '  "version": 0.6,\n'
    '  "generator": "Overpass API 0.7.62.4 2390de5a",\n'
    '  "osm3s": {\n'
    '    "timestamp_osm_base": "34",\n'
    '    "copyright": "The data included in this document is from '
    'www.openstreetmap.org. The data is made available under ODbL."\n'
    '  },\n'
    '  "elements": [\n\n\n  ]\n'
    '}\n';

// 合法的「真的没有数据」应答（形状与空壳一致 —— 用于对照空洞不可区分性）。
const String qaLegitEmpty = '{"version":0.6,"elements":[]}';

// 非数据应答（错误页/限流提示）：不含 "elements"。
const String qaShellNoElements = '{"foo":1,"error":"rate limited"}';

// QA 自造：有数据的道路应答（2 条，均带 name 与几何）。
/// 周边要素（电力线 + 水系）——v3.9.4 新增抓取路的 fixture。
String qaExtrasJson() {
  return jsonEncode({
    'version': 0.6,
    'elements': [
      {
        'type': 'way',
        'id': 61,
        'tags': {'power': 'line'},
        'geometry': [
          {'lat': 32.1265, 'lon': 114.0914},
          {'lat': 32.1275, 'lon': 114.0924},
        ],
      },
      {
        'type': 'way',
        'id': 62,
        'tags': {'waterway': 'stream'},
        'geometry': [
          {'lat': 32.1266, 'lon': 114.0915},
          {'lat': 32.1276, 'lon': 114.0925},
        ],
      },
    ],
  });
}

String qaRoadsJson() {
  final road1 = [
    [32.1264, 114.0913],
    [32.1274, 114.0923],
    [32.1284, 114.0933],
  ];
  final road2 = [
    [32.1300, 114.0950],
    [32.1310, 114.0960],
  ];
  return jsonEncode({
    'version': 0.6,
    'elements': [
      {
        'type': 'way',
        'id': 1,
        'tags': {'highway': 'primary', 'name': '北京大街'},
        'geometry': [
          for (final p in road1) {'lat': p[0], 'lon': p[1]}
        ],
      },
      {
        'type': 'way',
        'id': 2,
        'tags': {'highway': 'residential', 'name': '解放路'},
        'geometry': [
          for (final p in road2) {'lat': p[0], 'lon': p[1]}
        ],
      },
    ],
  });
}

// QA 自造：有数据的建筑应答（1 个 way + 1 个 relation）。
String qaBuildingsJson() => jsonEncode({
      'version': 0.6,
      'elements': [
        {
          'type': 'way',
          'id': 11,
          'tags': {'building': 'yes', 'name': '李庄村委会'},
          'geometry': [
            {'lat': 32.1260, 'lon': 114.0900},
            {'lat': 32.1262, 'lon': 114.0900},
            {'lat': 32.1262, 'lon': 114.0903},
            {'lat': 32.1260, 'lon': 114.0903},
            {'lat': 32.1260, 'lon': 114.0900},
          ],
        },
        {
          'type': 'relation',
          'id': 12,
          'tags': {'building': 'yes', 'name': '丰乐园小区'},
          'members': [
            {
              'type': 'way',
              'role': 'outer',
              'geometry': [
                {'lat': 32.1280, 'lon': 114.0940},
                {'lat': 32.1285, 'lon': 114.0940},
              ],
            },
            {
              'type': 'way',
              'role': 'outer',
              'geometry': [
                {'lat': 32.1285, 'lon': 114.0940},
                {'lat': 32.1285, 'lon': 114.0947},
                {'lat': 32.1280, 'lon': 114.0947},
                {'lat': 32.1280, 'lon': 114.0940},
              ],
            },
          ],
        },
      ],
    });

// QA 自造：地名应答。
String qaPlacesJson() => jsonEncode({
      'version': 0.6,
      'elements': [
        {
          'type': 'node',
          'id': 21,
          // QA 注：必须落在 boundsOf(labels,300) 算出的 bbox 内，否则会被 crop
          // 裁空（→ 按"空结果不落缓存"规则不写盘），干扰缓存命中率的判定。
          'lat': 32.1290,
          'lon': 114.0940,
          'tags': {'place': 'village', 'name': '李庄村'},
        },
      ],
    });

List<MapLabel> qaLabels() => [
      MapLabel(typeId: 'pipe', seq: 1, lat: 32.1264, lon: 114.0913),
      MapLabel(typeId: 'pipe', seq: 2, lat: 32.1274, lon: 114.0923),
      MapLabel(typeId: 'pipe', seq: 3, lat: 32.1284, lon: 114.0933,
          lineGroupId: 'g1'),
    ];

/// DXF 文本中某图层上的实体数（组码 8 = 图层名）。
///
/// **注意**：产出文件为 **GBK 字节**，不能用 `readAsString`（默认 utf-8）解码。
/// 此处按 latin1 逐字节映射读取：ASCII 组码与图层名逐字节保真，
/// 中文写成乱码也不影响下面这只按 ASCII 图层名计数的断言。
int qaEntitiesOnLayer(String dxf, String layer) =>
    RegExp('8\n$layer\n').allMatches(dxf).length;

String qaReadDxfBytes(File f) => String.fromCharCodes(f.readAsBytesSync());

// ==================== QA 独立 GCJ-02 参考实现（交叉校验用） ====================
// 独立于 lib/geo/gcj02.dart 另写一遍标准算法，用于反验 SDK 的 GCJ→WGS 出口：
// 对 SDK 输出的 WGS 坐标再做**正向加密**，应还原 mock 里给出的原始 GCJ 坐标。

class QaGcjRef {
  static const double a = 6378245.0;
  static const double ee = 0.00669342162296594323;

  static double _tLat(double x, double y) {
    var r = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    r += (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) *
        2.0 /
        3.0;
    r += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) *
        2.0 /
        3.0;
    r += (160.0 * math.sin(y / 12.0 * math.pi) +
            320.0 * math.sin(y * math.pi / 30.0)) *
        2.0 /
        3.0;
    return r;
  }

  static double _tLon(double x, double y) {
    var r = 300.0 +
        x +
        2.0 * y +
        0.1 * x * x +
        0.1 * x * y +
        0.1 * math.sqrt(x.abs());
    r += (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) *
        2.0 /
        3.0;
    r += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) *
        2.0 /
        3.0;
    r += (150.0 * math.sin(x / 12.0 * math.pi) +
            300.0 * math.sin(x / 30.0 * math.pi)) *
        2.0 /
        3.0;
    return r;
  }

  /// WGS-84 → GCJ-02（正向加密），返回 [lat, lon]。
  static List<double> encrypt(double lat, double lon) {
    var dLat = _tLat(lon - 105.0, lat - 35.0);
    var dLon = _tLon(lon - 105.0, lat - 35.0);
    final radLat = lat / 180.0 * math.pi;
    var magic = math.sin(radLat);
    magic = 1 - ee * magic * magic;
    final sqrtMagic = math.sqrt(magic);
    dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * math.pi);
    dLon = (dLon * 180.0) / (a / sqrtMagic * math.cos(radLat) * math.pi);
    return [lat + dLat, lon + dLon];
  }
}

double qaDistM(double la1, double lo1, double la2, double lo2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(la2 - la1);
  final dLon = rad(lo2 - lo1);
  final t = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(la1)) *
          math.cos(rad(la2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return r * 2 * math.atan2(math.sqrt(t), math.sqrt(1 - t));
}

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

  // ======================= B：空结果不落缓存（核心） =======================

  group('B20-QA B1 合法空响应不得落缓存 + 不得被复用', () {
    test('所有端点返回 {"elements":[]} → 空底图、缓存不落盘、二次重抓', () async {
      final dir = Directory.systemTemp.createTempSync('qa20_b1_empty');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cache = BasemapCache(dir);
      var calls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        return qaOk(qaLegitEmpty);
      };

      final labels = qaLabels();
      final bbox = BasemapFetcher.boundsOf(labels, 300);

      final d1 = await BasemapFetcher.fetchFor(labels,
          rangeM: 300, cache: cache, useTdt: false);
      expect(d1.roads, isEmpty);
      expect(d1.buildings, isEmpty);
      expect(d1.places, isEmpty);
      expect(d1.report.hasVector, isFalse);

      // ② 缓存未落盘 / read 为 null —— 这是「永久毒化」是否修好的核心判据
      expect(await cache.read('roads', bbox), isNull,
          reason: '空结果不得写入近乎永久的项目级缓存');
      expect(await cache.read('buildings', bbox), isNull);
      expect(await cache.read('places', bbox), isNull);
      final idx = File('${dir.path}/index.json');
      // 索引文件要么不存在，要么为空数组 —— 不得登记任何数据集
      final idxContent = idx.existsSync() ? idx.readAsStringSync() : '[]';
      expect(idxContent.trim(), anyOf('[]', 'null'),
          reason: '缓存索引不得登记空结果：$idxContent');

      final callsAfterFirst = calls;
      expect(callsAfterFirst, greaterThan(0));

      // ③ 第二次导出必须重新走网络（而不是复用空缓存）
      final d2 = await BasemapFetcher.fetchFor(labels,
          rangeM: 300, cache: cache, useTdt: false);
      expect(d2.roads, isEmpty);
      expect(calls, greaterThan(callsAfterFirst),
          reason: '第二次导出必须重新联网重抓，不得命中空缓存');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('反向验证：正常有数据的响应确实会被缓存并可离线复用', () async {
      final dir = Directory.systemTemp.createTempSync('qa20_b1_data');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cache = BasemapCache(dir);
      var calls = 0;
      String qaBodyFor(String data) {
        if (data.contains('"highway"')) return qaRoadsJson();
        if (data.contains('"building"')) return qaBuildingsJson();
        if (data.contains('"power"')) return qaExtrasJson(); // v3.9.4 周边要素
        return qaPlacesJson();
      }

      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        return qaOk(qaBodyFor(url.queryParameters['data'] ?? ''));
      };

      final labels = qaLabels();
      final bbox = BasemapFetcher.boundsOf(labels, 300);

      final d1 = await BasemapFetcher.fetchFor(labels,
          rangeM: 300, cache: cache, useTdt: false);
      expect(d1.roads, isNotEmpty, reason: 'mock 有数据时应解析出道路');
      expect(d1.buildings, isNotEmpty, reason: 'mock 有数据时应解析出建筑');
      expect(d1.report.roads.state, FetchState.ok);
      expect(d1.report.buildings.state, FetchState.ok);

      // 必须落盘
      expect(await cache.read('roads', bbox), isNotNull,
          reason: '有数据必须落缓存（不得被"空结果不落缓存"误伤）');
      expect(await cache.read('buildings', bbox), isNotNull);

      final callsAfterFirst = calls;

      // 第二次：全部走缓存，不再联网
      final d2 = await BasemapFetcher.fetchFor(labels,
          rangeM: 300, cache: cache, useTdt: false);
      expect(calls, callsAfterFirst,
          reason: '第二次应完全命中缓存，网络调用次数不得增加'
              '（v3.9.4 起含新增的电力/水系一路，同样应命中缓存）');
      expect(d2.report.roads.state, FetchState.cached);
      expect(d2.report.buildings.state, FetchState.cached);
      expect(d2.roads.length, d1.roads.length);
      expect(d2.buildings.length, d1.buildings.length);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('B20-QA B2 空壳/非数据应答闸门', () {
    test('200 但无 "elements"（{"foo":1}）→ 判失败、不赢竞速', () async {
      // 慢但正确的端点 vs 快但空壳的端点：空壳必须赢不下竞速
      OverpassClient.httpGetOverride = (url, {headers}) async {
        if (url.host == 'fast-shell.example') {
          return qaOk(qaShellNoElements);
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return qaOk(qaRoadsJson());
      };
      final body = await OverpassClient.fetchRaw('[out:json];',
          endpoints: const [
            'https://fast-shell.example/api',
            'https://slow-good.example/api'
          ],
          timeout: const Duration(seconds: 3),
          retries: 0);
      expect(body, qaRoadsJson(),
          reason: '无 elements 的空壳 200 不得赢下竞速');
      expect(body.contains('"highway"'), isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('全端点均为无 elements 空壳 → 抛异常且绝不写赛道结果', () async {
      OverpassClient.httpGetOverride =
          (url, {headers}) async => qaOk(qaShellNoElements);
      await expectLater(
          OverpassClient.fetchRaw('[out:json];',
              endpoints: const ['https://a.example/api'],
              timeout: const Duration(milliseconds: 300),
              retries: 0),
          throwsA(isA<HttpException>()));
    }, timeout: const Timeout(Duration(seconds: 30)));

    // ★★★ QA 独立发现：真实世界的「空壳」是**含 elements 但为空数组** ★★★
    test('[QA 新增 → P0 修复] 真实空壳形态（含 "elements" 但数组为空）'
        '不再赢下竞速，慢而正确的端点胜出', () async {
      // 前提：该 body 确实包含 "elements"（否则旧闸门拦得住，本用例无意义）
      expect(qaOsmChEmptyBody.contains('"elements"'), isTrue,
          reason: 'osm.ch 真实应答含 "elements"，旧闸门拦不住它');
      // 新闸门：能识别"含 elements 但为空数组"这种真实空壳形态
      expect(OverpassClient.hasEmptyElements(qaOsmChEmptyBody), isTrue,
          reason: '必须识别 QA 实测的真实空壳排版（多行空白的 [ ]）');

      var slowGoodReturned = false;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        if (url.host == 'osmch.example') {
          return qaOk(qaOsmChEmptyBody); // ~0ms 返回（真实实测 ≈1.05s）
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
        slowGoodReturned = true;
        return qaOk(qaRoadsJson());
      };

      final body = await OverpassClient.fetchRaw('[out:json];',
          endpoints: const [
            'https://osmch.example/api',
            'https://good.example/api'
          ],
          timeout: const Duration(seconds: 3),
          retries: 0);

      // 修复后：空壳不得抢答，必须等有数据的端点
      expect(body, qaRoadsJson(), reason: '空答案不得赢下竞速');
      expect(slowGoodReturned, isTrue);
      final parsed = OverpassClient.parseRoads(body);
      expect(parsed.length, 2, reason: '竞速结果必须是那 2 条真实道路');

      // 端到端前提翻转：内置端点**不再**含 osm.ch（已下线）
      expect(OverpassEndpoints.builtin().any((e) => e.contains('osm.ch')),
          isFalse,
          reason: 'osm.ch 为全局故障的空壳实例，已从抓取列表移除');
      for (final bad in OverpassEndpoints.retired) {
        expect(OverpassEndpoints.builtin(), isNot(contains(bad)));
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('[P0 保留] 全端点都返回真实空壳 → 才用空答案收场（不得抛失败）', () async {
      OverpassClient.httpGetOverride =
          (url, {headers}) async => qaOk(qaOsmChEmptyBody);
      final body = await OverpassClient.fetchRaw('[out:json];',
          endpoints: const [
            'https://a.example/api',
            'https://b.example/api'
          ],
          timeout: const Duration(milliseconds: 300),
          retries: 0);
      expect(body, qaOsmChEmptyBody, reason: '只有"所有端点都空"时才允许空答案收场');
      expect(OverpassClient.parseRoads(body), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));

    // ★★★ QA 独立发现的核心缺陷（端到端证据）★★★
    // 按 QA 本机实测的真实端点延迟重放竞速，证明用户最终拿到的是**空底图**，
    // 且 report 谎报 `ok` —— 即用户主诉"建筑道路导不出来"并未被修复。
    test('[QA 发现·端到端 → P0 修复] 按 QA 实测延迟重放：不再被空壳抢答，'
        '用户拿到真实矢量底图且报告不再谎报', () async {
      final cacheDir = Directory.systemTemp.createTempSync('qa20_b2_race');
      addTearDown(() => cacheDir.deleteSync(recursive: true));
      final cache = BasemapCache(cacheDir);

      // 真实延迟（QA 2026-09-13 实测，信阳 bbox，roads 查询）：
      //   overpass.osm.ch      ≈1.05s  200 但 elements 为空  ← 最快（现已下线）
      //   overpass-api.de      ≈2.35s  200 / 955 条（正确数据）
      //   其余端点           504 或连接失败
      // 注：即便 osm.ch 仍在列表里，空答案也已不允许抢答（双保险）。
      OverpassClient.httpGetOverride = (url, {headers}) async {
        final h = url.host;
        if (h == 'overpass.osm.ch') {
          await Future<void>.delayed(const Duration(milliseconds: 1050));
          return qaOk(qaOsmChEmptyBody);
        }
        if (h == 'overpass-api.de') {
          await Future<void>.delayed(const Duration(milliseconds: 2350));
          final q = url.queryParameters['data'] ?? '';
          if (q.contains('"building"')) return qaOk(qaBuildingsJson());
          if (q.contains('"place"')) return qaOk(qaPlacesJson());
          if (q.contains('"power"')) return qaOk(qaExtrasJson());
          return qaOk(qaRoadsJson());
        }
        throw const HttpException('实测：504 / 连接失败');
      };

      final d = await BasemapFetcher.fetchFor(qaLabels(),
          rangeM: 300, cache: cache, useTdt: false);

      // 修复后：用户拿到的是真实数据，不是空底图
      expect(d.roads, isNotEmpty, reason: '不得再被空答案抢答作废');
      // v3.9.3 起底图按**沿线路缓冲**裁剪（非矩形 bbox）：样例里第二条路
      // 离轨迹超过 300m，被正确裁掉——这里只断言"拿到的不是空底图"。
      expect(d.roads.length, greaterThanOrEqualTo(1));
      expect(d.buildings, isNotEmpty);
      expect(d.report.hasVector, isTrue);
      expect(d.report.roads.state, FetchState.ok);
      expect(d.report.roads.count, greaterThanOrEqualTo(1));
      expect(d.report.anyEmptyAnswer, isFalse);
      expect(d.report.statusLines().first, contains('道路'));
      expect(d.report.statusLines().first, isNot(contains('该范围内无数据')));

      // 有数据 → 写入缓存；二次导出（不刷新）直接命中缓存且仍有数据
      final d2 = await BasemapFetcher.fetchFor(qaLabels(),
          rangeM: 300, cache: cache, useTdt: false);
      // 同上：沿线路缓冲裁剪后样例只剩 1 条在 300m 内（缓存命中路径同理）。
      expect(d2.roads.length, greaterThanOrEqualTo(1));
      expect(d2.report.roads.state, FetchState.cached);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('[QA 场景保留] 若所有端点都返回空壳 → 0 项但必须明确"数据源返回空/疑似镜像故障"',
        () async {
      final cacheDir = Directory.systemTemp.createTempSync('qa20_b2_allempty');
      addTearDown(() => cacheDir.deleteSync(recursive: true));
      final cache = BasemapCache(cacheDir);
      OverpassClient.httpGetOverride =
          (url, {headers}) async => qaOk(qaOsmChEmptyBody);

      final d = await BasemapFetcher.fetchFor(qaLabels(),
          rangeM: 300, cache: cache, useTdt: false);

      expect(d.roads, isEmpty);
      expect(d.report.hasVector, isFalse);
      // 语义修正：不再谎称"该范围内无数据"，而是提示疑似镜像故障 + 建议重试
      expect(d.report.anyEmptyAnswer, isTrue);
      expect(d.report.statusLines().first, contains('数据源返回空'));
      expect(d.report.statusLines().first, contains('疑似底图镜像故障'));
      expect(d.report.statusLines().first, isNot(contains('该范围内无数据')));
      // 空结果不落缓存 → 用户点「重试抓取」可自救
      expect(await cache.read('roads', BasemapFetcher.boundsOf(qaLabels(), 300)),
          isNull);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ======================= C：端点与重试策略 =======================

  group('B20-QA C1 端点清单', () {
    test('内置端点：空壳/已死全部下线，仅留实测能返回真实数据的镜像', () {
      final eps = OverpassEndpoints.builtin();
      expect(eps.length, 6);
      // 下线：空壳 osm.ch（200 最快但恒空）/ 已死 ru·jp / 长期超时 private.coffee
      expect(eps.any((e) => e.contains('private.coffee')), isFalse);
      expect(eps.any((e) => e.contains('overpass.osm.ch')), isFalse,
          reason: '空壳镜像已下线：它抢答会导致 0 道路/0 建筑');
      expect(eps.any((e) => e.contains('openstreetmap.ru')), isFalse,
          reason: '已死端点已下线（3/3 TCP 挂 10s）');
      expect(eps.any((e) => e.contains('overpass.osm.jp')), isFalse,
          reason: '已死端点已下线（3/3 秒拒）');
      // 保留：实测 elements > 0 的可用镜像（含新验证的 fr 与 z.overpass-api.de）
      expect(eps.any((e) => e.contains('maps.mail.ru')), isTrue);
      expect(eps.any((e) => e.contains('overpass-api.de')), isTrue);
      expect(eps.any((e) => e.contains('kumi.systems')), isTrue);
      expect(eps.any((e) => e.contains('overpass.openstreetmap.fr')), isTrue);
      expect(eps.any((e) => e.contains('z.overpass-api.de')), isTrue);
      // 诊断常量仍在源码中保留（不参与抓取）
      expect(OverpassEndpoints.retiredPrivateCoffee.contains('private.coffee'),
          isTrue);
      expect(OverpassEndpoints.retired.length, 4);
      for (final bad in OverpassEndpoints.retired) {
        expect(eps, isNot(contains(bad)), reason: '$bad 不得再参与抓取');
      }
      // resolve：用户自定义端点**在前**、内置**在后**，去重、保序
      // （第二十三批规格变更：自定义优先——用户配反代即绕开境外直连，须排最前）
      final merged = OverpassEndpoints.resolve(
          'https://x.example/api;https://overpass-api.de/api/interpreter');
      expect(merged.length, 7, reason: '6 内置 + x.example；de 已存在故去重');
      expect(merged.first, 'https://x.example/api',
          reason: '自定义端点必须排在最前（旧规格"内置在前"已废弃）');
      expect(merged.contains('https://overpass-api.de/api/interpreter'), isTrue,
          reason: '自定义里已含 de 且保留其位置，内置追加时去重不重复');
      expect(merged.last, contains('z.overpass-api.de'),
          reason: '仅内置端点退居兜底、排在自定义之后');
    });
  });

  group('B20-QA C2 重试轮次', () {
    test('全端点失败 → 总调用次数 = 2 × 端点数（首轮 + 重试轮）', () async {
      var calls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        throw const HttpException('mock 全灭');
      };
      await expectLater(
          OverpassClient.fetchRaw('[out:json];',
              endpoints: const [
                'https://a.example/api',
                'https://b.example/api',
                'https://c.example/api'
              ],
              timeout: const Duration(milliseconds: 200),
              retries: 1),
          throwsA(isA<HttpException>()));
      expect(calls, 6, reason: '3 端点 × (1 首轮 + 1 重试轮) = 6');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('首轮全灭、重试轮成功 → 返回正确内容', () async {
      var calls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        if (calls <= 2) throw const HttpException('首轮失败');
        return qaOk(qaRoadsJson());
      };
      final body = await OverpassClient.fetchRaw('[out:json];',
          endpoints: const [
            'https://a.example/api',
            'https://b.example/api'
          ],
          timeout: const Duration(milliseconds: 200),
          retries: 1);
      expect(body, qaRoadsJson());
      expect(calls, greaterThan(2));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('竞速：首个成功即返回，慢端点不阻塞', () async {
      OverpassClient.httpGetOverride = (url, {headers}) async {
        if (url.host == 'slow.example') {
          await Future<void>.delayed(const Duration(seconds: 5));
          return qaOk('{"elements":[]}');
        }
        return qaOk(qaRoadsJson());
      };
      final sw = Stopwatch()..start();
      final body = await OverpassClient.fetchRaw('[out:json];',
          endpoints: const [
            'https://fast.example/api',
            'https://slow.example/api'
          ],
          timeout: const Duration(milliseconds: 300),
          retries: 0);
      sw.stop();
      expect(body, qaRoadsJson());
      expect(sw.elapsedMilliseconds, lessThan(3000),
          reason: '慢端点（5s）不得阻塞竞速返回');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('超时常量：首轮 12s，重试轮 ×2 = 24s', () {
      expect(OverpassClient.defaultTimeout, const Duration(seconds: 12));
      expect(OverpassClient.defaultRetries, 1);
      expect(OverpassClient.retryTimeoutFactor, 2);
      expect(OverpassClient.defaultTimeout * OverpassClient.retryTimeoutFactor,
          const Duration(seconds: 24));
      expect(OverpassClient.retryDelay, const Duration(milliseconds: 1200));
    });
  });

  // ======================= D：建筑/道路端到端三路径 =======================

  group('B20-QA D 建筑/道路端到端', () {
    test('路径①注入 basemap → DXF 出 DaoLuBian 与 JianZhu', () async {
      final dir = Directory.systemTemp.createTempSync('qa20_d1');
      PathProviderPlatform.instance = QaPathProvider(dir.path);
      addTearDown(() => dir.deleteSync(recursive: true));

      final bm = BasemapData(
        roads: OverpassClient.parseRoads(qaRoadsJson()),
        buildings: OverpassClient.parseBuildings(qaBuildingsJson()),
        places: OverpassClient.parsePlaces(qaPlacesJson()),
        report: const BasemapFetchReport(
          roads: DatasetReport(FetchState.ok, count: 2),
          buildings: DatasetReport(FetchState.ok, count: 2),
          places: DatasetReport(FetchState.ok, count: 1),
        ),
      );
      expect(bm.roads, isNotEmpty);
      expect(bm.buildings, isNotEmpty);

      final res = await DxfExporter.export(
        name: 'qa20_inject',
        labels: qaLabels(),
        includeSurroundings: true,
        basemap: bm,
        version: DxfVersion.r12,
      );
      final dxf = qaReadDxfBytes(res.file);
      expect(qaEntitiesOnLayer(dxf, 'DaoLuBian'), greaterThan(0),
          reason: '道路实体必须 > 0（用户主诉回归守卫）');
      expect(qaEntitiesOnLayer(dxf, 'JianZhu'), greaterThan(0),
          reason: '建筑实体必须 > 0（用户主诉回归守卫）');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('路径②缓存命中 → DXF 仍出 DaoLuBian 与 JianZhu', () async {
      final dir = Directory.systemTemp.createTempSync('qa20_d2');
      PathProviderPlatform.instance = QaPathProvider(dir.path);
      addTearDown(() => dir.deleteSync(recursive: true));

      // 先落缓存
      final cacheDir = Directory.systemTemp.createTempSync('qa20_d2_cache');
      addTearDown(() => cacheDir.deleteSync(recursive: true));
      final cache = BasemapCache(cacheDir);
      final bbox = BasemapFetcher.boundsOf(qaLabels(), 300);
      await cache.write('roads', bbox, qaRoadsJson());
      await cache.write('buildings', bbox, qaBuildingsJson());
      await cache.write('places', bbox, qaPlacesJson());
      expect(await cache.read('roads', bbox), isNotNull);

      // 网络钩子设为"必炸"：证明走的是缓存而非网络
      OverpassClient.httpGetOverride = (url, {headers}) async {
        throw const HttpException('不应联网');
      };
      final bm = await BasemapFetcher.fetchFor(qaLabels(),
          rangeM: 300, cache: cache, useTdt: false);
      expect(bm.report.roads.state, FetchState.cached);
      expect(bm.report.buildings.state, FetchState.cached);
      expect(bm.roads, isNotEmpty);
      expect(bm.buildings, isNotEmpty);

      final res = await DxfExporter.export(
        name: 'qa20_cache',
        labels: qaLabels(),
        includeSurroundings: true,
        basemap: bm,
      );
      final text = await _readExported(dir, 'qa20_cache', res);
      expect(qaEntitiesOnLayer(text, 'DaoLuBian'), greaterThan(0));
      expect(qaEntitiesOnLayer(text, 'JianZhu'), greaterThan(0));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('路径③真实抓取（mock Overpass 真实格式）→ DXF 出两类实体', () async {
      final dir = Directory.systemTemp.createTempSync('qa20_d3');
      PathProviderPlatform.instance = QaPathProvider(dir.path);
      addTearDown(() => dir.deleteSync(recursive: true));

      OverpassClient.httpGetOverride = (url, {headers}) async {
        final data = url.queryParameters['data'] ?? '';
        if (data.contains('"highway"')) return qaOk(qaRoadsJson());
        if (data.contains('"building"')) return qaOk(qaBuildingsJson());
        return qaOk(qaPlacesJson());
      };

      final res = await DxfExporter.export(
        name: 'qa20_fetch',
        labels: qaLabels(),
        includeSurroundings: true,
        rangeM: 300,
        version: DxfVersion.r12,
      );
      final text = await _readExported(dir, 'qa20_fetch', res);
      expect(qaEntitiesOnLayer(text, 'DaoLuBian'), greaterThan(0),
          reason: '真实抓取路径必须产出道路实体');
      expect(qaEntitiesOnLayer(text, 'JianZhu'), greaterThan(0),
          reason: '真实抓取路径必须产出建筑实体');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('全端点失败 → DXF 仍产出（不崩），report failed 且带中文原因', () async {
      final dir = Directory.systemTemp.createTempSync('qa20_d4');
      PathProviderPlatform.instance = QaPathProvider(dir.path);
      addTearDown(() => dir.deleteSync(recursive: true));

      OverpassClient.httpGetOverride = (url, {headers}) async {
        throw const HttpException('mock 全端点失败');
      };
      final bm = await BasemapFetcher.fetchFor(qaLabels(),
          rangeM: 300,
          cache: BasemapCache(
              Directory.systemTemp.createTempSync('qa20_d4_cache')),
          useTdt: false,
          refresh: false);
      expect(bm.report.allFailed, isTrue);
      expect(bm.report.roads.error, isNotNull);
      expect(bm.report.roads.error!.contains('失败') ||
          bm.report.roads.error!.contains('Exception') ||
          bm.report.roads.error!.contains('HttpException'), isTrue,
          reason: '失败原因不得为空/英文裸异常：${bm.report.roads.error}');
      final lines = bm.report.statusLines();
      expect(lines.length, 3);
      expect(lines.any((s) => s.startsWith('道路')), isTrue);
      expect(lines.any((s) => s.contains('未获取')), isTrue,
          reason: '状态行必须含中文失败说明：$lines');

      final res = await DxfExporter.export(
        name: 'qa20_allfail',
        labels: qaLabels(),
        includeSurroundings: true,
        basemap: bm,
      );
      final text = await _readExported(dir, 'qa20_allfail', res);
      expect(text, isNotEmpty);
      expect(text.contains('GanLu'), isTrue, reason: '杆路本体仍须出图');
      expect(qaEntitiesOnLayer(text, 'DaoLuBian'), 0,
          reason: '底图全灭时不应有道路实体');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  // ======================= E：高德接入 =======================

  group('B20-QA E 高德接入', () {
    const gcjExamples = [
      ['114.098765', '32.123456'],
      ['114.050123', '32.180987'],
      ['116.407526', '39.904030'], // 北京天安门（境内）
    ];

    String amapBody(List<List<String>> locs,
        {String status = '1', String infocode = '10000', String info = 'OK'}) {
      return jsonEncode({
        'status': status,
        'infocode': infocode,
        'info': info,
        'count': '${locs.length}',
        'pois': [
          for (var i = 0; i < locs.length; i++)
            {
              'id': 'B0FFH$i',
              'name': '丰乐园小区${i + 1}期',
              'type': '商务住宅;住宅区;住宅小区',
              'address': '河南省信阳市浉河区北京大街${100 + i}号',
              'location': '${locs[i][0]},${locs[i][1]}',
              'pname': '河南省',
              'cityname': '信阳市',
              'adname': '浉河区',
            },
        ],
      });
    }

    test('解析 + GCJ→WGS 纠偏（QA 独立参考实现交叉验证）', () async {
      AmapClient.httpGetOverride = (url) async => qaOk(amapBody(gcjExamples));
      final r = await AmapClient.search('丰乐园', 'qa-key');
      expect(r.length, 3);
      expect(r.first.name, '丰乐园小区1期');
      expect(r.first.address, contains('信阳市'));
      expect(r[2].name, '丰乐园小区3期');

      for (var i = 0; i < r.length; i++) {
        final mockLon = double.parse(gcjExamples[i][0]);
        final mockLat = double.parse(gcjExamples[i][1]);
        // ① location="lng,lat" 解析正确性（顺序不能颠倒）
        expect(r[i].lon, closeTo(mockLon, 0.02),
            reason: '经度应与 mock 的 lng 接近（已纠偏，允许 5xx 米级偏移）');
        expect(r[i].lat, closeTo(mockLat, 0.02),
            reason: '纬度应与 mock 的 lat 接近（已纠偏，允许 5xx 米级偏移）');
        // ② 必须已纠偏为 WGS：与 GCJ 原始值距离应在 50~2000m 之间（境内特征）
        final offset = qaDistM(mockLat, mockLon, r[i].lat, r[i].lon);
        expect(offset, greaterThan(30),
            reason: '境内坐标若未做 GCJ→WGS 纠偏，偏移量应≈0，实测 ${offset}m');
        expect(offset, lessThan(2000));
        // ③ **独立参考实现反验**：对输出结果再做正向加密应还原 mock 的 GCJ
        final back = QaGcjRef.encrypt(r[i].lat, r[i].lon);
        final backErr = qaDistM(mockLat, mockLon, back[0], back[1]);
        expect(backErr, lessThan(2.0),
            reason: 'GCJ→WGS 不精确：正向回加密误差 ${backErr.toStringAsFixed(3)}m '
                '应 < 2m（第 ${i + 1} 条）');
      }
      // ④ SDK 转换器与 QA 参考实现完全一致（排除参考实现自身写错）
      for (final p in gcjExamples) {
        final sdk = Gcj02Converter.gcj02ToWgs84(
            double.parse(p[1]), double.parse(p[0]));
        final re = QaGcjRef.encrypt(sdk[0], sdk[1]);
        expect(qaDistM(double.parse(p[1]), double.parse(p[0]), re[0], re[1]),
            lessThan(2.0));
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('convertGcj=false 时保留 GCJ 原值（可对照）', () async {
      AmapClient.httpGetOverride = (url) async => qaOk(amapBody(gcjExamples));
      final r = await AmapClient.search('丰乐园', 'qa-key', convertGcj: false);
      expect(r.first.lat, closeTo(32.123456, 1e-9));
      expect(r.first.lon, closeTo(114.098765, 1e-9));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('INVALID_USER_KEY（status=0/infocode=10001）→ 抛异常，绝不静默空',
        () async {
      var msg = '';
      Future<List<SearchResult>> call() async {
        final uri = Uri.https('restapi.amap.com', '/v5/place/polygon', {
          'key': 'bad-key',
          'polygon': '114.0,32.1|114.1,32.2',
        });
        final res = await (AmapClient.httpGetOverride!)(uri);
        expect(res.statusCode, 200);
        return AmapClient.poiInBounds(
            [32.1, 114.0, 32.2, 114.1], '小区', 'bad-key');
      }
      AmapClient.httpGetOverride = (url) async => qaOk(amapBody(const [],
          status: '0', infocode: '10001', info: 'INVALID_USER_KEY'));
      try {
        await call();
        fail('无效 key 必须抛异常');
      } catch (e) {
        msg = e.toString();
      }
      expect(msg, contains('INVALID_USER_KEY'),
          reason: '异常须携带高德原始 info：$msg');
      // 抛异常（而非返回空列表）→ SearchService 才会降级
      await expectLater(
          () async => await AmapClient.poiInBounds(
              [32.1, 114.0, 32.2, 114.1], '小区', 'bad-key'),
          throwsA(isA<Exception>()));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('http 非 200 → 抛异常', () async {
      AmapClient.httpGetOverride = (url) async => http.Response('{}', 502);
      await expectLater(
          AmapClient.search('丰乐园', 'k'), throwsA(isA<Exception>()));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('polygon 参数顺序：左下(lng,lat)|右上(lng,lat)', () async {
      Uri? seen;
      AmapClient.httpGetOverride = (url) async {
        seen = url;
        return qaOk(amapBody([
          ['114.05', '32.15']
        ]));
      };
      final bbox = [32.10, 114.00, 32.20, 114.10]; // [minLat,minLon,maxLat,maxLon]
      // 本用例只验参数顺序/格式；坐标转换另由 QA21-G 覆盖 → 关闭纠偏，断言原 WGS 值。
      final r = await AmapClient.poiInBounds(bbox, '小区', 'k', convertGcj: false);
      expect(r, isNotEmpty);
      final poly = seen!.queryParameters['polygon']!;
      expect(poly, '114.0,32.1|114.1,32.2',
          reason: '须为 左下lng,lat | 右上lng,lat，实测：$poly');
      expect(seen!.host, 'restapi.amap.com');
      expect(seen!.path, '/v5/place/polygon');
      expect(seen!.scheme, 'https');
      expect(seen!.queryParameters['keywords'], '小区');
      expect(seen!.queryParameters['key'], 'k');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('关键词搜索：location=lng,lat + sortrule=distance（基准点已转 GCJ）',
        () async {
      Uri? seen;
      AmapClient.httpGetOverride = (url) async {
        seen = url;
        return qaOk(amapBody([
          ['114.05', '32.15']
        ]));
      };
      await AmapClient.search('丰乐园', 'k', nearLat: 32.1264, nearLon: 114.0913,
          region: '信阳', cityLimit: true);
      expect(seen!.path, '/v5/place/text');
      expect(seen!.queryParameters['keywords'], '丰乐园');
      expect(seen!.queryParameters['sortrule'], 'distance');
      expect(seen!.queryParameters['region'], '信阳');
      expect(seen!.queryParameters['city_limit'], 'true');
      final loc = seen!.queryParameters['location']!;
      final parts = loc.split(',');
      expect(parts.length, 2);
      final lng = double.parse(parts[0]);
      final lat = double.parse(parts[1]);
      // 基准点应先正向加密为 GCJ 再传给高德
      final expectGcj = Gcj02Converter.wgs84ToGcj02(32.1264, 114.0913);
      expect(lat, closeTo(expectGcj[0], 1e-9));
      expect(lng, closeTo(expectGcj[1], 1e-9));
      // 且确实是 GCJ（已偏移）
      expect(qaDistM(32.1264, 114.0913, lat, lng), greaterThan(100));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('搜索源优先级：高德成功 → 不调天地图/境外源', () async {
      var amapCalls = 0, tdtCalls = 0;
      AmapClient.httpGetOverride = (url) async {
        amapCalls++;
        return qaOk(amapBody([
          ['114.05', '32.15']
        ]));
      };
      TiandituClient.httpGetOverride = (url) async {
        tdtCalls++;
        fail('高德成功时不得调用天地图');
      };
      final r = await SearchService.search('丰乐园', amapKey: 'k', tdtKey: 't');
      expect(amapCalls, 1);
      expect(tdtCalls, 0);
      expect(r.length, 1);
      expect(r.first.name, contains('丰乐园'));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('高德失败（无效 key）→ 自动降级天地图并返回结果', () async {
      var amapCalls = 0, tdtCalls = 0;
      AmapClient.httpGetOverride = (url) async {
        amapCalls++;
        return qaOk(amapBody(const [],
            status: '0', infocode: '10001', info: 'INVALID_USER_KEY'));
      };
      TiandituClient.httpGetOverride = (url) async {
        tdtCalls++;
        return qaOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': 'OK'},
          'resultType': 1,
          'pois': [
            {
              'name': '丰乐园',
              'address': '河南省信阳市浉河区',
              'lonlat': '114.0913,32.1264',
            },
          ],
        }));
      };
      final r =
          await SearchService.search('丰乐园', amapKey: 'bad', tdtKey: 't');
      expect(amapCalls, 1, reason: '高德先试一次');
      expect(tdtCalls, greaterThan(0), reason: '高德失败必须降级天地图');
      expect(r, isNotEmpty);
      expect(r.first.name, '丰乐园');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('★ 未配高德 key → 行为不变：仍走天地图（关键回归）', () async {
      var tdtCalls = 0;
      AmapClient.httpGetOverride = (url) async {
        fail('未配高德 key 时绝不可调用高德');
      };
      TiandituClient.httpGetOverride = (url) async {
        tdtCalls++;
        return qaOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': 'OK'},
          'resultType': 1,
          'pois': [
            {
              'name': '李庄村',
              'address': '河南省信阳市',
              'lonlat': '114.0913,32.1264',
            },
          ],
        }));
      };
      final r = await SearchService.search('李庄', tdtKey: 't');
      expect(tdtCalls, greaterThan(0), reason: '未配高德 key 必须仍走天地图');
      expect(r, isNotEmpty);
      expect(r.first.name, '李庄村');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('★ 未配高德 key → fetchFor 地名兜底 source 仍为 +tdt', () async {
      final dir = Directory.systemTemp.createTempSync('qa20_e_tdt');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cache = BasemapCache(dir);
      var tdtCalls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        final data = url.queryParameters['data'] ?? '';
        if (data.contains('"place"')) return qaOk(qaLegitEmpty); // OSM 无地名
        return qaOk(qaLegitEmpty);
      };
      AmapClient.httpGetOverride = (url) async {
        fail('未配 key 不得调用高德');
      };
      TiandituClient.httpGetOverride = (url) async {
        tdtCalls++;
        return qaOk(jsonEncode({
          'status': {'infocode': 1000, 'cndesc': 'OK'},
          'resultType': 1,
          'pois': [
            {
              'name': '丰乐园',
              'address': '信阳市浉河区',
              'lonlat': '114.0913,32.1264',
            },
          ],
        }));
      };
      // mock 坐标按 WGS 意图给（语义是"线路旁的真实地名"），故关闭纠偏，
      // 避免被当作 GCJ-02 再纠偏后偏移 ~600m 落出 bbox（测试不测坐标转换）。
      final d = await BasemapFetcher.fetchFor(qaLabels(),
          rangeM: 300,
          cache: cache,
          tdtKey: 't',
          convertGcj: false);
      expect(tdtCalls, greaterThan(0), reason: '未配高德 key 仍须走天地图兜底');
      expect(d.places, isNotEmpty);
      expect(d.report.places.source, contains('+tdt'),
          reason: 'source 必须仍为 +tdt，不得变成 +amap：'
              '${d.report.places.source}');
      expect(d.report.places.source.contains('+amap'), isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('配高德 key → 地名兜底走高德，天地图不被调用', () async {
      final dir = Directory.systemTemp.createTempSync('qa20_e_amap');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cache = BasemapCache(dir);
      var amapCalls = 0;
      OverpassClient.httpGetOverride =
          (url, {headers}) async => qaOk(qaLegitEmpty);
      AmapClient.httpGetOverride = (url) async {
        amapCalls++;
        return qaOk(amapBody([
          ['114.0913', '32.1264']
        ]));
      };
      TiandituClient.httpGetOverride = (url) async {
        fail('高德有结果时不得回落天地图');
      };
      final d = await BasemapFetcher.fetchFor(qaLabels(),
          rangeM: 300,
          cache: cache,
          amapKey: 'k',
          tdtKey: 't',
          convertGcj: false); // mock 坐标为 WGS 意图，关闭纠偏
      expect(amapCalls, greaterThan(0));
      expect(d.places, isNotEmpty);
      expect(d.report.places.source, contains('+amap'));
      expect(d.report.places.source.contains('+tdt'), isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('地名兜底开关关闭 → 高德/天地图都不兜底（与旧版一致）', () async {
      final dir = Directory.systemTemp.createTempSync('qa20_e_off');
      addTearDown(() => dir.deleteSync(recursive: true));
      OverpassClient.httpGetOverride =
          (url, {headers}) async => qaOk(qaLegitEmpty);
      AmapClient.httpGetOverride = (url) async => qaOk(amapBody([
        ['114.0913', '32.1264']
      ]));
      TiandituClient.httpGetOverride = (url) async => qaOk('{"result":[]}');
      final d = await BasemapFetcher.fetchFor(qaLabels(),
          rangeM: 300,
          cache: BasemapCache(dir),
          amapKey: 'k',
          tdtKey: 't',
          useTdt: false);
      expect(d.places, isEmpty);
      expect(d.report.places.source.contains('+amap'), isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ======================= F：红线 =======================

  group('B20-QA F 红线', () {
    test('依赖零新增（pubspec.yaml 不含新包名）', () {
      final pub = File('pubspec.yaml').readAsStringSync();
      for (final banned in [
        'geocoding',
        'amap_flutter',
        'amap_location',
        'amap_search',
        'flutter_map_tile_caching',
        'dio',
        'retrofit',
      ]) {
        expect(pub.contains(banned), isFalse,
            reason: '不得新增依赖：$banned');
      }
      // 既有依赖仍在
      for (final keep in ['http:', 'gbk_codec:', 'flutter_map:', 'intl:']) {
        expect(pub.contains(keep), isTrue);
      }
    });

    test('解析层未回归：parseRoads/parseBuildings/parsePlaces 仍出非空结果', () {
      expect(OverpassClient.parseRoads(qaRoadsJson()).length, 2);
      expect(OverpassClient.parseBuildings(qaBuildingsJson()).length, 2,
          reason: 'relation 外环缝合 + way 单环均应产出');
      expect(OverpassClient.parsePlaces(qaPlacesJson()).length, 1);
      expect(OverpassClient.parseRoads(qaLegitEmpty), isEmpty);
      expect(OverpassClient.parseBuildings(qaLegitEmpty), isEmpty);
    });

    test('举报语义未降：失败三态 / 状态行 / 汇总行齐全且为中文', () {
      const r = BasemapFetchReport(
        roads: DatasetReport(FetchState.failed, error: '网络不可达'),
        buildings: DatasetReport(FetchState.ok, count: 0),
        places: DatasetReport(FetchState.cached, count: 3, source: 'cache'),
      );
      expect(r.anyFailed, isTrue);
      expect(r.allFailed, isFalse);
      expect(r.anyCached, isTrue);
      expect(r.summaryLine, '道路 0 项 / 建筑 0 项 / 地名 3 项');
      final lines = r.statusLines();
      expect(lines, [
        '道路 未获取（网络不可达）',
        '建筑 0 项（该范围内无数据）',
        '地名 3 项（本地缓存）',
      ]);
      final w = r.toWarnings();
      expect(w.any((s) => s.contains('刷新底图')), isTrue);
      expect(w.any((s) => s.contains('缺道路矢量')), isTrue);
    });

    test('缓存有效期仍近乎永久（36500 天）——未被顺手改小', () {
      expect(BasemapCache.defaultMaxAgeDays, 36500);
    });
  });
}

Future<String> _readExported(
    Directory root, String name, DxfExportResult res) async {
  final f = File(res.file.path);
  if (await f.exists()) return qaReadDxfBytes(f);
  // 兜底：递归查找导出目录内的同名 dxf
  final hit = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((e) => e.path.endsWith('$name.dxf'))
      .toList();
  if (hit.isNotEmpty) return qaReadDxfBytes(hit.first);
  fail('找不到导出文件 ${res.file.path}（root=${root.path}）');
}
