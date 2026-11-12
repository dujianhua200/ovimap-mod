// T20 补强：恢复确认弹窗的数据安全提示分支 ——
// 该工程在本机**有待上传改动**时，确认框必须显示
// 「恢复将以所选版本为准，本机未上传的改动将丢失」；无待上传时不显示。
// 零网络（内存 Worker），真 widget 泵（走真实 showDarkDialog 链路）。
//
// ⚠️ 测试环境注意：widget 测试体运行在 FakeAsync 区，**真实文件 I/O 必须包在
// `tester.runAsync` 里**（否则 await 永不完成 → 测试挂死）。UI 泵仍在 FakeAsync 区。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/device_identity.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/sync/sync_controller.dart';
import 'package:ovimap/sync/sync_models.dart' show SyncStatus;
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
  final controllers = <SyncController>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_restore_confirm');
    store.setBaseDirForTest(dir);
    fake = FakeSyncServer(token: 'tok-test')..install();
  });

  tearDown(() async {
    for (final c in controllers) {
      c.dispose();
    }
    controllers.clear();
    fake.uninstall();
    AppPaths.clearForTest();
    // 用退让重试的删除：Windows 上在途异步写盘会短暂锁住临时目录，
    // 直接 deleteSync 会抛 PathAccessException(errno=32) 把构建判红。
    await deleteTempDirResilient(dir);
  });

  SyncController makeController() {
    final sc = SyncController(
      store: store,
      identity: DeviceIdentity.forTest(
        deviceId: 'dev-A',
        deviceName: '电脑-A',
        token: 'tok-test',
        serverBase: kBase,
      ),
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

  /// 打开历史对话框并点第一行的「恢复」→ 停在确认弹窗。
  Future<void> openHistoryAndTapRestore(
      WidgetTester tester, SyncController sc, String cid) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showVersionHistoryDialog(ctx, sc, cid, '甲'),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump(); // 弹出（初始 loading 帧）
    await tester.pump(const Duration(milliseconds: 50)); // 历史列表加载完成
    // 列表里每行的「恢复」按钮（第一个即可）
    await tester.tap(find.widgetWithText(TextButton, '恢复').first);
    await tester.pump(); // 确认弹窗弹出
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('有待上传改动：确认框显示「本机未上传的改动将丢失」', (tester) async {
    late String c1;
    late SyncController sc;
    // 真实文件 I/O + 启动同步：必须在 runAsync 里（FakeAsync 区会挂死）。
    await tester.runAsync(() async {
      c1 = await makeLocal('甲', 2);
      sc = makeController();
      await sc.start();
      expect(sc.statusFor(c1), isNot(SyncStatus.pendingUpload));
      // 制造本机待上传（debounce 不触发，留在队里）
      await editLocal(c1, '甲', 3);
      sc.onLocalSaved(c1);
      expect(sc.statusFor(c1), SyncStatus.pendingUpload);
    });

    await openHistoryAndTapRestore(tester, sc, c1);

    expect(find.textContaining('本机未上传的改动将丢失'), findsOneWidget,
        reason: '有待上传改动时必须明示数据丢失风险');
  });

  testWidgets('无待上传改动：确认框不显示该提示句', (tester) async {
    late String c2;
    late SyncController sc;
    await tester.runAsync(() async {
      c2 = await makeLocal('乙', 2);
      sc = makeController();
      await sc.start();
      expect(sc.statusFor(c2), isNot(SyncStatus.pendingUpload));
    });

    await openHistoryAndTapRestore(tester, sc, c2);

    expect(find.textContaining('本机未上传的改动将丢失'), findsNothing);
  });
}
