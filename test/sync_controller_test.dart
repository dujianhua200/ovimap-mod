// T15/T16：SyncController 编排——首次上传、离线队列（入队/按序重放/出队/失败保留）、
// debounce 合并、冲突三选一（保留云端/保留本机/另存副本）、软删除跟随与历史恢复。
// 全程零网络（注入内存 Worker），零真实平台通道。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/device_identity.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/sync/sync_api.dart';
import 'package:ovimap/sync/sync_controller.dart';
import 'package:ovimap/sync/sync_models.dart';

import '_fs_cleanup.dart';
import '_sync_fake_server.dart';

const kBase = 'https://sync.example.com';
final store = LabelStore.instance;

List<MapLabel> labelsN(String cid, int n) => [
      for (var i = 0; i < n; i++)
        MapLabel(
            typeId: 'pipe', seq: i + 1, lat: 32.0 + i * 0.001, lon: 114.0)
          ..id = '$cid-$i',
    ];

String serverPayload(String cid, String name) => jsonEncode(<String, dynamic>{
      'id': cid,
      'name': name,
      'kind': 'label',
      'labels': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'srv',
          'typeId': 'pipe',
          'seq': 1,
          'lat': 31.0,
          'lon': 113.0,
        }
      ],
    });

void main() {
  late Directory dir;
  late FakeSyncServer fake;
  late DeviceIdentity identity;
  final controllers = <SyncController>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_sync_ctrl');
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

  SyncController makeController({Duration? debounce}) {
    final sc = SyncController(
      store: store,
      identity: identity,
      uploadDebounce: debounce ?? const Duration(hours: 1),
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

  test('启动：拉索引 + 首传本地工程 → 服务端 rev=1，状态 synced', () async {
    final c1 = await makeLocal('甲', 2);
    final sc = makeController();
    await sc.start();

    expect(fake.projects.containsKey(c1), isTrue);
    expect(fake.projects[c1]!.rev, 1);
    expect(sc.statusFor(c1), SyncStatus.synced);
    expect(sc.pendingCount, 0);
  });

  test('离线队列：断网入队（保留）→ 恢复后按序重放并出队', () async {
    final c1 = await makeLocal('甲', 1);
    await Future<void>.delayed(const Duration(milliseconds: 3));
    final c2 = await makeLocal('乙', 1);
    final sc = makeController();

    // —— 断网：两次保存都进队，且不丢 ——
    fake.offline = true;
    sc.onLocalSaved(c1);
    await Future<void>.delayed(const Duration(milliseconds: 3));
    sc.onLocalSaved(c2);
    expect(sc.pendingCount, 2);
    await sc.flushQueue();
    expect(sc.pendingCount, 2, reason: '网络错误：应保留在队，不丢');
    expect(sc.statusFor(c1), SyncStatus.pendingUpload);
    expect(sc.statusFor(c2), SyncStatus.pendingUpload);

    // —— 恢复：按入队顺序重放，成功后出队 ——
    fake.offline = false;
    await sc.flushQueue();
    expect(sc.pendingCount, 0);
    expect(sc.statusFor(c1), SyncStatus.synced);
    expect(sc.statusFor(c2), SyncStatus.synced);
    expect(fake.projects[c1]!.rev, 1);
    expect(fake.projects[c2]!.rev, 1);

    final puts =
        fake.log.where((e) => e.startsWith('PUT /project/')).toList();
    expect(puts.length, 2);
    expect(puts[0], 'PUT /project/$c1', reason: '应按 enqueuedAt 升序重放');
    expect(puts[1], 'PUT /project/$c2');
  });

  test('debounce：连续保存合并为一次上传', () async {
    final c1 = await makeLocal('甲', 1);
    final sc = makeController(debounce: const Duration(milliseconds: 50));
    await sc.start();
    final before = fake.putCount;

    // ⚠️ 这里刻意「先把两次落盘做完，再紧邻发两次本地已保存通知」。
    //
    // 原先的写法是把 editLocal（真实文件 I/O）夹在两次 onLocalSaved 之间。
    // 那样测试结论就依赖磁盘耗时：Windows runner 上这次写盘一旦超过 debounce
    // 窗口，第一次通知的定时器已经触发并发出 PUT，最终变成 2 次 PUT 而不是 1 次，
    // 用例随机失败（实测同一提交在两次 CI 上时过时不过）。
    //
    // 被验语义是「debounce 对 onLocalSaved 的合并」，通知相邻调用即可完整覆盖，
    // 不必也不该让结论取决于磁盘快慢。
    await editLocal(c1, '甲', 2);
    await editLocal(c1, '甲', 3);
    sc.onLocalSaved(c1);
    sc.onLocalSaved(c1); // 紧邻再次通知 → 应重置 debounce 并合并

    // 等待要留足余量：慢 runner 上定时器可能比标称值晚触发。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(fake.putCount, before + 1, reason: '两次保存应合并为一次 PUT');
    expect(sc.statusFor(c1), SyncStatus.synced);
    expect(fake.projects[c1]!.rev, 2);
  });

  test('冲突-保留云端：本地被云端覆盖', () async {
    final c1 = await makeLocal('甲', 2);
    final sc = makeController();
    await sc.start();

    fake.bumpByOtherDevice(c1, payload: serverPayload(c1, '云端甲'));
    await editLocal(c1, '甲', 3);
    sc.onLocalSaved(c1);
    await sc.flushQueue();
    expect(sc.statusFor(c1), SyncStatus.conflict);

    await sc.resolve(c1, ConflictChoice.keepCloud);
    expect(sc.statusFor(c1), SyncStatus.synced);
    final ls = await store.loadCollection(c1);
    expect(ls.length, 1);
    expect(ls.first.id, 'srv');
  });

  test('冲突-保留本机：用 serverRev 重传，服务端 rev+1', () async {
    final c1 = await makeLocal('甲', 2);
    final sc = makeController();
    await sc.start();

    fake.bumpByOtherDevice(c1, payload: serverPayload(c1, '云端甲'));
    await editLocal(c1, '甲', 3);
    sc.onLocalSaved(c1);
    await sc.flushQueue();
    expect(sc.statusFor(c1), SyncStatus.conflict);

    final localRaw = await store.readCollectionRaw(c1);
    await sc.resolve(c1, ConflictChoice.keepLocal);
    expect(sc.statusFor(c1), SyncStatus.synced);
    expect(fake.projects[c1]!.rev, 3, reason: 'overwrite 云端 → rev+1');
    expect(fake.projects[c1]!.snapshots[3]!.payload, localRaw);
  });

  test('冲突-另存副本（默认）：本机存为新工程，云端保留', () async {
    final c1 = await makeLocal('甲', 2);
    final sc = makeController();
    await sc.start();

    fake.bumpByOtherDevice(c1, payload: serverPayload(c1, '云端甲'));
    await editLocal(c1, '甲', 3);
    sc.onLocalSaved(c1);
    await sc.flushQueue();
    expect(sc.statusFor(c1), SyncStatus.conflict);

    await sc.resolve(c1, ConflictChoice.saveCopy);

    // 云端工程被覆盖（rev 仍为 2），本地 c1 = 云端内容。
    expect(fake.projects[c1]!.rev, 2);
    final orig = await store.loadCollection(c1);
    expect(orig.length, 1);
    expect(orig.first.id, 'srv');

    // 本机改动另存为新工程（名字含「(本机-」），待上传。
    final idx = await store.loadIndex();
    final copy = idx.where((m) => m.name.contains('(本机-')).toList();
    expect(copy.length, 1, reason: '应生成一个冲突副本');
    expect(sc.statusFor(copy.first.id), SyncStatus.pendingUpload);
    expect((await store.loadCollection(copy.first.id)).length, 3,
        reason: '副本保留本机 3 点');
  });

  test('软删除：DELETE 使服务端 deleted=1 且 rev+1', () async {
    final c1 = await makeLocal('甲', 2);
    final sc = makeController();
    await sc.start();

    await store.deleteCollection(c1);
    sc.onLocalDeleted(c1);
    await sc.flushQueue();

    expect(fake.projects[c1]!.deleted, isTrue);
    expect(fake.projects[c1]!.rev, 2);
    expect(sc.pendingCount, 0);
  });

  test('pullIndex 跟随云端软删除（本地干净时随之删除）', () async {
    final c1 = await makeLocal('甲', 2);
    final sc = makeController();
    await sc.start();
    expect(await store.readCollectionRaw(c1), isNotNull);

    // 另一设备删除云端。
    fake.projects[c1]!
      ..deleted = true
      ..rev = 2
      ..updatedAt = DateTime.now().millisecondsSinceEpoch + 1;

    await sc.pullIndex();
    expect(await store.readCollectionRaw(c1), isNull, reason: '本地应随云端软删除');
    final idx = await store.loadIndex();
    expect(idx.any((m) => m.id == c1), isFalse);
  });

  test('历史恢复：restore 后 pullIndex 重新拉回本地', () async {
    final c1 = await makeLocal('甲', 2);
    final sc = makeController();
    await sc.start();

    await store.deleteCollection(c1);
    sc.onLocalDeleted(c1);
    await sc.flushQueue();
    expect(fake.projects[c1]!.deleted, isTrue);

    final api = SyncApi(
        base: kBase, token: 'tok-test', deviceId: 'dev-A', deviceName: '电脑-A');
    final newRev = await api.restore(c1, 1); // 恢复到 rev1（含 2 点）
    expect(newRev, 3);

    await sc.pullIndex();
    final back = await store.loadCollection(c1);
    expect(back.length, 2, reason: '恢复后应重新拉回 2 点');
    expect(sc.statusFor(c1), SyncStatus.synced);
  });

  test('未配置令牌：全部为 no-op（保持本地模式）', () async {
    final c1 = await makeLocal('甲', 1);
    // 未配置身份的控制器（token 空）。
    final sc2 = SyncController(
        store: store,
        identity: DeviceIdentity.forTest(token: '', serverBase: ''),
        uploadDebounce: const Duration(hours: 1))
      ..autoPoll = false;
    controllers.add(sc2);
    await sc2.start();
    expect(fake.projects.containsKey(c1), isFalse);
    expect(sc2.configured, isFalse);
    expect(sc2.aggregateStatus, SyncStatus.localOnly);
  });
}
