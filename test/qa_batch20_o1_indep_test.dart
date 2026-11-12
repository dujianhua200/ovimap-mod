// QA 复验 O1（第二十批收尾）——**QA 自写对抗用例**（不复用工程师 batch20_test.dart 的 mock）。
//
// 覆盖目标：
//  O1① 有硬失败 + 空答案收场 → 必须再抢一轮，并真的把数据救回来（calls == 2 × N）
//  O1② 全部 200 空（真·无数据）→ **绝不**重试（wall-clock 卡死防 72s 劣化）
//  O1③ 全硬失败 → 仍重试一轮并抛 HttpException
//  O1④ delay 挪到轮末的等价性：只在**轮间**等，**最后一轮之后不等**
//  O1⑤ 反向用例：已经有真数据时（哪怕同时有硬失败）**不得**多此一举重试
//  回归：空 elements 抢不赢竞速 / 端点列表 5 个且不含下线 4 个 / 空结果不落缓存
//
// 机制与 batch20_test.dart 不同：按**主机**分别计数（而非全局 calls 计数），
// 可直接断言"每个端点各被叫了几次"，从而证明"整轮重试"确实发生、且没有多余轮次。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/overpass.dart';
import 'package:ovimap/models/map_label.dart';

// ---------------- QA 自有夹具（与 batch20_test.dart 完全不同） ----------------

const double _lat = 31.8642;
const double _lon = 117.2311;

/// 空数据集应答（伪装成"正常但没数据"的 Overpass 响应）。
String _emptyBody() =>
    '{"version":0.6,"generator":"QA-O1-mirror","elements":[]}';

/// 真数据应答（QA 自有标记 QA-O1-REAL，便于与工程师夹具区分）。
String _realBody() => jsonEncode({
      'version': 0.6,
      'generator': 'QA-O1-REAL',
      'elements': [
        {
          'type': 'way',
          'id': 1,
          'geometry': [
            {'lat': _lat, 'lon': _lon - 0.002},
            {'lat': _lat, 'lon': _lon + 0.002},
          ],
          'tags': {'highway': 'trunk', 'name': 'QA-O1-真数据大道'}
        }
      ],
    });

/// 构造 mock 响应：**必须显式声明 utf-8**，否则 http.Response 默认按 Latin-1 编码，
/// 含中文的 JSON 会抛 "Contains invalid characters"（QA 自测踩坑记录）。
http.Response _resp(String body, [int code = 200]) => http.Response(body, code,
    headers: const {'content-type': 'application/json; charset=utf-8'});

// ---------------- mock 机械 ----------------

/// 单个端点的脚本：第 n 次调用时做什么。
class _Scripted {
  _Scripted(this.host, this.onCall);
  final String host;
  final Future<http.Response> Function(int callIndex) onCall;
  int calls = 0;
}

/// 可注入 HTTP 钩子的竞速舞台：按**主机**计数，并顺带校验请求头未被改坏。
class _Stage {
  _Stage(this.eps) {
    OverpassClient.httpGetOverride = get;
  }
  final List<_Scripted> eps;
  int total = 0;

  List<String> get endpoints =>
      eps.map((e) => 'https://${e.host}/api/interpreter').toList();

  Future<http.Response> get(Uri url, {Map<String, String>? headers}) async {
    final host = url.host;
    final ep = eps.firstWhere((e) => e.host == host,
        orElse: () => throw StateError('未注册的端点: $host'));
    if (headers?['User-Agent'] == null) {
      throw StateError('请求未带 User-Agent（协议回归）');
    }
    final n = ++ep.calls;
    total++;
    return ep.onCall(n);
  }
}

/// 恒硬失败（504 / 连接失败 —— 都计入 hardFailures）。
_Scripted _dead(String host, {String how = 'HttpException'}) => _Scripted(
      host,
      (n) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw HttpException('mock $how #$n @$host');
      },
    );

/// 第 1 次给空答案，之后给真数据（"故障镜像第一轮空壳、重试轮救回"）。
_Scripted _emptyThenReal(String host) => _Scripted(
      host,
      (n) async {
        await Future<void>.delayed(const Duration(milliseconds: 15));
        return _resp(n == 1 ? _emptyBody() : _realBody());
      },
    );

/// 恒返回 200 空集。
_Scripted _alwaysEmpty(String host, {int delayMs = 12}) => _Scripted(
      host,
      (n) async {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        return _resp(_emptyBody());
      },
    );

_Scripted _slowReal(String host, int delayMs) => _Scripted(
      host,
      (n) async {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        return _resp(_realBody());
      },
    );

/// 5 个端点形态（对齐内置列表数量）。
List<String> _fiveHosts() => [
      'qa-a.invalid',
      'qa-b.invalid',
      'qa-c.invalid',
      'qa-d.invalid',
      'qa-e.invalid'
    ];

