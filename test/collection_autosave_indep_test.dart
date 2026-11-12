// 收藏夹改版护栏（用户反馈：新建文件夹逻辑不行 / 没有删除功能 /
// 「添加的轨迹和标签没有保存功能」/ 要跟电脑版奥维地图一样）。
//
// 本文件覆盖**状态与磁盘层**：
//   T1  打开收藏后加/删/撤销点 → 收藏文件同步落盘（核心回归：以前只写 draft.json）
//   T2  编辑态下「新建空白工程」先脱离收藏再清空，空列表绝不写回收藏文件
//   T3  文件夹新建/重命名/删除（删除时内容上移到父级，不丢工程）
//
// ⚠️ 真实文件 I/O 在纯 `test()`（非 FakeAsync）里跑，落盘是 fire-and-forget，
//    断言前用 `await _settle()` 让事件循环把异步写排空。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_fs_cleanup.dart';

final store = LabelStore.instance;

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 80));

List<MapLabel> labelsN(int n) => [
      for (var i = 0; i < n; i++)
        MapLabel(typeId: 'pole', seq: i + 1, lat: 32.0 + i * 0.001, lon: 114.0),
    ];

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_fav_rework');
    store.setBaseDirForTest(dir);
  });

  tearDown(() async {
    AppPaths.clearForTest();
    await deleteTempDirResilient(dir);
  });

  group('T1 打开收藏后的自动保存（「轨迹和标签没有保存」根因回归）', () {
    Future<AppState> makeOpened(int n) async {
      final cid = await store.finishCollection(
        name: '杆路A',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(n),
      );
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
      final metas = await store.loadIndex();
      await st.openCollection(metas.firstWhere((m) => m.id == cid));
      return st;
    }

    Future<int> diskCount(String cid) async {
      final f = File('${dir.path}/labels/collection_$cid.json');
      final o = Map<String, dynamic>.from(
          jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      return (o['labels'] as List).length;
    }

    test('加 1 个点 → 收藏文件从 3 变 4', () async {
      final st = await makeOpened(3);
      final cid = st.activeCollectionId;
      expect(cid, isNotEmpty);
      expect(await diskCount(cid), 3, reason: '前置：收藏文件应为打开时的 3 点');

      st.addLabelAtWgs(32.5, 114.5);
      await _settle();
      expect(await diskCount(cid), 4, reason: '打点必须同步写回收藏文件');
      expect(st.labels.length, 4);
    });

    test('删 1 个点 → 收藏文件同步变 2；再撤销 → 回到 3', () async {
      final st = await makeOpened(3);
      final cid = st.activeCollectionId;

      st.removeLabel(st.labels.last);
      await _settle();
      expect(await diskCount(cid), 2, reason: '删点必须同步写回收藏文件');

      st.undoDraft();
      await _settle();
      expect(await diskCount(cid), 3, reason: '撤销也走 _saveDraft，同样落盘');
      expect(st.labels.length, 3);
    });

    test('重启模拟：重新 loadCollection 拿到的是改过之后的点集', () async {
      final st = await makeOpened(2);
      final cid = st.activeCollectionId;
      st.addLabelAtWgs(32.9, 114.9);
      await _settle();

      final reopened = await store.loadCollection(cid);
      expect(reopened.length, 3, reason: '重启后收藏里必须有第 3 个点');
    });
  });

  group('T2 新建空白工程不误清收藏', () {
    test('编辑收藏时 startNewDraft → 收藏文件保持原内容，且脱离编辑态', () async {
      final cid = await store.finishCollection(
        name: '管道B',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(2),
      );
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
      final metas = await store.loadIndex();
      await st.openCollection(metas.firstWhere((m) => m.id == cid));

      st.startNewDraft();
      await _settle();

      expect(st.activeCollectionId, '', reason: '必须先脱离收藏再清空，顺序不能反');
      expect(st.labels, isEmpty, reason: '画布应已清空');
      expect(st.projectName, '');

      final onDisk = await store.loadCollection(cid);
      expect(onDisk.length, 2, reason: '空列表绝不许写回收藏文件（历史 bug 会清空整个工程）');
    });
  });

  group('T2b 跨工程续画断路（「打点老接上次工程末端」回归）', () {
    test('打开收藏后第一笔不接收藏线组；之后恢复连续绘制', () async {
      // 收藏里已有两点同组（一条线）。
      final labels = labelsN(2)
        ..[0].lineGroupId = 'g1'
        ..[1].lineGroupId = 'g1';
      final cid = await store.finishCollection(
        name: '老杆路',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labels,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
      final metas = await store.loadIndex();
      await st.openCollection(metas.firstWhere((m) => m.id == cid));

      // 打开收藏后新打一笔：**不得**接进 g1。
      st.addLabelAtWgs(33.0, 115.0);
      expect(st.labels.last.lineGroupId, isEmpty,
          reason: '跨工程第一笔必须另起（v3.4 之前会接上收藏末端）');

      // 第二笔恢复连续绘制：接上第一笔的新线组。
      st.addLabelAtWgs(33.001, 115.001);
      expect(st.labels[3].lineGroupId, st.labels[2].lineGroupId,
          reason: '同工程内仍自动连线');
      expect(st.labels[3].lineGroupId, isNot('g1'),
          reason: '新线组是独立的，不与收藏旧线组混淆');
    });

    test('breakChain()：手动断开后下一笔另起', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
      st.addLabelAtWgs(32.0, 114.0);
      st.addLabelAtWgs(32.001, 114.0);
      expect(st.labels[1].lineGroupId, isNotEmpty);
      expect(st.labels[1].lineGroupId, st.labels[0].lineGroupId);

      st.breakChain();
      st.addLabelAtWgs(32.5, 114.5);
      expect(st.labels[2].lineGroupId, isEmpty,
          reason: '断开后第一笔不接任何线组');
      st.addLabelAtWgs(32.501, 114.5);
      expect(st.labels[3].lineGroupId, st.labels[2].lineGroupId,
          reason: '断开只影响一笔，之后恢复连续绘制');
    });
  });

  group('T2c v3.7 反馈护栏（逐点撤销 / 标记自动入根目录）', () {
    test('撤销逐点：打 3 点后 Ctrl+Z 一次只少 1 个点', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
      st.addLabelAtWgs(32.0, 114.0);
      st.addLabelAtWgs(32.001, 114.0);
      st.addLabelAtWgs(32.002, 114.0);
      expect(st.labels.length, 3);
      st.undoDraft();
      expect(st.labels.length, 2, reason: '一次撤销只回退一个点（之前一次撤光）');
      st.undoDraft();
      expect(st.labels.length, 1);
    });

    test('标记模式：addMarkAtWgs 落独立点并自动建根目录「标记」收藏', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
      st.markMode = true;
      await st.addMarkAtWgs(32.0, 114.0);
      await st.addMarkAtWgs(32.5, 114.5);

      // 草稿不被污染。
      expect(st.labels, isEmpty, reason: '标记不进草稿');
      // 根目录出现「标记」收藏，2 个点。
      final metas = await store.loadIndex();
      final mark = metas.where((m) => m.name == '标记' && m.folder.isEmpty).toList();
      expect(mark.length, 1, reason: '只建一个「标记」收藏');
      expect(mark.first.kind, 'mark', reason: 'kind=mark 供收藏夹树识别列出点行');
      final ls = await store.loadCollection(mark.first.id);
      expect(ls.length, 2);
      expect(ls[0].name, '标记1');
      expect(ls[1].name, '标记2');
      expect(ls.every((l) => l.lineGroupId.isEmpty), isTrue,
          reason: '只标记不连线');
      // 自动上屏。
      expect(st.visibleCids.contains(mark.first.id), isTrue);
    });
  });

  group('T3 文件夹 CRUD（奥维式右键菜单的磁盘层）', () {
    test('新建 → 重命名 → 持久化在 folders.json', () async {
      final f1 = await store.addFolder('光缆工程');
      final f2 = await store.addFolder('管道工程', f1.id);
      await _settle();

      var list = await store.loadFolders();
      expect(list.map((e) => e.name), containsAll(['光缆工程', '管道工程']));
      expect(list.firstWhere((e) => e.id == f2.id).parentId, f1.id,
          reason: '子文件夹必须挂在父级下');

      await store.renameFolder(f2.id, '直埋工程');
      await _settle();
      list = await store.loadFolders();
      expect(list.firstWhere((e) => e.id == f2.id).name, '直埋工程');
    });

    test('重命名为空串：保持原名不破坏数据', () async {
      final f = await store.addFolder('外线');
      await store.renameFolder(f.id, '   ');
      await _settle();
      final list = await store.loadFolders();
      expect(list.firstWhere((e) => e.id == f.id).name, '外线');
    });

    test('删除文件夹：级联删整棵子树，工程上移到被删目录的父级', () async {
      final parent = await store.addFolder('2026年');
      final child = await store.addFolder('一季度', parent.id);
      final grand = await store.addFolder('一月', child.id);
      await store.finishCollection(
        name: '城北杆路',
        kind: 'label',
        folderId: grand.id,
        editMode: 'design',
        labels: labelsN(1),
      );
      await _settle();

      // 删 child：连同 grand 一起删（用户口径：删父文件夹连子文件夹一起删）。
      final (nF, nP) = await store.deleteFolder(child.id);
      await _settle();

      expect(nF, 2, reason: 'child + grand 共删 2 个文件夹');
      final ids = (await store.loadFolders()).map((e) => e.id).toList();
      expect(ids, isNot(contains(child.id)));
      expect(ids, isNot(contains(grand.id)), reason: '子文件夹必须一起删掉');
      expect(ids, contains(parent.id), reason: '父级不受影响');

      // 工程不丢：上移到 child 的父级（parent）。
      final proj = (await store.loadIndex()).firstWhere((m) => m.name == '城北杆路');
      expect(proj.folder, parent.id, reason: '子树内工程上移到被删目录的父级');

      // 删 parent：工程回到根，文件夹全清。
      await store.deleteFolder(parent.id);
      await _settle();
      final proj2 = (await store.loadIndex()).firstWhere((m) => m.name == '城北杆路');
      expect(proj2.folder, '', reason: '顶级目录删除后工程回到根目录');
      expect((await store.loadFolders()).map((e) => e.name),
          isNot(contains('2026年')));
    });

    test('空名新建文件夹：落为「文件夹」默认名（与 UI onSubmitted 空提交一致）', () async {
      final f = await store.addFolder('');
      await _settle();
      expect(f.name, '文件夹');
      expect((await store.loadFolders()).map((e) => e.name), contains('文件夹'));
    });
  });
}
