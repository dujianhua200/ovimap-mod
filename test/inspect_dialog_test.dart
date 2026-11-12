// 出图体检面板护栏。
//
// 这一块是"出图效率"专项的核心交付：线路设计人员在**出图前**点一下就能拿到
// 一份可行动的问题清单。测试要锁住的是「清单真的能指问题、能排序、能定位、
// 能一键修」这四件事，而不只是"对话框能打开"。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/desktop/inspect_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState st;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
  });

  /// 一条 3 点 2 段的干净链：段距 38 / 42（都在 5~200 内）、敷设方式齐全、
  /// 命名唯一且序号连续 —— 体检应当**零问题**。
  void seedClean() {
    st.labels.addAll([
      MapLabel(
          typeId: 'pole', seq: 1, lat: 32.0, lon: 114.0, lineGroupId: 'g1',
          name: 'GK-1'),
      MapLabel(
          typeId: 'pole', seq: 2, lat: 32.0004, lon: 114.0, lineGroupId: 'g1',
          name: 'GK-2', distanceM: 38, segKind: 1),
      MapLabel(
          typeId: 'pole', seq: 3, lat: 32.0008, lon: 114.0, lineGroupId: 'g1',
          name: 'GK-3', distanceM: 42, segKind: 2),
    ]);
  }

  Future<void> openDialog(
    WidgetTester tester, {
    void Function(List<String>)? onLocate,
  }) async {
    // 桌面尺寸：面板定宽 560 + 高度上限取视口 80%，窗口太小会让内容被挤掉。
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => showRouteInspectDialog(ctx, st, onLocate: onLocate),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();
  }

  testWidgets('干净工程：给出"可以交付"的明确结论，而不是列一堆空条目', (tester) async {
    seedClean();
    await openDialog(tester);
    expect(find.text('未发现问题，可以出图'), findsOneWidget);
    expect(find.text('这一版可以交付'), findsOneWidget);
    // 没有问题时不该出现"清除漂移段标"这种修动作。
    expect(find.textContaining('清除漂移段标'), findsNothing);
  });

  testWidgets('段距过短报 error：标题 + 人话详情 + 可执行建议三件套齐全',
      (tester) async {
    seedClean();
    st.labels[1].distanceM = 3.2; // 段1 只有 3.2 米
    await openDialog(tester);

    expect(find.text('段距过短'), findsOneWidget);
    // 详情必须带具体数字与段位，不能只说"存在异常"。
    expect(find.textContaining('第1段'), findsWidgets);
    expect(find.textContaining('3.2'), findsWidgets);
    expect(find.textContaining('5 米下限'), findsWidgets);
    expect(find.textContaining('确认是否漏点'), findsWidgets);
  });

  testWidgets('严重度排序：error 一定渲染在 warn 之前', (tester) async {
    seedClean();
    st.labels[1].distanceM = 3.2; // error：段距过短
    st.labels[2].segKind = 0; // warn：未填敷设方式
    await openDialog(tester);

    final errY = tester.getTopLeft(find.text('段距过短')).dy;
    final warnY = tester.getTopLeft(find.text('未填敷设方式')).dy;
    expect(errY, lessThan(warnY),
        reason: '先看错误再看警告——排序错会让用户先处理次要问题');
  });

  testWidgets('等级筛选：取消勾选「错误」后 error 条目消失、warn 仍在',
      (tester) async {
    seedClean();
    st.labels[1].distanceM = 3.2;
    st.labels[2].segKind = 0;
    await openDialog(tester);

    expect(find.text('段距过短'), findsOneWidget);
    expect(find.text('未填敷设方式'), findsOneWidget);

    await tester.tap(find.textContaining('错误（'));
    await tester.pumpAndSettle();

    expect(find.text('段距过短'), findsNothing);
    expect(find.text('未填敷设方式'), findsOneWidget);
  });

  testWidgets('定位：把该问题的点位 id 交给外壳，并把面板关掉（否则遮罩挡住地图）',
      (tester) async {
    seedClean();
    st.labels[1].distanceM = 3.2;
    final got = <List<String>>[];
    await openDialog(tester, onLocate: got.add);

    await tester.tap(find.text('定位').first);
    await tester.pumpAndSettle();

    expect(got.length, 1);
    // 段类问题要能定位到这一段的两个端点。
    expect(got.first, containsAll(<String>[st.labels[0].id, st.labels[1].id]));
    expect(find.text('出图体检'), findsNothing, reason: '定位后应已关闭面板');
  });

  testWidgets('竣工模式：额外要求盘留与光缆型号（结算口径）', (tester) async {
    seedClean();
    st.editModeName = 'completion';
    await openDialog(tester);

    expect(find.text('竣工未填盘留'), findsWidgets);
    expect(find.text('未填光缆型号'), findsWidgets);
  });

  testWidgets('清除漂移段标：手填数字与实测不符时一键清掉，且清完即从清单消失',
      (tester) async {
    seedClean();
    st.labels[1].distLabel = '埋99'; // 实测 38，偏差 160%
    await openDialog(tester);

    expect(find.text('段标注与实测不符'), findsOneWidget);
    final fix = find.textContaining('清除漂移段标（');
    expect(fix, findsOneWidget);

    await tester.tap(fix);
    await tester.pumpAndSettle();

    // 真的写回 state，且段标回到"实时推导"（敷设方式 架 + 实测 38）。
    expect(st.labels[1].distLabel, '');
    expect(st.segments.first.text, '架38');
    // 清完就没有漂移项了，那条修动作也必须消失（否则是在骗用户）。
    expect(find.text('段标注与实测不符'), findsNothing);
    expect(find.textContaining('清除漂移段标'), findsNothing);
  });

  testWidgets('无点工程不崩：空工程打开体检给出友好结论', (tester) async {
    await openDialog(tester);
    expect(find.text('出图体检'), findsOneWidget);
    expect(find.text('未发现问题，可以出图'), findsOneWidget);
  });
}
