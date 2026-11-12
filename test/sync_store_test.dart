// T13：本地旁路存储——sync_state.json / sync_queue.json，且 **index.json 不被注入同步字段**。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/sync/sync_models.dart';
import 'package:ovimap/sync/sync_store.dart';

void main() {
  late Directory dir;
  final store = LabelStore.instance;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_sync_store');
    store.setBaseDirForTest(dir);
  });

  tearDown(() {
    AppPaths.clearForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<String> readLabelsJson(String name) async {
    final d = await AppPaths.labelsDir();
    return File('${d.path}/$name').readAsStringSync();
  }

  test('sync_state：缺省为空表，写入后可读回', () async {
    final s = SyncStore();
    expect(await s.loadState(), isEmpty);

    await s.saveState(<String, SyncMeta>{
      'c1': SyncMeta(
          cid: 'c1',
          rev: 7,
          updatedAt: 1730000000000,
          lastDeviceId: 'dev-A',
          lastDeviceName: '电脑-信阳',
          status: SyncStatus.synced),
    });

    final back = await s.loadState();
    expect(back.keys, <String>['c1']);
    expect(back['c1']!.rev, 7);
    expect(back['c1']!.status, SyncStatus.synced);
    expect(back['c1']!.lastDeviceName, '电脑-信阳');
  });

  test('sync_queue：缺省为空表，写入后可读回（含 op/attempts）', () async {
    final s = SyncStore();
    expect(await s.loadQueue(), isEmpty);
    await s.saveQueue(<QueueItem>[
      QueueItem(cid: 'c1', op: SyncOp.upsert, baseRev: 2, enqueuedAt: 10),
      QueueItem(
          cid: 'c2',
          op: SyncOp.delete,
          baseRev: 0,
          enqueuedAt: 20,
          attempts: 3,
          lastError: 'x'),
    ]);
    final back = await s.loadQueue();
    expect(back.length, 2);
    expect(back[0].op, SyncOp.upsert);
    expect(back[1].op, SyncOp.delete);
    expect(back[1].attempts, 3);
  });

  test('⭐ index.json 不被注入同步字段（旧版兼容）', () async {
    final cid = await store.finishCollection(
      name: '工程甲',
      kind: 'label',
      folderId: '',
      editMode: 'design',
      labels: <MapLabel>[MapLabel(typeId: 'pipe', seq: 1, lat: 32.1, lon: 114.0)],
    );

    // 同步元数据只落到旁路文件。
    await SyncStore().saveState(<String, SyncMeta>{
      cid: SyncMeta(
          cid: cid,
          rev: 9,
          updatedAt: 123,
          lastDeviceId: 'dev-A',
          lastDeviceName: '电脑',
          status: SyncStatus.synced),
    });

    final idx = await readLabelsJson('index.json');
    expect(idx.contains('"rev"'), isFalse, reason: 'index.json 不应含 rev');
    expect(idx.contains('lastDeviceId'), isFalse,
        reason: 'index.json 不应含 lastDeviceId');
    expect(idx.contains('updatedAt'), isFalse,
        reason: 'index.json 不应含 updatedAt');

    // 旁路文件里确实有 rev=9。
    final st = await readLabelsJson('sync_state.json');
    expect(st.contains('"rev": 9') || st.contains('"rev":9'), isTrue);
  });

  test('writeSyncTag 的 _sync 在 saveCollectionLabels 后仍保留', () async {
    final cid = await store.finishCollection(
      name: '工程乙',
      kind: 'label',
      folderId: '',
      editMode: 'design',
      labels: <MapLabel>[MapLabel(typeId: 'pipe', seq: 1, lat: 32.1, lon: 114.0)],
    );

    await store.writeSyncTag(cid, <String, dynamic>{
      'rev': 4,
      'updatedAt': 111,
      'lastDeviceId': 'dev-A',
      'lastDeviceName': '电脑',
    });

    // 旧版风格的“只覆盖 labels”保存。
    await store.saveCollectionLabels(
        cid, <MapLabel>[MapLabel(typeId: 'pipe', seq: 1, lat: 32.2, lon: 114.2)]);

    final raw = await readLabelsJson('collection_$cid.json');
    expect(raw.contains('"_sync"'), isTrue, reason: '_sync 应被保留');
    expect(raw.contains('"rev": 4') || raw.contains('"rev":4'), isTrue);
  });

  test('applyRemoteCollection：集合落 _sync，索引仅业务字段', () async {
    await store.applyRemoteCollection(
      'remote1',
      jsonEncode(<String, dynamic>{
        'id': 'remote1',
        'name': '云端工程',
        'labels': [
          <String, dynamic>{'id': 'p1', 'type': 'pipe', 'lat': 32.1, 'lon': 114.0},
          <String, dynamic>{'id': 'p2', 'type': 'pipe', 'lat': 32.2, 'lon': 114.1},
        ],
      }),
      meta: CollectionMeta(
          id: 'remote1', name: '云端工程', kind: 'label', folder: 'f1', count: 2),
      syncTag: <String, dynamic>{
        'rev': 5,
        'updatedAt': 999,
        'lastDeviceId': 'dev-B',
        'lastDeviceName': '手机',
      },
    );

    final col = await readLabelsJson('collection_remote1.json');
    expect(col.contains('"_sync"'), isTrue);
    expect(col.contains('"rev": 5') || col.contains('"rev":5'), isTrue);

    final idx = await readLabelsJson('index.json');
    expect(idx.contains('remote1'), isTrue);
    expect(idx.contains('云端工程'), isTrue);
    // 索引仍是“干净”的业务字段。
    expect(idx.contains('"rev"'), isFalse);
    expect(idx.contains('lastDeviceName'), isFalse);

    // 目录可被本地加载（2 点）。
    expect((await store.loadCollection('remote1')).length, 2);
  });
}
