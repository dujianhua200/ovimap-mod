// 图源 / 图层面板护栏：把「定宽 + 卡片网格 + 叠加层互斥单选」这轮设计用断言锁住。
// 核心修复：对话框不再被撑到整窗宽（≤520），且叠加层是 Radio 而非 Checkbox（修 UX 缺陷）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/dialogs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState st;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
  });

  /// 桌面真实视口（1440×900）。默认测试视口只有 800×600，用它断言"不占满窗口"
  /// 会失真——同样的 528px 在 800 视口里占 66%，在真实窗口里只占 1/3。
  /// 断言必须放在真实尺寸下才有意义。
  void useDesktopViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> openDialog(WidgetTester tester) async {
    useDesktopViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => showSourceDialog(ctx, st),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();
  }

  /// 取「对话框可见面板」的尺寸。
  ///
  /// 不能用 `find.byType(AlertDialog)` —— AlertDialog 的 render box 是**整屏**
  /// （其内部是 AnimatedPadding，会吃满视口），量出来恒等于视口宽度，断言失效。
  /// 真正代表可见面板的是 AlertDialog 下第一个 Material（对话框底色面）。
  Size dialogSurfaceSize(WidgetTester tester) {
    final surface = find
        .descendant(
            of: find.byType(AlertDialog), matching: find.byType(Material))
        .evaluate()
        .first;
    return (surface.renderObject as RenderBox).size;
  }

  testWidgets('对话框不再占满窗口：面板定宽 480，且不超过视口 40%',
      (tester) async {
    await openDialog(tester);
    final size = dialogSurfaceSize(tester);
    // 旧实现是 width: double.maxFinite → 面板宽度 ≈ 视口宽度（1440）。
    expect(size.width, equals(480),
        reason: '定宽后可见面板应恰为 480（kPanelWidth）');
    expect(size.width, lessThan(1440 * 0.4),
        reason: '不应超过视口宽度的 40%（旧实现在此会 >98%）');
    // 高度受 maxHeightFactor 约束：900 × 0.7 = 630。
    expect(size.height, lessThanOrEqualTo(900 * 0.7 + 0.5),
        reason: '面板高度应受视口 70% 约束，避免长列表把对话框拉到出屏');
  });

  testWidgets('主图源卡片数量 == 非叠加源数量', (tester) async {
    await openDialog(tester);
    final expected = st.allSources.where((s) => !s.overlay).length;
    // 只统计主图源卡片：叠加层 RadioListTile 内部也用 InkWell，需用专属 key 区分。
    final cards = tester.widgetList(find.byWidgetPredicate(
      (w) =>
          w is InkWell &&
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('srcCard-'),
    )).length;
    expect(cards, expected);
  });

  testWidgets('当前源卡片上有选中标记（✓），点击第二张后切换', (tester) async {
    await openDialog(tester);
    // 初始：只有 1 个选中标记，且为默认当前源。
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    final sources = st.allSources.where((s) => !s.overlay).toList();
    expect(st.curSource.id, sources.first.id);

    // 点击第二张。
    await tester.tap(find.text(sources[1].name));
    await tester.pumpAndSettle();
    expect(st.curSource.id, sources[1].id);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('叠加层是互斥单选：存在 RadioListTile 且不存在 CheckboxListTile',
      (tester) async {
    await openDialog(tester);
    // 注意：find.byType 是**精确** runtimeType 匹配，`RadioListTile<String>`
    // 不会被 `find.byType(RadioListTile)`（= `<dynamic>`）命中，必须用谓词。
    expect(find.byWidgetPredicate((w) => w is RadioListTile), findsWidgets);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('点「无」后 overlayId == null', (tester) async {
    await openDialog(tester);
    // 先切到一个真实叠加层（滚动到可见后再点），再点「无」，验证回到 null。
    final overlays = st.allOverlays;
    if (overlays.isNotEmpty) {
      final tile = find.text(overlays.first.name);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(st.overlayId, overlays.first.id);
    }
    final none = find.text('无');
    await tester.ensureVisible(none);
    await tester.tap(none);
    await tester.pumpAndSettle();
    expect(st.overlayId, isNull);
  });
}
