// QA Round-2 独立复验：P0 修复（空答案不得抢答 + emptyAnswer 语义）。
//
// **独立性**：本文件为 QA 在工程师修复后**新写**的对抗用例，不复用
// batch20_test.dart 的 fixture，也不依赖工程师改写过的 qa_batch20_indep_test.dart。
// 重点打三处：①正则对真实空壳排版的命中与**误判**（false positive）；
// ②用**真实内置端点列表**重放"快空壳 vs 慢数据"；③emptyAnswer 置位边界。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/overpass.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class R2PathProvider extends PathProviderPlatform {
  final String root;
  R2PathProvider(this.root);
  @override
  Future<String?> getExternalStoragePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

http.Response r2Ok(String b, {int status = 200}) => http.Response(
    b, status,
    headers: const {'content-type': 'application/json; charset=utf-8'});

// QA 于 2026-09-13 07:xx 从 overpass.osm.ch 真实抓取的空壳应答（原样保留空白排版）
const String r2RealOsmCh = '{\n'
    '  "version": 0.6,\n'
    '  "generator": "Overpass API 0.7.62.4 2390de5a",\n'
    '  "osm3s": {\n'
    '    "timestamp_osm_base": "34",\n'
    '    "copyright": "The data included in this document is from '
    'www.openstreetmap.org. The data is made available under ODbL."\n'
    '  },\n'
    '  "elements": [\n\n\n  ]\n'
    '}\n';

String r2RoadsJson() => jsonEncode({
      'version': 0.6,
      'elements': [
        {
          'type': 'way',
          'id': 1,
          'tags': {'highway': 'primary', 'name': '北京大街'},
          'geometry': [
            {'lat': 32.1264, 'lon': 114.0913},
            {'lat': 32.1274, 'lon': 114.0923},
            {'lat': 32.1284, 'lon': 114.0933},
          ],
        },
        {
          'type': 'way',
          'id': 2,
          'tags': {'highway': 'residential', 'name': '解放路'},
          'geometry': [
            {'lat': 32.1300, 'lon': 114.0950},
            {'lat': 32.1310, 'lon': 114.0960},
          ],
        },
      ],
    });

String r2BuildingsJson() => jsonEncode({
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
          ],
        },
      ],
    });

String r2PlacesJson() => jsonEncode({
      'version': 0.6,
      'elements': [
        {
          'type': 'node',
          'id': 21,
          'lat': 32.1290,
          'lon': 114.0940,
          'tags': {'place': 'village', 'name': '李庄村'},
        },
      ],
    });

List<MapLabel> r2Labels() => [
      MapLabel(typeId: 'pipe', seq: 1, lat: 32.1264, lon: 114.0913),
      MapLabel(typeId: 'pipe', seq: 2, lat: 32.1274, lon: 114.0923),
      MapLabel(typeId: 'pipe', seq: 3, lat: 32.1284, lon: 114.0933),
    ];

int r2EntitiesOnLayer(String dxf, String layer) =>
    RegExp('8\n$layer\n').allMatches(dxf).length;

/// DXF 是 GBK 字节，必须逐字节映射（latin1）读取，不能按 utf-8 解码。
String r2ReadDxf(File f) => String.fromCharCodes(f.readAsBytesSync());

