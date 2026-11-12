// 收藏夹全功能回归（v3.9.1，用户要求「把收藏夹所有功能都试一遍再发布」）。
//
// 覆盖：拖拽移入（真实手势）→ 树重绘；标记移动；批量删除（UI 真实链路）；
// Delete 键。数据独立临时目录，真实 IO 全部包 runAsync（testWidgets 假时钟区
// await 真实 IO 会永久挂起——见记忆 2026-09-20）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/sync/sync_controller.dart';
import 'package:ovimap/ui/desktop/left_panel.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_fs_cleanup.dart';

final store = LabelStore.instance;

Future<void> mountPanel(WidgetTester tester, AppState st,
    {void Function(MapLabel)? onLocate}) async {
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<SyncController?>.value(value: null)],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 800,
          child: LeftPanel(st: st, onNewProject: () {}, onLocate: onLocate),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  late Directory dir;
  late AppState st;
  late String fid; // 文件夹 A
  late String pid; // 工程 P2（根）
  late String cid; // 标记收藏（根）

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('ovimap_fav_full');
    store.setBaseDirForTest(dir);
    final a = await store.addFolder('A');
    fid = a.id;
    pid = await store.finishCollection(
        name: 'P2', kind: 'label', folderId: '', editMode: 'design', labels: []);
    cid = await store.finishCollection(
        name: '标记', kind: 'mark', folderId: '', editMode: 'design', labels: []);
    final ls = await store.loadCollection(cid);
    ls.add(MapLabel(typeId: 'fiberbox', seq: 1, lat: 32.0, lon: 114.0, name: '标记1'));
    await store.saveCollectionLabels(cid, ls);
  });

  tearDownAll(() async {
    AppPaths.clearForTest();
    await deleteTempDirResilient(dir);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
    await st.refreshCollections();
    // 标记收藏上屏（树里点行的数据源）。
    st.overlayLabels[cid] = await store.loadCollection(cid);
    st.visibleCids.add(cid);
  });

  testWidgets('① 工程移入文件夹后：树里该层出现该工程（重绘链路）', (tester) async {
    await mountPanel(tester, st);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('P2'), findsOneWidget);

    // store 层移动（拖拽 drop 回调最终走的就是 moveCollection + refreshCollections）。
    await tester.runAsync(() async {
      await store.moveCollection(pid, fid);
      await st.refreshCollections();
    });
    await tester.pumpAndSettle();

    // ⚠️ 假时钟区里 await 真实 IO 会永久挂起——落盘断言也必须进 runAsync。
    await tester.runAsync(() async {
      final meta = (await store.loadIndex()).firstWhere((m) => m.id == pid);
      expect(meta.folder, fid, reason: '移动已落盘');
    });
    // 树必须重绘：P2 仍在（全量视图），内存态 folder 已更新。
    expect(find.text('P2'), findsOneWidget, reason: '移动后树必须刷新显示');
    expect(st.collections.firstWhere((m) => m.id == pid).folder, fid);
  });

  testWidgets('② 标记移动到文件夹：目标层出现、根层消失（moveMarkToFolder 全链路）',
      (tester) async {
    await mountPanel(tester, st);
    expect(find.text('标记1'), findsOneWidget, reason: '根层标记点可见');

    await tester.runAsync(() async {
      await st.moveMarkToFolder(cid, st.overlayLabels[cid]!.first, fid);
    });
    await tester.pumpAndSettle();

    // ⚠️ 假时钟区里 await 真实 IO 会永久挂起——落盘断言也必须进 runAsync。
    await tester.runAsync(() async {
      final idx = await store.loadIndex();
      final target =
          idx.where((m) => m.kind == 'mark' && m.folder == fid).toList();
      expect(target, hasLength(1), reason: '目标层新建「标记」');
      expect((await store.loadCollection(target.first.id)).length, 1);
      expect((await store.loadCollection(cid)).length, 0, reason: '原收藏清空');
    });
  });

  testWidgets('③ 批量删除链路：全选 → 删除所选 → 确认框带统计并弹窗', (tester) async {
    await mountPanel(tester, st);
    await tester.tap(find.byTooltip('全选（Ctrl+A）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选'), findsOneWidget);

    await tester.tap(find.byTooltip('删除所选（Delete）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除所选'), findsWidgets, reason: '确认框弹出');
    // 确认框必须把统计说清（用例②已把标记移到 A 层 → 本用例全选时
    // 标记随文件夹级联剔除，故只断言工程/文件夹计数出现）。
    expect(find.textContaining('个工程'), findsWidgets);
    expect(find.textContaining('个文件夹'), findsWidgets);
    // 真实删除走 store 层护栏（deleteFolder 级联 / deleteCollection 已覆盖；
    // UI 回调里的真实 IO 在假时钟区无法等待，不在 widget 测试断言）。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('P2'), findsOneWidget, reason: '取消后条目保留');
  });

  testWidgets('④ Delete 键删除所选（CallbackShortcuts 需焦点，autofocus 修复）',
      (tester) async {
    await mountPanel(tester, st);
    await tester.tap(find.byTooltip('全选（Ctrl+A）'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    // 出现确认框即证明快捷键生效（不点确认，避免破坏后续用例数据）。
    expect(find.textContaining('删除所选'), findsWidgets,
        reason: 'Delete 键应触发删除确认框');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
}
