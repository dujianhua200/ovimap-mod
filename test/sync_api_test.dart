// T14：SyncApi 网络层语义（零网络，注入内存 Worker）。
//   统一响应 {code,data,message}；401；409 → PutConflict；rev 递增。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ovimap/sync/sync_api.dart';
import 'package:ovimap/sync/sync_models.dart';

import '_sync_fake_server.dart';

void main() {
  const base = 'https://sync.example.com';
  late FakeSyncServer fake;

  setUp(() {
    fake = FakeSyncServer(token: 'tok-test');
    fake.install();
  });

  tearDown(() => fake.uninstall());

  SyncApi api({String token = 'tok-test'}) => SyncApi(
        base: base,
        token: token,
        deviceId: 'dev-A',
        deviceName: '电脑-A',
      );

  test('ping：连通 → true', () async {
    expect(await api().ping(), isTrue);
  });

  test('401：令牌错误 → fetchIndex 抛 SyncApiException(401)', () async {
    final bad = api(token: 'wrong');
    expect(await bad.ping(), isFalse, reason: 'ping 吞异常返回 false');
    await expectLater(
      bad.fetchIndex(),
      throwsA(isA<SyncApiException>()
          .having((e) => e.status, 'status', 401)),
    );
  });

  test('请求头携带 Bearer + X-Device-Id/Name', () async {
    Map<String, String>? seen;
    SyncApi.httpGetOverride = (url, {headers}) async {
      seen = headers;
      return http.Response(
          jsonEncode({'code': 0, 'data': {'items': []}, 'message': 'ok'}), 200);
    };
    await api().fetchIndex();
    expect(seen!['Authorization'], 'Bearer tok-test');
    expect(seen!['X-Device-Id'], 'dev-A');
    expect(seen!['X-Device-Name'], '电脑-A');
  });

  test('fetchIndex：解析 items', () async {
    fake.projects['c1'] = FakeProject()
      ..rev = 3
      ..name = '甲'
      ..updatedAt = 100
      ..lastDeviceName = '手机';
    final idx = await api().fetchIndex();
    expect(idx.items.length, 1);
    expect(idx.items.first.id, 'c1');
    expect(idx.items.first.rev, 3);
    expect(idx.items.first.lastDeviceName, '手机');
  });

  test('fetchProject：不存在 → null；存在 → payload/meta', () async {
    expect(await api().fetchProject('nope'), isNull);

    await api().putProject('c1',
        baseRev: 0,
        name: '甲',
        kind: 'label',
        folder: '',
        editMode: 'design',
        count: 2,
        payload: '{"id":"c1","labels":[{},{},{}]}',
        updatedAt: 1);

    final snap = await api().fetchProject('c1');
    expect(snap, isNotNull);
    expect(snap!.rev, 1);
    expect(snap.meta['name'], '甲');
    expect(snap.payload, contains('labels'));
  });

  test('putProject：新建 → PutOk(1)；baseRev 匹配 → PutOk(rev+1)', () async {
    final r1 = await api().putProject('c1',
        baseRev: 0,
        name: '甲',
        kind: 'label',
        folder: '',
        editMode: 'design',
        count: 1,
        payload: '{"labels":[{}]}',
        updatedAt: 1);
    expect(r1, isA<PutOk>());
    expect((r1 as PutOk).rev, 1);

    final r2 = await api().putProject('c1',
        baseRev: 1,
        name: '甲',
        kind: 'label',
        folder: '',
        editMode: 'design',
        count: 2,
        payload: '{"labels":[{},{}]}',
        updatedAt: 2);
    expect((r2 as PutOk).rev, 2);
  });

  test('putProject：baseRev 不匹配 → PutConflict(serverRev)', () async {
    await api().putProject('c1',
        baseRev: 0,
        name: '甲',
        kind: 'label',
        folder: '',
        editMode: 'design',
        count: 1,
        payload: '{"labels":[{}]}',
        updatedAt: 1);
    final r = await api().putProject('c1',
        baseRev: 0, // 服务端已到 1
        name: '甲',
        kind: 'label',
        folder: '',
        editMode: 'design',
        count: 1,
        payload: '{"labels":[{}]}',
        updatedAt: 3);
    expect(r, isA<PutConflict>());
    expect((r as PutConflict).serverRev, 1);
  });

  test('putProject：缺 baseRev 且工程已存在 → 409（保守不覆盖）', () async {
    await api().putProject('c1',
        baseRev: 0,
        name: '甲',
        kind: 'label',
        folder: '',
        editMode: 'design',
        count: 1,
        payload: '{"labels":[{}]}',
        updatedAt: 1);
    // 直接构造一个不带 baseRev 的请求体（模拟旧版客户端）。
    SyncApi.httpSendOverride = (method, url, {headers, body}) async {
      final map = body is String
          ? Map<String, dynamic>.from(jsonDecode(body) as Map)
          : Map<String, dynamic>.from(body as Map);
      map.remove('baseRev');
      return fake.handleSendRaw(method, url,
          headers: headers, bodyText: jsonEncode(map));
    };
    final r = await api().putProject('c1',
        baseRev: 99, // 会被覆盖移除
        name: '甲',
        kind: 'label',
        folder: '',
        editMode: 'design',
        count: 1,
        payload: '{"labels":[{}]}',
        updatedAt: 1);
    expect(r, isA<PutConflict>());
  });

  test('deleteProject：软删除 rev+1；history 可见旧版本', () async {
    await api().putProject('c1',
        baseRev: 0,
        name: '甲',
        kind: 'label',
        folder: '',
        editMode: 'design',
        count: 1,
        payload: '{"labels":[{}]}',
        updatedAt: 1);
    final d = await api().deleteProject('c1', baseRev: 1);
    expect((d as PutOk).rev, 2);
    expect(fake.projects['c1']!.deleted, isTrue);

    final hist = await api().history('c1');
    expect(hist.map((v) => v.rev), contains(1));
  });

  test('restore：恢复到旧版本 → 生成新 rev 并复活', () async {
    await api().putProject('c1',
        baseRev: 0,
        name: '甲',
        kind: 'label',
        folder: '',
        editMode: 'design',
        count: 1,
        payload: '{"labels":[{"id":"a"}]}',
        updatedAt: 1);
    await api().deleteProject('c1', baseRev: 1);

    final newRev = await api().restore('c1', 1);
    expect(newRev, 3);
    expect(fake.projects['c1']!.deleted, isFalse);
    final snap = await api().fetchProject('c1', rev: newRev);
    expect(snap!.payload, contains('"a"'));
  });
}
