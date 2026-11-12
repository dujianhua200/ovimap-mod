// QA 复验 O1（"有硬失败 + 空答案收场" 时补一轮重试）。
//
// **独立性**：QA 自写的对抗用例，不复用 batch20_test.dart 的 O1①/②/③，
// 也不依赖工程师 fixture。重点：
//   A O1 主路径（4 硬失败 + 1 空 → 重试把数据抢回来）
//   B 防劣化：**全部 200 空绝不重试**，且用 **wall-clock** 卡死（不能只数调用次数）
//   C 失败路径不得被"轮末统一 delay"多拖 1.2s
//   D 重试轮确实用 ×2 超时（用"只有在 ×2 下才来得及"的慢端点做判别）
//   E 重试轮仍空 → 停止，不无限循环
//   F 端到端：O1 真的把用户导出救回来（DXF 出 DaoLuBian/JianZhu）
//   G 最坏耗时口径 + 正常路径不受影响
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/overpass.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class O1PathProvider extends PathProviderPlatform {
  final String root;
  O1PathProvider(this.root);
  @override
  Future<String?> getExternalStoragePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

http.Response o1Ok(String b, {int status = 200}) => http.Response(
    b, status,
    headers: const {'content-type': 'application/json; charset=utf-8'});

const String o1Empty = '{"version":0.6,"elements":[\n\n  ]}';

String o1Roads() => jsonEncode({
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

String o1Buildings() => jsonEncode({
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

List<MapLabel> o1Labels() => [
      MapLabel(typeId: 'pipe', seq: 1, lat: 32.1264, lon: 114.0913),
      MapLabel(typeId: 'pipe', seq: 2, lat: 32.1274, lon: 114.0923),
      MapLabel(typeId: 'pipe', seq: 3, lat: 32.1284, lon: 114.0933),
    ];

int o1Entities(String dxf, String layer) =>
    RegExp('8\n$layer\n').allMatches(dxf).length;

/// DXF 是 GBK 字节：必须逐字节映射读取，不能按 utf-8 解码。
String o1ReadDxf(File f) => String.fromCharCodes(f.readAsBytesSync());

/// 5 个端点 hos，最后一个为"幸存者"。
const List<String> o1Eps = [
  'https://a.example/api',
  'https://b.example/api',
  'https://c.example/api',
  'https://d.example/api',
  'https://survivor.example/api',
];

bool _isSurvivor(Uri url) => url.host == 'survivor.example';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => OverpassClient.httpGetOverride = null);
  tearDown(() => OverpassClient.httpGetOverride = null);

  // ---------------- A：O1 主路径 ----------------

  test('A. O1 主路径：4 硬失败 + 1 空 → 重试把真实数据抢回来', () async {
    var calls = 0;
    OverpassClient.httpGetOverride = (url, {headers}) async {
      calls++;
      if (!_isSurvivor(url)) throw const HttpException('实测 504');
      // 第一轮：空壳；第二轮起：真实数据
      return calls <= 5 ? o1Ok(o1Empty) : o1Ok(o1Roads());
    };
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: o1Eps,
        timeout: const Duration(milliseconds: 300),
        retries: 1);
    expect(calls, 10, reason: '5 端点 × 2 轮（首轮空答案收场 → 补一轮）');
    expect(r.body, o1Roads(), reason: '重试必须把数据抢回来');
    expect(r.emptyFallback, isFalse, reason: '拿到数据了就不该再是空答案兜底');
    expect(OverpassClient.parseRoads(r.body).length, 2);
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ---------------- B：防劣化（最关键） ----------------

  test('B. ★ 防劣化：全部 200 空 → 绝不重试，且不得白等 1.2s（wall-clock 卡死）',
      () async {
    var calls = 0;
    OverpassClient.httpGetOverride = (url, {headers}) async {
      calls++;
      return o1Ok(o1Empty);
    };
    final sw = Stopwatch()..start();
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: o1Eps,
        timeout: const Duration(milliseconds: 300),
        retries: 1);
    sw.stop();

    expect(calls, 5, reason: '全 200 空 = 该范围确实无数据，重试只是白等');
    expect(r.emptyFallback, isTrue);
    expect(r.hardFailures, 0);
    // 只数调用次数不够：必须确认没有真的睡那 1.2s
    expect(sw.elapsedMilliseconds, lessThan(1000),
        reason: '不得白等 retryDelay(1.2s)：实测 ${sw.elapsedMilliseconds}ms');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('B2. 防劣化：1 个 200 空 + 4 个 200 空（不同内容）也一律不重试', () async {
    var calls = 0;
    OverpassClient.httpGetOverride = (url, {headers}) async {
      calls++;
      return o1Ok('{"version":0.6,"elements": [] }');
    };
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: o1Eps,
        timeout: const Duration(milliseconds: 200),
        retries: 1);
    expect(calls, 5);
    expect(r.hardFailures, 0);
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ---------------- C：失败路径不得被轮末 delay 多拖 ----------------

  test('C. 全硬失败（retries=1）→ 仍 throws 且只等 1 次 delay', () async {
    var calls = 0;
    OverpassClient.httpGetOverride = (url, {headers}) async {
      calls++;
      throw const HttpException('全灭');
    };
    final sw = Stopwatch()..start();
    await expectLater(
        OverpassClient.fetchRawDetailed('[out:json];',
            endpoints: o1Eps,
            timeout: const Duration(milliseconds: 200),
            retries: 1),
        throwsA(isA<HttpException>()));
    sw.stop();
    expect(calls, 10);
    // 200(首轮) + 1200(delay) + 400(重试轮 ×2) ≈ 1800ms；
    // 若 delay 被错误地放到轮末无条件执行，会变成 ≈3000ms
    expect(sw.elapsedMilliseconds, lessThan(2600),
        reason: '失败路径不得多拖一次 1.2s：实测 ${sw.elapsedMilliseconds}ms');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('C2. 全硬失败（retries=0）→ 一次 delay 都不该有', () async {
    var calls = 0;
    OverpassClient.httpGetOverride = (url, {headers}) async {
      calls++;
      throw const HttpException('全灭');
    };
    final sw = Stopwatch()..start();
    await expectLater(
        OverpassClient.fetchRawDetailed('[out:json];',
            endpoints: o1Eps,
            timeout: const Duration(milliseconds: 200),
            retries: 0),
        throwsA(isA<HttpException>()));
    sw.stop();
    expect(calls, 5);
    expect(sw.elapsedMilliseconds, lessThan(900),
        reason: 'retries=0 时不应有任何 delay：实测 ${sw.elapsedMilliseconds}ms');
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ---------------- D：重试轮确实用 ×2 超时 ----------------

  test('D. 重试轮确实用 timeout ×2（只有 ×2 才来得及的慢端点）', () async {
    // 首轮 timeout=500ms；幸存者首轮 50ms 回空壳。
    // 重试轮若按 ×1(500ms)：600ms 的响应会被丢掉 → 只能拿到空答案；
    // 若按 ×2(1000ms)：600ms 的响应来得及 → 拿到数据。用这个差异做判别。
    final sw = Stopwatch()..start();
    var round2LatencyApplied = false;
    OverpassClient.httpGetOverride = (url, {headers}) async {
      if (!_isSurvivor(url)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        throw const HttpException('504');
      }
      // 首轮（<1s 内）回空壳；重试轮（>1s 后）600ms 回数据
      if (!round2LatencyApplied) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return o1Ok(o1Empty);
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
      return o1Ok(o1Roads());
    };
    // 在首轮完成（约 70ms + 1.2s delay 之前）后把标志打开，模拟"第二轮镜像恢复了"
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      round2LatencyApplied = true;
    });

    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: o1Eps,
        timeout: const Duration(milliseconds: 500),
        retries: 1);
    sw.stop();
    expect(r.body, o1Roads(),
        reason: '重试轮必须是 1000ms(×2)，否则 600ms 的响应来不及');
    expect(r.emptyFallback, isFalse);
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ---------------- E：重试轮仍空 → 停止 ----------------

  test('E. 重试轮仍空 → 停止（共 2 轮，不无限循环）', () async {
    var calls = 0;
    OverpassClient.httpGetOverride = (url, {headers}) async {
      calls++;
      if (!_isSurvivor(url)) throw const HttpException('504');
      return o1Ok(o1Empty);
    };
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: o1Eps,
        timeout: const Duration(milliseconds: 200),
        retries: 1);
    expect(calls, 10, reason: 'retries=1 ⇒ 最多 2 轮');
    expect(r.emptyFallback, isTrue);
    expect(r.hardFailures, greaterThan(0));
    expect(r.body, o1Empty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ---------------- F：端到端，O1 真的救回用户导出 ----------------

  test('F. ★ 端到端：O1 真的把用户导出救回来（DXF 出 DaoLuBian / JianZhu）',
      () async {
    final dir = Directory.systemTemp.createTempSync('qa20_o1_dxf');
    PathProviderPlatform.instance = O1PathProvider(dir.path);
    addTearDown(() => dir.deleteSync(recursive: true));
    final cacheDir = Directory.systemTemp.createTempSync('qa20_o1_cache');
    addTearDown(() => cacheDir.deleteSync(recursive: true));

    // 真实内置列表：只有 maps.mail.ru 幸存；首轮回空壳，重试轮回真实数据
    var round = 0;
    OverpassClient.httpGetOverride = (url, {headers}) async {
      final h = url.host;
      if (h == 'maps.mail.ru') {
        if (round == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return o1Ok(o1Empty);
        }
        await Future<void>.delayed(const Duration(milliseconds: 60));
        final q = url.queryParameters['data'] ?? '';
        return o1Ok(q.contains('"building"') ? o1Buildings() : o1Roads());
      }
      throw const HttpException('实测 504');
    };
    // 首轮结束后（约 20ms + 1.2s delay 之前）让镜像"恢复"
    Future<void>.delayed(const Duration(milliseconds: 200), () => round = 1);

    final res = await DxfExporter.export(
      name: 'qa20_o1',
      labels: o1Labels(),
      includeSurroundings: true,
      rangeM: 300,
    );
    final text = o1ReadDxf(res.file);
    expect(o1Entities(text, 'DaoLuBian'), greaterThan(0),
        reason: 'O1 修复后：硬失败+空答案场景也能出道路实体');
    expect(o1Entities(text, 'JianZhu'), greaterThan(0),
        reason: 'O1 修复后：硬失败+空答案场景也能出建筑实体');
    expect(res.report, isNotNull);
    expect(res.report!.hasVector, isTrue);
    expect(res.report!.anyEmptyAnswer, isFalse,
        reason: '重试救回数据后不得再报"疑似镜像故障"');
  }, timeout: const Timeout(Duration(seconds: 120)));

  // ---------------- G：耗时口径 + 正常路径不受影响 ----------------

  test('G. 最坏耗时口径：仅 O1 路径为 12s + 1.2s + 24s；正常路径零额外开销', () async {
    expect(OverpassClient.defaultTimeout, const Duration(seconds: 12));
    expect(OverpassClient.retryDelay, const Duration(milliseconds: 1200));
    expect(OverpassClient.defaultTimeout * OverpassClient.retryTimeoutFactor,
        const Duration(seconds: 24));

    // 正常路径：首轮就有数据 → 立即返回，不吃 1.2s delay
    OverpassClient.httpGetOverride =
        (url, {headers}) async => o1Ok(o1Roads());
    final sw = Stopwatch()..start();
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: o1Eps,
        timeout: const Duration(milliseconds: 300),
        retries: 1);
    sw.stop();
    expect(r.emptyFallback, isFalse);
    expect(r.hardFailures, 0);
    expect(sw.elapsedMilliseconds, lessThan(500),
        reason: '正常路径不得有任何额外等待：实测 ${sw.elapsedMilliseconds}ms');
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ---------------- H：回归：语义与缓存未被 O1 破坏 ----------------

  test('H. 回归：全 200 空 → emptyAnswer 仍置位且仍不落缓存', () async {
    final cacheDir = Directory.systemTemp.createTempSync('qa20_o1_nocache');
    addTearDown(() => cacheDir.deleteSync(recursive: true));
    final cache = BasemapCache(cacheDir);
    OverpassClient.httpGetOverride = (url, {headers}) async => o1Ok(o1Empty);

    final d = await BasemapFetcher.fetchFor(o1Labels(),
        rangeM: 300, cache: cache, useTdt: false);
    expect(d.report.anyEmptyAnswer, isTrue);
    expect(d.report.statusLines().first, contains('数据源返回空'));
    expect(d.report.statusLines().first, isNot(contains('该范围内无数据')));
    expect(await cache.read('roads', BasemapFetcher.boundsOf(o1Labels(), 300)),
        isNull,
        reason: '空结果不落缓存 → 用户点重试可自救（O1 不得破坏这条）');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