void main() {
  tearDown(() => OverpassClient.httpGetOverride = null);

  // ============ O1① 最关键：4 恒失败 + 1 先空后真 → 必须再抢一轮 ============

  test('O1①：4 端点恒硬失败 + 1 端点空壳 → 再抢一轮并**真的拿到数据**', () async {
    final eps = <_Scripted>[
      _dead('qa-a.invalid'),
      _dead('qa-b.invalid'),
      _dead('qa-c.invalid'),
      _dead('qa-d.invalid'),
      _emptyThenReal('qa-e.invalid'), // 第一轮空壳，第二轮真数据
    ];
    final st = _Stage(eps);
    final sw = Stopwatch()..start();
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: st.endpoints, timeout: const Duration(milliseconds: 400));
    sw.stop();

    // 每个端点都被叫了 2 次 ⇒ 整轮确实又跑了一遍（共 10 次）。
    expect(st.total, 10, reason: '首轮 5 + 重试轮 5；每端点应各被呼叫 2 次');
    for (final e in eps) {
      expect(e.calls, 2, reason: '${e.host} 应在两轮中各被调用一次');
    }
    expect(r.body, _realBody(), reason: '重试轮必须用真数据收场');
    expect(r.emptyFallback, isFalse, reason: '拿到真数据就不算空答案兜底');
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(1000),
        reason: '确实跨过了 1.2s 重试间隔（实测 ${sw.elapsedMilliseconds}ms）');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('O1①-b：504 / 非数据应答 / 超时 三种硬失败形态都要触发重试', () async {
    final eps = <_Scripted>[
      _dead('qa-a.invalid', how: 'http 504'),
      _Scripted('qa-b.invalid', (n) async {
        // 200 但不是数据（缺 "elements"）⇒ 非数据应答
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return _resp('<html>error page without elements</html>', 200);
      }),
      _Scripted('qa-c.invalid', (n) async {
        // 慢到超过单轮超时 ⇒ 按超时计硬失败（比首轮 400ms / 重试轮 800ms 都慢）
        await Future<void>.delayed(const Duration(milliseconds: 2000));
        return _resp(_realBody());
      }),
      _dead('qa-d.invalid', how: 'SocketException'),
      _emptyThenReal('qa-e.invalid'),
    ];
    final st = _Stage(eps);
    final sw = Stopwatch()..start();
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: st.endpoints, timeout: const Duration(milliseconds: 400));
    sw.stop();

    expect(st.total, 10, reason: '504 / 非数据应答 / 超时 都算硬失败 ⇒ 应再抢一轮');
    expect(r.body, _realBody());
    expect(r.emptyFallback, isFalse);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(1000));
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ============ O1② 最关心：全 200 空 → 绝不重试（防 72s 劣化） ============

  test('O1②：5 端点全部 200 空 → 一轮收工、不重试、不白等', () async {
    final eps = _fiveHosts().map(_alwaysEmpty).toList();
    final st = _Stage(eps);
    final sw = Stopwatch()..start();
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: st.endpoints, timeout: const Duration(milliseconds: 400));
    sw.stop();

    expect(st.total, 5, reason: '全是 200 空 = 该范围真没数据，第二轮纯属白等');
    for (final e in eps) {
      expect(e.calls, 1, reason: '${e.host} 不得被二次调用');
    }
    expect(r.body, _emptyBody());
    expect(r.emptyFallback, isTrue);
    expect(r.hardFailures, 0, reason: '空答案**不算**硬失败');
    expect(sw.elapsedMilliseconds, lessThan(1000),
        reason: '绝不能等到 1.2s 重试间隔（实测 ${sw.elapsedMilliseconds}ms）');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('O1②-b：retries=3 时全空也只跑一轮（不得放大成更多轮）', () async {
    final eps = _fiveHosts().map(_alwaysEmpty).toList();
    final st = _Stage(eps);
    final sw = Stopwatch()..start();
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: st.endpoints,
        timeout: const Duration(milliseconds: 400),
        retries: 3);
    sw.stop();
    expect(st.total, 5, reason: 'retries 再大也不能在无数据时空转');
    expect(r.emptyFallback, isTrue);
    expect(sw.elapsedMilliseconds, lessThan(1000));
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ============ O1③：全硬失败 → 仍重试一轮并抛异常 ============

  test('O1③：5 端点全硬失败 → 重试一轮（10 次调用）后抛 HttpException', () async {
    final eps = _fiveHosts().map((h) => _dead(h)).toList();
    final st = _Stage(eps);
    Object? thrown;
    try {
      await OverpassClient.fetchRawDetailed('[out:json];',
          endpoints: st.endpoints, timeout: const Duration(milliseconds: 300));
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isA<HttpException>(), reason: '全灭必须抛 HttpException');
    expect('$thrown', contains('已重试 1 次'), reason: '异常文案保留重试次数便于排障');
    expect(st.total, 10, reason: '全灭场景按既有策略重试一轮');
    for (final e in eps) {
      expect(e.calls, 2, reason: '${e.host} 应参与两轮');
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ============ ④ delay 挪动的等价性：只在轮间等，末轮之后不等 ============

  test('④-a：retries=2 全灭 → 恰好 2 次轮间等待（3 轮 + 2 等待）', () async {
    final eps = _fiveHosts().map((h) => _dead(h)).toList();
    final st = _Stage(eps);
    final sw = Stopwatch()..start();
    Object? thrown;
    try {
      await OverpassClient.fetchRawDetailed('[out:json];',
          endpoints: st.endpoints,
          timeout: const Duration(milliseconds: 300),
          retries: 2);
    } catch (e) {
      thrown = e;
    }
    sw.stop();
    expect(thrown, isA<HttpException>());
    expect(st.total, 15, reason: '3 轮 × 5 端点');
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(2400),
        reason: '两次轮间等待都应发生（实测 ${sw.elapsedMilliseconds}ms）');
    expect(sw.elapsedMilliseconds, lessThan(3400),
        reason:
            '**末轮之后不得再等**第三个 1.2s（否则延迟 | 实测 ${sw.elapsedMilliseconds}ms）');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('④-b：O1 重试路径只等一次（成功返回后不再补一次多余等待）', () async {
    final eps = <_Scripted>[
      _dead('qa-a.invalid'),
      _emptyThenReal('qa-e.invalid'),
    ];
    final st = _Stage(eps);
    final sw = Stopwatch()..start();
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: st.endpoints, timeout: const Duration(milliseconds: 300));
    sw.stop();
    expect(st.total, 4);
    expect(r.body, _realBody());
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(1000),
        reason: '轮间等待必须发生');
    expect(sw.elapsedMilliseconds, lessThan(2300),
        reason: '成功返回后不得再等一次 1.2s（实测 ${sw.elapsedMilliseconds}ms）');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('④-c：O1 重试轮仍空且仍有硬失败 → 恰好收敛于 2 轮', () async {
    final eps = <_Scripted>[
      _dead('qa-a.invalid'),
      _dead('qa-b.invalid'),
      _alwaysEmpty('qa-e.invalid'),
    ];
    final st = _Stage(eps);
    final sw = Stopwatch()..start();
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: st.endpoints, timeout: const Duration(milliseconds: 300));
    sw.stop();
    expect(st.total, 6, reason: '2 轮 × 3 端点，之后必须收敛，不得无限重试');
    expect(r.emptyFallback, isTrue);
    expect(r.hardFailures, greaterThan(0));
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(1000));
    expect(sw.elapsedMilliseconds, lessThan(2300), reason: '只等一次');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('④-d：首轮即成功 → 不应有任何额外等待', () async {
    final eps = <_Scripted>[
      _alwaysEmpty('qa-e.invalid', delayMs: 20),
      _slowReal('qa-a.invalid', 120),
    ];
    final st = _Stage(eps);
    final sw = Stopwatch()..start();
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: st.endpoints, timeout: const Duration(milliseconds: 600));
    sw.stop();
    expect(st.total, 2, reason: '拿到真数据后不得再发起重试');
    expect(r.body, _realBody());
    expect(sw.elapsedMilliseconds, lessThan(1000), reason: '成功路径零额外等待');
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ============ ⑤ 反向：已有真数据（哪怕伴随硬失败）不得多此一举重试 ============

  test('⑤-a：4 恒失败 + 1 空壳(快) + 1 慢真数据 → 立即收工，不重试', () async {
    final eps = <_Scripted>[
      _dead('qa-a.invalid'),
      _dead('qa-b.invalid'),
      _dead('qa-c.invalid'),
      _dead('qa-d.invalid'),
      _alwaysEmpty('qa-e.invalid', delayMs: 20),
      _slowReal('qa-f.invalid', 350),
    ];
    final st = _Stage(eps);
    final sw = Stopwatch()..start();
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: st.endpoints, timeout: const Duration(milliseconds: 900));
    sw.stop();
    expect(st.total, 6, reason: '已拿到真数据 ⇒ 不得因为"存在硬失败"就再抢一轮');
    for (final e in eps) {
      expect(e.calls, 1, reason: '${e.host} 不得重复调用');
    }
    expect(r.body, _realBody(), reason: '空壳不得抢答');
    expect(r.emptyFallback, isFalse);
    expect(sw.elapsedMilliseconds, lessThan(1200), reason: '不得白等重试间隔');
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ============ ⑥ 已通过成果回归确认 ============

  test('⑥-a：内置端点 6 个且不含任何已下线端点', () {
    final builtin = OverpassEndpoints.builtin();
    expect(builtin.length, 6, reason: 'v3.5.0 起首位为自建 hzyt 反代');
    for (final dead in OverpassEndpoints.retired) {
      expect(builtin, isNot(contains(dead)), reason: '下线端点 $dead 不得复活');
      expect(OverpassEndpoints.resolve(''), isNot(contains(dead)));
    }
    expect(builtin.any((e) => e.contains('overpass-api.de')), isTrue);
    expect(builtin.any((e) => e.contains('overpass.kumi.systems')), isTrue);
    expect(builtin.any((e) => e.contains('maps.mail.ru')), isTrue);
    expect(builtin.any((e) => e.contains('overpass.openstreetmap.fr')), isTrue);
    expect(builtin.any((e) => e.contains('z.overpass-api.de')), isTrue);
    expect(OverpassEndpoints.retired.length, 4);
    expect(OverpassEndpoints.retired,
        contains(OverpassEndpoints.retiredOsmCh),
        reason: '空壳镜像 osm.ch 应保留在 retired 名单供测试对照');
  });

  test('⑥-b：空 elements 抢不赢竞速（空壳最快也要等真数据）', () async {
    final eps = <_Scripted>[
      _alwaysEmpty('qa-e.invalid', delayMs: 20), // 空壳：最快
      _slowReal('qa-a.invalid', 300), // 真数据：慢
    ];
    final st = _Stage(eps);
    final sw = Stopwatch()..start();
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: st.endpoints, timeout: const Duration(milliseconds: 800));
    sw.stop();
    expect(r.body, _realBody(), reason: '空答案不得赢下竞速');
    expect(r.emptyFallback, isFalse);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(280),
        reason: '确实用真数据收场（等到了慢端点）');
    expect(st.total, 2, reason: '成功即收，不得重试');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('⑥-c：非数据应答（200 但无 elements）仍计硬失败', () async {
    final eps = <_Scripted>[
      _Scripted('qa-a.invalid', (n) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return _resp('<html>rate limited</html>', 200);
      }),
      _alwaysEmpty('qa-e.invalid'),
    ];
    final st = _Stage(eps);
    final r = await OverpassClient.fetchRawDetailed('[out:json];',
        endpoints: st.endpoints, timeout: const Duration(milliseconds: 300));
    expect(st.total, 4, reason: '非数据应答算硬失败 ⇒ 配合空答案触发重试');
    expect(r.emptyFallback, isTrue);
    expect(r.hardFailures, greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('⑥-d：空结果**不落缓存**（第二次抓取仍走网络）', () async {
    final dir = Directory.systemTemp.createTempSync('qa_o1_cache');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = BasemapCache(dir);
    // fetchFor **不注入 endpoints**，走真实内置列表 ⇒ mock 必须按内置端点主机建戶。
    final hosts = OverpassEndpoints.builtin()
        .map((e) => Uri.parse(e).host)
        .toList();
    final eps = hosts.map(_alwaysEmpty).toList();
    final st = _Stage(eps);
    final labels = [
      MapLabel(
          typeId: 'pipe', seq: 1, lat: _lat, lon: _lon, lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe', seq: 2, lat: _lat, lon: _lon + 0.001, lineGroupId: 'g'),
    ];

    final first = await BasemapFetcher.fetchFor(labels,
        rangeM: 500, cache: cache, useTdt: false, tdtKey: '', amapKey: '');
    final afterFirst = st.total;
    expect(afterFirst, greaterThan(0), reason: '首次抓取应发起网络请求');
    expect(first.roads, isEmpty);
    expect(first.buildings, isEmpty);
    expect(
        dir.listSync(recursive: true).where((e) => e is File).length, 0,
        reason: '空结果不得留下任何缓存文件（写盘 = 36500 天毒化）');

    final second = await BasemapFetcher.fetchFor(labels,
        rangeM: 500, cache: cache, useTdt: false, tdtKey: '', amapKey: '');
    expect(st.total, afterFirst * 2,
        reason: '空结果若被写进 36500 天项目级缓存，第二次就不会再联网（毒化回归）');
    expect(second.roads, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('⑥-e：hasEmptyElements 仍识别各种排版；真数据不误判', () {
    expect(OverpassClient.hasEmptyElements('{"elements":[]}'), isTrue);
    expect(OverpassClient.hasEmptyElements('{"elements" : [  ]}'), isTrue);
    expect(OverpassClient.hasEmptyElements('{"elements":[\n]}'), isTrue);
    expect(OverpassClient.hasEmptyElements(_realBody()), isFalse);
  });
}
