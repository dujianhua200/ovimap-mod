// 符号库 UI 与资源包装载的接线验证。
//
// 单元测试只能证明"解析器和导出器对"，证明不了"软件里真的能选到图例库符号"。
// 本文件补上这一层：
//  1. `rootBundle` 能读到 pubspec 里登记的 lispblock.dxf；
//  2. 启动装载后 `LabelType.all` 里真的出现 gl001 等图块符号；
//  3. 「符号库」对话框把它们按组列出来（杆/井/拉线…），并且**画的是真几何**；
//  4. 选中图块符号后 `curType` 变成该块、`setType` 顺手进打点模式。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/label_type.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/symbols/symbol_catalog.dart';
import 'package:ovimap/ui/desktop/symbol_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('资源包装载', () {
    test('pubspec 登记的 lispblock.dxf 能从 rootBundle 读到并可解析', () async {
      SymbolCatalog.resetForTest();
      final cat = await SymbolCatalog.ensureLoaded();
      expect(cat.symbols, isNotEmpty,
          reason: 'assets/dxf/lispblock.dxf 必须被 pubspec 登记并成功解析');
      // 用户口径：ID=块编号，名称=图例文字
      final gl001 = cat.byId('gl001');
      expect(gl001, isNotNull);
      expect(gl001!.name, '新建水泥杆');

      final n = LabelType.installCatalog(cat);
      expect(n, greaterThan(0));
      expect(LabelType.fromId('gl001').isBlock, isTrue);
    });
  });

  group('符号库对话框', () {
    setUpAll(() async {
      final cat = await SymbolCatalog.ensureLoaded();
      LabelType.installCatalog(cat);
    });

    Future<AppState> state() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
      return st;
    }

    testWidgets('列出图例库符号（按组 + 显示块编号）', (tester) async {
      final st = await state();
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showSymbolLibrary(ctx, st),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('符号库（打点使用）'), findsOneWidget);
      // 分组标题存在（杆/井/拉线 至少出现）
      expect(find.textContaining('图例库 · 杆'), findsOneWidget);
      // 符号名与编号都要显示：用户是按 gl001 找块的
      expect(find.text('新建水泥杆'), findsWidgets);
      expect(find.text('gl001'), findsWidgets);
      // 内置符号区仍在（老工程/老习惯不能丢）
      expect(find.text('常用（内置符号）'), findsOneWidget);
    });

    testWidgets('点选图块符号 → curType 变成该块，并自动进入打点模式',
        (tester) async {
      final st = await state();
      expect(st.mode, isNot(AppMode.edit));
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showSymbolLibrary(ctx, st),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 点「新建水泥杆」那一格（用 SymbolTile 定位，避免命中滚动区外的同名文字）
      final tile = find.byWidgetPredicate(
          (w) => w is SymbolTile && w.type.id == 'gl001');
      expect(tile, findsOneWidget);
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(st.curType.id, 'gl001');
      expect(st.curType.name, '新建水泥杆');
      expect(st.mode, AppMode.edit,
          reason: '选完符号语义就是"我要放这个符号"，应直接进打点模式');
      expect(find.text('符号库（打点使用）'), findsNothing, reason: '对话框应关闭');
    });

    testWidgets('图例库块用真几何绘制（不是色块占位）', (tester) async {
      final st = await state();
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showSymbolLibrary(ctx, st),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // SymbolTile 里凡 type.isBlock 都渲染 DxfBlockThumb
      expect(find.byType(DxfBlockThumb), findsWidgets);
    });
  });

  group('地图符号', () {
    test('图块符号的 LabelSymbol 走真几何分支而非形状近似', () {
      final st = AppState();
      expect(st.curType.isBlock, isFalse, reason: '默认仍是内置符号');
      final t = LabelType.fromId('gl001');
      expect(t.isBlock, isTrue);
      expect(t.block, isNotNull);
      expect(t.block!.strokes, isNotEmpty);
    });
  });
}

/// 避免 analyzer 报 `SystemChannels` 未使用（本文件靠 TestWidgetsFlutterBinding
/// 初始化资源包通道，不需要显式调用）。
// ignore: unused_element
const Object _keepServicesImport = SystemChannels.platform;
