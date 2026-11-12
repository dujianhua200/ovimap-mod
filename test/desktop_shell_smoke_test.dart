// 桌面壳关键机制的 widget 级验证（真实 pump，非源级字符串断言）。
//
// 为什么需要它：本机（macOS）没装完整 Xcode（`xcode-select -p` 指向
// /Library/Developer/CommandLineTools），**无法本地构建 macOS 包**做肉眼验收，
// 桌面产物只能靠 CI。本文件用 widget 层兜住「本次桌面改造最容易回归的两处」：
//
//   A. 状态栏「鼠标经纬度」——奥维桌面版的标志性字段，且走 ValueNotifier 局部刷新，
//      需要证明「notifier 一改，那一格文本就跟着变」；
//   B. 快捷键裸键守卫——框内编辑时不得被 Backspace / Delete / `+` 截胡。
//
// ⚠️ 刻意**不**在这里 pump 整个 WorkspacePage：它内含 FlutterMap，瓦片加载会挂出
// 一堆 Timer，`flutter test` 会一直挂着不返回（实测 90s+ 未结束）。整壳的结构在位
// 由 test/desktop_shell_wiring_test.dart 的源级断言覆盖。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import 'package:ovimap/geo/geo_util.dart';
import 'package:ovimap/services/platform_caps.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/desktop/shortcuts.dart';
import 'package:ovimap/ui/desktop/status_bar.dart';

/// 取某个文本 widget 的当前字符串（未命中返回 null）。
String? textOf(WidgetTester tester, Finder f) =>
    f.evaluate().isEmpty ? null : (f.evaluate().first.widget as Text).data;

void main() {
  group('A. 状态栏鼠标经纬度（奥维桌面版口径）', () {
    testWidgets('初始显示「鼠标 —」，notifier 更新后随之刷新，且不重建整栏', (tester) async {
      final st = AppState();
      final mouse = ValueNotifier<LatLng?>(null);
      addTearDown(mouse.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: st,
          child: MaterialApp(
            home: Scaffold(
              body: StatusBar(
                st: st,
                centerText: '32.130100, 114.081400',
                zoom: 17.5,
                selectedCount: 0,
                mouseGeo: mouse,
              ),
            ),
          ),
        ),
      );

      // 奥维口径字段：鼠标处经纬度 + 视图中心 + 缩放 + 坐标系
      expect(find.textContaining('鼠标 —'), findsOneWidget,
          reason: '鼠标未进入地图时应显示占位');
      expect(find.textContaining('中心 32.130100, 114.081400'), findsOneWidget);
      expect(find.textContaining('缩放 17.5'), findsOneWidget);
      expect(find.textContaining('坐标系'), findsOneWidget);
      // 未接入同步 → 退化为本地模式（可空接入的 AOT 安全口径）
      expect(find.textContaining('本地模式'), findsOneWidget);

      // 模拟鼠标移到 WGS-84 (32.13, 114.08) 上方 → 那一格文本必须跟着变。
      // 注意：状态栏显示的是**显示基准**下的坐标（与视图中心同口径），
      // 因此期望值要用 toDisplay + formatCoord 现算，不能写死 WGS-84 数值。
      const hover = LatLng(32.13, 114.08);
      final d = st.toDisplay(hover.latitude, hover.longitude);
      final expected = GeoUtil.formatCoord(d[0], d[1], st.coordFmt);

      mouse.value = hover;
      await tester.pump();

      final after = textOf(tester, find.textContaining('鼠标 '));
      expect(after, isNotNull, reason: '鼠标格必须始终在位');
      expect(after, '鼠标 $expected',
          reason: '鼠标格应显示指针处坐标（按当前显示基准格式化）');
      expect(find.textContaining('鼠标 —'), findsNothing);

      // 鼠标移出地图（回传 null）→ 回到占位
      mouse.value = null;
      await tester.pump();
      expect(find.textContaining('鼠标 —'), findsOneWidget);
    });
  });

  group('B. 快捷键裸键守卫（不吞文本框输入）', () {
    testWidgets('焦点在文本框内：Backspace/Delete/`+` 不被截胡；焦点移出后正常触发', (tester) async {
      var undoPoint = 0, zoomIn = 0, zoomOut = 0, deleted = 0;
      final tf = FocusNode(debugLabel: 'tf');
      final other = FocusNode(debugLabel: 'other');
      final ctl = TextEditingController(text: 'ab');
      addTearDown(() {
        tf.dispose();
        other.dispose();
        ctl.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          // TextField 需要 Material 祖先（Scaffold 提供）。
          home: Scaffold(
            body: DesktopShortcuts(
              onSave: () {},
              onUndo: () {},
              onRedo: () {},
              onDeleteSelection: () => deleted++,
              onExport: () {},
              onFocusSearch: () {},
              onOpenProject: () {},
              onZoomIn: () => zoomIn++,
              onZoomOut: () => zoomOut++,
              onResetView: () {},
              onEscape: () {},
              onUndoPoint: () => undoPoint++,
              // 侧栏 / 专注地图（本轮新增的三个视图快捷键）。
              onToggleLeft: () {},
              onToggleRight: () {},
              onFocusMap: () {},
              onInspect: () {},
              child: Column(
                children: [
                  TextField(focusNode: tf, controller: ctl),
                  // 一个非文本的可聚焦节点：用来把焦点移出文本框。
                  Focus(
                      focusNode: other,
                      child: const SizedBox(width: 10, height: 10)),
                ],
              ),
            ),
          ),
        ),
      );

      // ---- 焦点在文本框内：按键必须交给文本框 ----
      tf.requestFocus();
      await tester.pump();
      ctl.selection = const TextSelection.collapsed(offset: 2); // 光标移到末尾

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(ctl.text, 'a',
          reason: '文本框内的 Backspace 必须删字符（曾被裸键快捷键截胡）');
      expect(undoPoint, 0, reason: '编辑文本时不得触发「退点」');

      // 用 `equal`（`=` 键）模拟裸键：`LogicalKeyboardKey.add` 在
      // flutter_test 的事件模拟里没有对应物理键（会断言失败），
      // 而 `add` / `numpadAdd` 的注册由 desktop_shell_wiring_test 的源级断言覆盖。
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();
      expect(zoomIn, 0, reason: '编辑文本时不得触发缩放');

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(deleted, 0, reason: '编辑文本时不得触发「删除选中点」');

      // ---- 焦点移出文本框：快捷键恢复 ----
      other.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(undoPoint, 1, reason: '焦点不在文本框时，Backspace 应触发「退点」');

      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();
      expect(zoomIn, 1, reason: '焦点不在文本框时，= / + 键应触发放大');

      // 带修饰键的组合不受守卫影响：焦点在文本框内也应触发（Ctrl 组合不参与开关）。
      tf.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.minus);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(zoomOut, 1,
          reason: 'Ctrl+- 是修饰键组合，编辑文本时也应生效（否则快捷键等于被守卫误伤）');
    });
  });

  test('本机为桌面平台（桌面壳相关断言才有意义）', () {
    expect(PlatformCaps.isDesktop, isTrue);
  });
}
