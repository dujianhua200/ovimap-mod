// T20：版本历史与恢复——行为链（列历史 → 一键恢复 → 本地刷新为新 rev）
//      + 无配置/断网时入口的中文提示分支。
// 全程零网络（注入内存 Worker），不触真实平台通道。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/device_identity.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/sync/sync_controller.dart';
import 'package:ovimap/sync/sync_models.dart';
import 'package:ovimap/ui/sync/sync_panel.dart';

import '_fs_cleanup.dart';
import '_sync_fake_server.dart';

const kBase = 'https://sync.example.com';
final store = LabelStore.instance;

List<MapLabel> labelsN(String tag, int n) => [
      for (var i = 0; i < n; i++)
        MapLabel(typeId: 'pipe', seq: i + 1, lat: 32.0 + i * 0.001, lon: 114.0)
          ..id = '$tag-$i',
    ];

void main() {
  late Directory dir;
  late FakeSyncServer fake;
  late DeviceIdentity identity;
  final controllers = <SyncController>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_hist');
    store.setBaseDirForTest(dir);
    fake = FakeSyncServer(token: 'tok-test')..install();
    identity = DeviceIdentity.forTest(
      deviceId: 'dev-A',
      deviceName: '电脑-A',
      token: 'tok-test',
      serverBase: kBase,
    );
  });

  tearDown(() async {
    for (final c in controllers) {
      c.dispose();
    }
    controllers.clear();
    fake.uninstall();
    AppPaths.clearForTest();
    // 退让重试：Windows 上在途异步写盘会短暂锁住临时目录（errno=32）。
    await deleteTempDirResilient(dir);
  });

  SyncController makeController() {
    final sc = SyncController(
      store: store,
      identity: identity,
      uploadDebounce: const Duration(hours: 1),
    )..autoPoll = false;
    controllers.add(sc);
    return sc;
  }

  Future<String> makeLocal(String name, int n) => store.finishCollection(
        name: name,
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(name, n),
      );

  Future<void> editLocal(String cid, String name, int n) =>
      store.finishCollection(
        existingId: cid,
        name: name,
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(name, n),
      );

  test('行为链：列历史（rev/设备/点数，倒序）→ 恢复旧版本 → 本地刷为新 rev', () async {
    final c1 = await makeLocal('甲', 2);
    final sc = makeController();
    await sc.start();
    expect(fake.projects[c1]!.rev, 1, reason: '首传 → rev1（2 点）');

    await editLocal(c1, '甲', 3);
    sc.onLocalSaved(c1);
    await sc.flushQueue();
    expect(fake.projects[c1]!.rev, 2, reason: '二次保存 → rev2（3 点）');

    // —— 列历史：最新在前，含 rev/设备名/点数 ——
    final vs = await sc.listHistory(c1);
    expect(vs, isNotNull);
    expect(vs!.length, 2);
    expect(vs.first.rev, 2);
    expect(vs.last.rev, 1);
    expect(vs.first.deviceName, '电脑-A');
    expect(vs.first.labelCount, 3);
    expect(vs.last.labelCount, 2);
    expect(sc.lastError, isEmpty);

    // —— 一键恢复到 rev1 → 服务端生成新 rev，本地刷回 2 点 ——
    final ok = await sc.restoreVersion(c1, 1);
    expect(ok, isTrue);
    expect(fake.projects[c1]!.rev, 3, reason: '恢复 = 新 rev（架构已定）');
    final ls = await store.loadCollection(c1);
    expect(ls.length, 2, reason: '本地应刷回 rev1 的 2 点');
    expect(sc.statusFor(c1), SyncStatus.synced);
    expect(sc.pendingCount, 0);

    // —— 旧快照仍在历史里，可再恢复 ——
    final vs2 = await sc.listHistory(c1);
    expect(vs2!.map((v) => v.rev), containsAll(<int>[1, 2, 3]));
  });

  test('恢复后清掉本工程待上传项（旧脏数据不会盖回去）', () async {
    final c1 = await makeLocal('甲', 2);
    final sc = makeController();
    await sc.start();

    // 制造一个待上传（debounce 未触发，留在队里）。
    await editLocal(c1, '甲', 4);
    sc.onLocalSaved(c1);
    expect(sc.pendingCount, 1, reason: '应有 1 个待上传');

    final ok = await sc.restoreVersion(c1, 1);
    expect(ok, isTrue);
    expect(sc.pendingCount, 0, reason: '恢复即「以服务端为准」，应清空待上传');
    expect(fake.projects[c1]!.rev, 2);
    expect((await store.loadCollection(c1)).length, 2);
  });

  test('未配置 / 断网：listHistory 返回 null（入口走中文提示，不崩）', () async {
    // 未配置身份 → 直接 null。
    final sc2 = SyncController(
      store: store,
      identity: DeviceIdentity.forTest(token: '', serverBase: ''),
      uploadDebounce: const Duration(hours: 1),
    )..autoPoll = false;
    controllers.add(sc2);
    expect(await sc2.listHistory('x'), isNull);
    expect(sc2.configured, isFalse);

    // 已配置但断网 → null + lastError 非空（不抛异常）。
    final c1 = await makeLocal('甲', 1);
    final sc = makeController();
    await sc.start();
    fake.offline = true;
    expect(await sc.listHistory(c1), isNull);
    expect(sc.lastError, isNotEmpty);
  });

  testWidgets('历史入口（未接入同步）→ 中文提示，不崩', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showVersionHistoryDialog(ctx, null, 'cid', '甲'),
              child: const Text('历史版本'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('历史版本'));
    await tester.pump(); // 触发 SnackBar
    expect(find.text('未配置云同步，请在「同步设置」里填入令牌'), findsOneWidget);
  });

  testWidgets('历史入口（cid 为空）→ 中文提示「暂无历史版本」', (tester) async {
    // 用一个「已配置」的控制器（token 非空），但 cid 为空 → 走空 cid 分支。
    final sc = SyncController(
      store: store,
      identity: DeviceIdentity.forTest(
        deviceId: 'd',
        deviceName: 'n',
        token: 'tok',
        serverBase: kBase,
      ),
      uploadDebounce: const Duration(hours: 1),
    )..autoPoll = false;
    controllers.add(sc);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showVersionHistoryDialog(ctx, sc, '', '甲'),
              child: const Text('历史版本2'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('历史版本2'));
    await tester.pump();
    expect(find.text('该工程尚未同步，暂无历史版本'), findsOneWidget);
  });
}