String r2BodyFor(String data) {
  if (data.contains('"highway"')) return r2RoadsJson();
  if (data.contains('"building"')) return r2BuildingsJson();
  return r2PlacesJson();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => OverpassClient.httpGetOverride = null);
  tearDown(() => OverpassClient.httpGetOverride = null);

  // ---------- R2-1：正则命中 + 误判（false positive）检查 ----------

  group('R2-1 hasEmptyElements 命中与误判', () {
    test('真实 osm.ch 空壳（多行空白排版）必须命中', () {
      expect(OverpassClient.hasEmptyElements(r2RealOsmCh), isTrue,
          reason: '真实空壳排版为 "elements": [\\n\\n\\n  ]，正则须兼容');
      // 各种排版等价形态
      expect(OverpassClient.hasEmptyElements('{"elements":[]}'), isTrue);
      expect(OverpassClient.hasEmptyElements('{"elements": []}'), isTrue);
      expect(OverpassClient.hasEmptyElements('{"version":0.6,"elements":[]}'),
          isTrue);
      expect(
          OverpassClient.hasEmptyElements('{"elements": [   \t\n  ]}'), isTrue);
    });

    test('★ 有数据的应答绝不能被误判为空（否则等于把正常底图全废掉）', () {
      // 三条真实格式的有数据应答
      expect(OverpassClient.hasEmptyElements(r2RoadsJson()), isFalse);
      expect(OverpassClient.hasEmptyElements(r2BuildingsJson()), isFalse);
      expect(OverpassClient.hasEmptyElements(r2PlacesJson()), isFalse);
      // 压缩排版（无空格）
      expect(
          OverpassClient.hasEmptyElements(
              '{"version":0.6,"elements":[{"type":"way","id":1}]}'),
          isFalse);
      // 单条元素
      expect(OverpassClient.hasEmptyElements('{"elements":[{"a":1}]}'), isFalse);
      // 大载荷（1000 条）不得误判
      final big = jsonEncode({
        'version': 0.6,
        'elements': [
          for (var i = 0; i < 1000; i++)
            {
              'type': 'way',
              'id': i,
              'tags': {'highway': 'primary', 'name': '路$i'},
              'geometry': [
                {'lat': 32.1 + i * 1e-5, 'lon': 114.09},
                {'lat': 32.1 + i * 1e-5, 'lon': 114.10},
              ],
            },
        ],
      });
      expect(big.length, greaterThan(50000));
      expect(OverpassClient.hasEmptyElements(big), isFalse,
          reason: 'MB 级有数据应答若被误判为空，会退化成"全部端点空 → 空答案收场"');
      // 嵌套空数组（tags 里的空 list）不得误判为本体的空 elements
      expect(
          OverpassClient.hasEmptyElements(
              '{"elements":[{"tags":{"x":[]}}]}'),
          isFalse);
    });
  });

  // ---------- R2-2：用真实内置端点列表重放"快空壳 vs 慢数据" ----------

  group('R2-2 真实端点列表下的抢答回归', () {
    test('最快的一个内置端点返回空壳，其余四个慢但有数据 → 数据胜出', () async {
      final eps = OverpassEndpoints.builtin();
      expect(eps.length, 6);
      // 选列表里的第一个当"空壳端点"（0ms），其余 4 个 400ms 返回真实数据
      final shell = eps.first;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        final q = url.queryParameters['data'] ?? '';
        if (url.toString().startsWith(shell)) return r2Ok(r2RealOsmCh);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return r2Ok(r2BodyFor(q));
      };
      // 不传 endpoints → 走真实内置列表
      final body = await OverpassClient.fetchRaw('[out:json];(way["highway"]);',
          timeout: const Duration(seconds: 3), retries: 0);
      expect(body, isNot(contains('"timestamp_osm_base": "34"')),
          reason: '不得采用空壳应答');
      expect(OverpassClient.parseRoads(body).length, 2);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('★ 端到端：真实内置列表 + 真实延迟 → DXF 出 DaoLuBian / JianZhu', () async {
      final dir = Directory.systemTemp.createTempSync('qa20_r2_dxf');
      PathProviderPlatform.instance = R2PathProvider(dir.path);
      addTearDown(() => dir.deleteSync(recursive: true));
      final cacheDir = Directory.systemTemp.createTempSync('qa20_r2_cache');
      addTearDown(() => cacheDir.deleteSync(recursive: true));

      // 按 QA 2026-09-13 07:58/07:59 两轮实测重放（信阳 bbox）：
      //   openstreetmap.fr  2.32~3.25s  955 条  ✅最稳
      //   z.overpass-api.de 2.20s       955 条（偶尔 504）
      //   overpass-api.de   2.62~13.3s  955 条
      //   maps.mail.ru      1.83~34.7s  955 条
      //   kumi.systems      504 / 13.3s 935 条
      //   （osm.ch 已下线，但即便它还在列表里也不能抢答 —— 此处仍按 1.05s 空壳注入做双保险）
      OverpassClient.httpGetOverride = (url, {headers}) async {
        final h = url.host;
        final q = url.queryParameters['data'] ?? '';
        if (h == 'overpass.osm.ch') {
          await Future<void>.delayed(const Duration(milliseconds: 1050));
          return r2Ok(r2RealOsmCh); // 空壳（已下线，仅作双保险注入）
        }
        if (h == 'overpass.openstreetmap.fr' || h == 'z.overpass-api.de') {
          await Future<void>.delayed(const Duration(milliseconds: 320));
          return r2Ok(r2BodyFor(q));
        }
        if (h == 'overpass-api.de') {
          await Future<void>.delayed(const Duration(milliseconds: 2620));
          return r2Ok(r2BodyFor(q));
        }
        throw const HttpException('实测：504 / 连接失败');
      };

      final res = await DxfExporter.export(
        name: 'qa20_r2',
        labels: r2Labels(),
        includeSurroundings: true,
        rangeM: 300,
      );
      final text = r2ReadDxf(res.file);
      expect(r2EntitiesOnLayer(text, 'DaoLuBian'), greaterThan(0),
          reason: '用户主诉守卫：修复后 DXF 必须含道路实体');
      expect(r2EntitiesOnLayer(text, 'JianZhu'), greaterThan(0),
          reason: '用户主诉守卫：修复后 DXF 必须含建筑实体');

      // 报告不得谎报：roads/buildings 有数据
      final rep = res.report;
      expect(rep, isNotNull);
      expect(rep!.roads.count, greaterThan(0));
      expect(rep.hasVector, isTrue);
      expect(rep.anyEmptyAnswer, isFalse);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  // ---------- R2-3：emptyAnswer 置位边界 ----------

  group('R2-3 emptyAnswer 置位边界', () {
    test('全部端点都返回 200 空壳 → 空答案收场，且不落缓存、可自救', () async {
      final cacheDir = Directory.systemTemp.createTempSync('qa20_r2_allempty');
      addTearDown(() => cacheDir.deleteSync(recursive: true));
      final cache = BasemapCache(cacheDir);
      OverpassClient.httpGetOverride =
          (url, {headers}) async => r2Ok(r2RealOsmCh);

      final d = await BasemapFetcher.fetchFor(r2Labels(),
          rangeM: 300, cache: cache, useTdt: false);
      expect(d.roads, isEmpty);
      expect(d.report.anyEmptyAnswer, isTrue);
      expect(d.report.statusLines().first, contains('数据源返回空'));
      expect(d.report.statusLines().first, contains('疑似底图镜像故障'));
      expect(d.report.statusLines().first, isNot(contains('该范围内无数据')));
      expect(await cache.read('roads', BasemapFetcher.boundsOf(r2Labels(), 300)),
          isNull,
          reason: '空结果不落缓存 → 用户点重试可自救');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('★ 边界问答：4 个端点硬失败 + 1 个返回空 → emptyAnswer 应置位', () async {
      // 这是工程师点名要 QA 定夺的边界。QA 结论：**应当置位**。
      // 理由：此时我们从未得到一个"该范围确实无数据"的确定答案，
      // 若报"该范围内无数据"等于二次欺骗用户；置位后提示"疑似镜像故障 + 点重试"
      // 是诚实且可操作的。副作用（乡村地区确实无地名时也会提示故障）属可接受噪声。
      final cacheDir = Directory.systemTemp.createTempSync('qa20_r2_mixed');
      addTearDown(() => cacheDir.deleteSync(recursive: true));
      final cache = BasemapCache(cacheDir);
      final eps = OverpassEndpoints.builtin();
      final survivor = eps.first;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        if (url.toString().startsWith(survivor)) return r2Ok(r2RealOsmCh);
        throw const HttpException('实测 504');
      };
      final d = await BasemapFetcher.fetchFor(r2Labels(),
          rangeM: 300, cache: cache, useTdt: false);
      expect(d.roads, isEmpty);
      expect(d.report.anyEmptyAnswer, isTrue,
          reason: '有硬失败 + 空集时不得谎称"该范围内无数据"');
      expect(d.report.statusLines().first, isNot(contains('该范围内无数据')));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('有数据 → 不得置位 emptyAnswer（正常路径不受污染）', () async {
      final cacheDir = Directory.systemTemp.createTempSync('qa20_r2_ok');
      addTearDown(() => cacheDir.deleteSync(recursive: true));
      OverpassClient.httpGetOverride = (url, {headers}) async =>
          r2Ok(r2BodyFor(url.queryParameters['data'] ?? ''));
      final d = await BasemapFetcher.fetchFor(r2Labels(),
          rangeM: 300, cache: BasemapCache(cacheDir), useTdt: false);
      expect(d.roads.length, 2);
      expect(d.buildings, isNotEmpty);
      expect(d.report.anyEmptyAnswer, isFalse);
      expect(d.report.statusLines().first, '道路 2 项');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ---------- R2-4：重试交互与端点清单 ----------

  group('R2-4 重试交互 / 清单', () {
    test('全端点空壳 → 不抛异常、不触发重试轮（调用数 = 端点数）', () async {
      final eps = OverpassEndpoints.builtin();
      var calls = 0;
      final sw = Stopwatch()..start();
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        return r2Ok(r2RealOsmCh);
      };
      final body = await OverpassClient.fetchRaw('[out:json];',
          timeout: const Duration(milliseconds: 300), retries: 1);
      sw.stop();
      expect(body, r2RealOsmCh);
      expect(calls, eps.length,
          reason: '空答案收场不算失败，故不进入重试轮（仅调用 1 轮）');
      expect(sw.elapsedMilliseconds, lessThan(1000),
          reason: '不应白等 1.2s 重试延迟（实测 ${sw.elapsedMilliseconds}ms）');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('全端点硬失败（无空答案）→ 仍抛异常并重试（调用数 = 2 × 端点数）', () async {
      final eps = OverpassEndpoints.builtin();
      var calls = 0;
      OverpassClient.httpGetOverride = (url, {headers}) async {
        calls++;
        throw const HttpException('全灭');
      };
      await expectLater(
          OverpassClient.fetchRaw('[out:json];',
              timeout: const Duration(milliseconds: 200), retries: 1),
          throwsA(isA<HttpException>()));
      expect(calls, eps.length * 2);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('端点清单：5 个且 4 个已下线端点全部不在列表中', () {
      final eps = OverpassEndpoints.builtin();
      expect(eps.length, 6);
      expect(OverpassEndpoints.retired.length, 4);
      for (final bad in OverpassEndpoints.retired) {
        expect(eps, isNot(contains(bad)), reason: '$bad 不得再参与抓取');
      }
      for (final need in [
        'overpass-api.de',
        'overpass.kumi.systems',
        'maps.mail.ru',
        'overpass.openstreetmap.fr',
        'z.overpass-api.de',
      ]) {
        expect(eps.any((e) => e.contains(need)), isTrue,
            reason: '$need 应在列表中');
      }
    });
  });
}
