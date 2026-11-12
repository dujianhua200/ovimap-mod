// 桌面右栏属性面板护栏。
//
// 本轮（出图效率专项）在这一块做了三件**会改变行为**的事，必须锁住：
//   1. 段标实时预览 —— 右栏就能看到"图上会写成什么"，不用切回地图核对；
//   2. 未保存可见 —— 8 个字段共用一个保存键，改了不点就丢，现在有橙标提示；
//   3. 切换点自动落盘 —— 改完直接去点另一个点，不能再静默丢改动。
// 其中第 3 条是**防出图事故**的：段距改了没写回，图上还是旧数字。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/desktop/right_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState st;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
  });

  /// 上一链点 + 当前点：当前点到上一点 38 米（distanceM 固定，不依赖 haversine）。
  ({MapLabel prev, MapLabel cur}) seedPair() {
    final prev = MapLabel(
        typeId: 'pole', seq: 1, lat: 32.0, lon: 114.0, lineGroupId: 'g1',
        name: 'GK-1');
    final cur = MapLabel(
        typeId: 'pole', seq: 2, lat: 32.0004, lon: 114.0, lineGroupId: 'g1',
        name: 'GK-2', distanceM: 38, segKind: 1);
    st.labels.addAll([prev, cur]);
    return (prev: prev, cur: cur);
  }

  Future<void> mount(WidgetTester tester, MapLabel? label,
      {String cid = ''}) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 280,
          height: 800,
          child: RightPanel(
            st: st,
            label: label,
            sourceCid: cid,
            onCleared: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 段标输入框：hint 以「如：埋」开头，用来与其它输入框区分（右栏有 9 个输入框）。
  Finder segLabelField() => find.widgetWithText(TextField, '如：埋42.5 / 架38，留空自动显示距离');

  testWidgets('段标实时预览：架空段显示「架38」，与地图/DXF 同源推导', (tester) async {
    final p = seedPair();
    await mount(tester, p.cur);

    // 敷设方式=架空(1)、无手填 → 预览必须带"架"前缀，而不是裸 38。
    expect(find.text('图上显示：'), findsOneWidget);
    expect(find.text('架38'), findsOneWidget);
    expect(find.text('手填'), findsNothing);
  });

  testWidgets('段标实时预览：手填内容优先，且标出「手填」', (tester) async {
    final p = seedPair();
    await mount(tester, p.cur);

    await tester.enterText(segLabelField(), '埋42.5');
    await tester.pumpAndSettle();

    expect(find.text('埋42.5'), findsWidgets);
    expect(find.text('手填'), findsOneWidget,
        reason: '要让用户知道这一档不是自动推导出来的');
  });

  testWidgets('段标实时预览：切敷设方式时预览立刻跟着变（不用先保存）', (tester) async {
    final p = seedPair();
    await mount(tester, p.cur);
    expect(find.text('架38'), findsOneWidget);

    await tester.tap(find.text('埋地'));
    await tester.pumpAndSettle();

    expect(find.text('埋38'), findsOneWidget);
    expect(find.text('架38'), findsNothing,
        reason: '预览读的是编辑态，不是已保存值');
  });

  testWidgets('未保存提示：改动后出现橙标 + 保存键点亮，保存后消失', (tester) async {
    final p = seedPair();
    await mount(tester, p.cur);
    expect(find.text('未保存'), findsNothing);
    expect(find.text('已保存'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '名称'), 'GK-2改');
    await tester.pumpAndSettle();

    expect(find.text('未保存'), findsOneWidget);
    expect(find.text('保存改动'), findsOneWidget);

    await tester.tap(find.text('保存改动'));
    await tester.pumpAndSettle();

    expect(find.text('未保存'), findsNothing);
    expect(p.cur.name, 'GK-2改');
  });

  testWidgets('切换点时自动落盘：改完直接去看另一个点，改动不会静默丢失', (tester) async {
    final p = seedPair();
    await mount(tester, p.cur);

    // 改段距 38 → 55，但**不点保存**。
    await tester.enterText(
        find.widgetWithText(TextField, '到上一点距离（米，留空自动）'), '55');
    await tester.pumpAndSettle();
    expect(find.text('未保存'), findsOneWidget);

    // 用户直接去点另一个点（壳把 label 换掉）。
    //
    // 这里用"状态通知次数"来验证**持久化入口真的被走到**：
    // `st.updateLabel` 内部会 `_saveDraft()` 再 `notifyListeners()`，而只改内存对象
    // 不会有任何通知。之所以不直接断言磁盘文件——widget 测试跑在假时钟里，
    // 真实文件 IO 的 Future 不会在 `pump` 期间完成（这是 flutter_test 的既有约束，
    // 不是本功能的问题）；磁盘持久化本身由 store 层用例覆盖。
    var notified = 0;
    st.addListener(() => notified++);
    await mount(tester, p.prev);
    await tester.pumpAndSettle();

    // 关键：原来那个点的改动已经写回**并请求落盘**，不会丢。
    expect(p.cur.distanceM, 55);
    expect(p.cur.distLabel, '', reason: '落盘不该顺手把段标固化');
    expect(notified, greaterThan(0),
        reason: '必须走 st.updateLabel（含 saveDraft）；只改内存 = 重启还原');
    // 新选中的点回到干净的"已保存"态。
    expect(find.text('未保存'), findsNothing);
  });

  testWidgets('拖动点后段标自动跟随：改段距即预览随之变化（不写死进 distLabel）',
      (tester) async {
    final p = seedPair();
    await mount(tester, p.cur);
    expect(find.text('架38'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, '到上一点距离（米，留空自动）'), '55');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存改动'));
    await tester.pumpAndSettle();

    expect(find.text('架55'), findsOneWidget);
    expect(p.cur.distLabel, '');
    // 地图/DXF 读的是同一份推导结果。
    expect(st.segments.first.text, '架55');
  });

  testWidgets('无选中点：给出可行动提示而不是空白', (tester) async {
    seedPair();
    await mount(tester, null);
    expect(find.textContaining('未选中点'), findsOneWidget);
  });
}
