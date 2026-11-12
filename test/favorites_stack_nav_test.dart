// 收藏夹树护栏（v3.6.0 用户给奥维截图定版：整树平铺、+/− 折叠、[n] 计数、
// 点名称选层过滤下方列表、搜索跨全库）。
//
// 数据：根工程 P2；文件夹 A（内含工程 P1 与子文件夹 B）。
// 真实文件 I/O 用 `tester.runAsync`；选层/折叠是纯 setState。
import 'dart:io';

import 'package:flutter/material.dart';
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

Future<void> mountPanel(WidgetTester tester, AppState st) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [Provider<SyncController?>.value(value: null)],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 700,
            child: LeftPanel(st: st, onNewProject: () {}),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late Directory dir;
  late AppState st;
  late String aid; // 文件夹 A 的 id

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('ovimap_fav_tree');
    store.setBaseDirForTest(dir);
    await store.finishCollection(
        name: 'P2', kind: 'label', folderId: '', editMode: 'design', labels: []);
    final a = await store.addFolder('A');
    aid = a.id;
    await store.finishCollection(
        name: 'P1',
        kind: 'label',
        folderId: a.id,
        editMode: 'design',
        labels: []);
    await store.addFolder('B', a.id);
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
  });

  testWidgets('整树平铺（奥维式）：文件夹与工程同树可见，各带 [n] 计数', (tester) async {
    await mountPanel(tester, st);
    expect(find.text('收藏夹'), findsWidgets); // 面板标题 + 树根行
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget, reason: '默认全展开，B 随 A 平铺可见');
    // v3.9：工程也在树里（用户口径：所有东西都在收藏夹树下看得见）。
    expect(find.text('P2'), findsOneWidget, reason: '根目录工程在树里');
    expect(find.text('P1'), findsOneWidget, reason: 'A 里的工程也在树里');
    expect(find.text('[1]'), findsWidgets, reason: 'A[1]');
    expect(find.text('[2]'), findsOneWidget, reason: '根行收藏夹[2 个工程]');
  });

  testWidgets('点 A 行：选中该层并同步 folderId（树保持全量可见）', (tester) async {
    await mountPanel(tester, st);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(st.folderId, aid, reason: '保存对话框默认层跟随选中');
    expect(find.text('P2'), findsOneWidget, reason: '树是全量视图，不因选层而隐藏');
  });

  testWidgets('点 A 的 −：B 收起；点 +：B 再展开', (tester) async {
    await mountPanel(tester, st);
    // 初始根与 A 都展开 ⇒ 两个 remove；树顺序 根, A, B ⇒ at(1) 是 A 的。
    expect(find.byIcon(Icons.remove), findsNWidgets(2));
    await tester.tap(find.byIcon(Icons.remove).at(1));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsNothing, reason: '收起后 B 隐藏');
    expect(find.byIcon(Icons.add), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget, reason: '再展开 B 回来');
  });

  testWidgets('标记收藏在树中列出点行：图钉+名字+备注，点击定位', (tester) async {
    // 建标记收藏（真实 IO 必须在 runAsync——testWidgets 是假时钟区）。
    final cid = await tester.runAsync(() async {
      final cid = await store.finishCollection(
          name: '标记', kind: 'mark', folderId: '', editMode: 'design', labels: []);
      final ls = await store.loadCollection(cid);
      ls.add(MapLabel(typeId: 'fiberbox', seq: 1, lat: 32.0, lon: 114.0,
          name: '标记1')..note = '光交');
      await store.saveCollectionLabels(cid, ls);
      st.visibleCids.add(cid);
      st.overlayLabels[cid] = ls;
      await st.refreshCollections();
      return cid;
    });

    await mountPanel(tester, st);
    expect(find.text('标记1'), findsOneWidget, reason: '树中列出标记点行');
    expect(find.text('光交'), findsOneWidget, reason: '备注灰字跟显');

    // 点击点行 → 定位回调（属性对话框链路由右键菜单既有用例覆盖）。
    var located = <MapLabel>[];
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<SyncController?>.value(value: null)],
      child: MaterialApp(
        home: Scaffold(
          body: LeftPanel(
              st: st,
              onNewProject: () {},
              onLocate: (l) => located.add(l)),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标记1'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(located.length, 1, reason: '瞬间定位');
    // 用户指定：点击标记**不弹属性框**（属性走右键）。
    expect(find.text('标签名称'), findsNothing, reason: '左键点击不应弹窗');
    expect(cid, isNotEmpty);
  });

  testWidgets('搜索跨全库：在 A 选中态搜 P2 也能命中根目录工程', (tester) async {
    await mountPanel(tester, st);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'P2');
    await tester.pumpAndSettle();
    // 两处 P2：搜索框内容 + 结果行。
    expect(find.text('P2'), findsNWidgets(2));
  });

  testWidgets('批量选择入口必须可见（用户反馈：只靠 Ctrl 找不到）', (tester) async {
    await mountPanel(tester, st);
    // 工具条四件套：全选 / 取消 / 导出所选 / 删除所选（+ 新建文件夹在标题栏）。
    expect(find.byTooltip('全选（Ctrl+A）'), findsOneWidget);
    expect(find.byTooltip('取消选择'), findsOneWidget);
    expect(find.byTooltip('导出所选工程（DXF）'), findsOneWidget);
    expect(find.byTooltip('删除所选（Delete）'), findsOneWidget);

    // 全选后：显示「已选 N 项」，删除按钮可用（enabled）。
    await tester.tap(find.byTooltip('全选（Ctrl+A）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 '), findsOneWidget,
        reason: '工具条实时显示已选数');

    // 项目里的条目都可被选中：文件夹 A/B、工程 P1/P2 都在选中集里。
    // （真正的删除动作走 store 层护栏：deleteFolder 级联 + deleteCollection
    //   已在 collection_autosave_indep_test 覆盖；此处只锁「入口可见」，
    //   避免依赖弹框+真实 IO 的脆弱链路。）
    await tester.tap(find.byTooltip('取消选择'));
    await tester.pumpAndSettle();
    expect(find.text('全部条目'), findsOneWidget);
  });
}
