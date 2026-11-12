import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/services/platform_caps.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/desktop/app_platform_menu_bar.dart';
import 'package:ovimap/ui/desktop/menu_model.dart';

/// macOS 原生菜单的结构回归测试。
///
/// ## 为什么这个测试值得存在
///
/// 用户反馈「上面一排英文菜单、下面还有一排中文菜单」。修复方案是让
/// `PlatformMenuBar` **整体接管** macOS 主菜单 —— 也就是说，屏幕顶部那一排
/// 由我们这份定义决定，一旦有人往 [oviMenuGroups] 里加菜单项却忘了给
/// [dispatchOviMenuItem] 加分支（或反之），菜单就会出现「点了没反应」的项。
///
/// `flutter test` 跑在**宿主机**上，所以在 macOS 上跑时 `Platform.isMacOS`
/// 为真，[AppPlatformMenuBar] 会走真实分支 —— 于是可以直接断言**实际交给系统
/// 的那份菜单树**，而不是断言源码字符串。
void main() {
  group('菜单真源（两端共用）', () {
    test('id 全局唯一 —— 分发器靠 id 路由，重复会静默串味', () {
      final ids = <String>[
        for (final g in oviMenuGroups)
          for (final it in g.items) it.id,
      ];
      expect(ids.toSet().length, equals(ids.length),
          reason: '菜单项 id 出现重复：$ids');
    });

    test('七个业务分组齐全且顺序固定', () {
      expect(oviMenuGroups.map((g) => g.label).toList(),
          equals(<String>['文件', '编辑', '工程', '视图', '底图', '同步', '帮助']));
    });

    test('本轮修复涉及的入口都在菜单里（防再次丢失）', () {
      final ids = <String>[
        for (final g in oviMenuGroups)
          for (final it in g.items) it.id,
      ];
      // 「竣工模式没了 / 很多标签也没了」的修复入口。
      expect(ids, contains('symbol_lib')); // 符号库（16 种符号）
      expect(ids, contains('design_mode')); // 设计模式
      expect(ids, contains('completion_mode')); // 竣工模式
      // 「地图利用率」的修复入口。
      expect(ids, contains('focus_map'));
      expect(ids, contains('toggle_left'));
      expect(ids, contains('toggle_right'));
    });

    test('裸键不声明为原生快捷键（否则会把 Delete 从文本框抢走）', () {
      for (final g in oviMenuGroups) {
        for (final it in g.items) {
          if (it.keys == 'Delete') {
            expect(it.activator, isNull,
                reason: '${it.id} 声明了裸键 Delete 的原生快捷键，会吞掉文本框删除');
          }
        }
      }
    });
  });

  testWidgets('macOS：实际交给系统的菜单是一排中文（含应用菜单与窗口菜单）',
      (tester) async {
    // ⚠️ 必须覆写目标平台：`flutter_test` 默认把 `defaultTargetPlatform` 伪装成
    // **android**，而 `PlatformProvidedMenuItem.hasMenu` 恰恰是按它判定的
    // （它看 `defaultTargetPlatform`，不是 `dart:io` 的 `Platform`，
    // 两者在测试环境里并不一致）。不覆写就永远断言不到
    // 「应用菜单里到底有没有退出项」的真值 —— 会得到空集，看着像缺陷。
    //
    // 复位必须发生在**测试体结束之前**：`flutter_test` 在跑 tearDown 之前就会调
    // `debugAssertAllFoundationVarsUnset`，用 `addTearDown` 复位会晚一步报
    // "A Timer is still pending" 一类的收尾错误。所以用 try/finally。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _verifyMacosMenus(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// 断言体（抽成独立函数，才能用 try/finally 把平台覆写复位于测试体之内）。
Future<void> _verifyMacosMenus(WidgetTester tester) async {
  final st = AppState();
    const noop = _Noop();
    final actions = OviMenuActions(
      onNewProject: noop.call,
      onOpenProject: noop.call,
      onExportProject: noop.call,
      onSave: noop.call,
      onExport: noop.call,
      onUndo: noop.call,
      onRedo: noop.call,
      onDeleteSelection: noop.call,
      onPoleTable: noop.call,
      onTrackCheck: noop.call,
      onOffline: noop.call,
      onStorageCleanup: noop.call,
      onSync: noop.call,
      onToggleLeft: noop.call,
      onToggleRight: noop.call,
      onFocusMap: noop.call,
      onInspect: noop.call,
      onZoomIn: noop.call,
      onZoomOut: noop.call,
      onResetView: noop.call,
      onFocusSearch: noop.call,
    );

    await tester.pumpWidget(MaterialApp(
      home: AppPlatformMenuBar(
        st: st,
        actions: actions,
        child: const SizedBox.expand(),
      ),
    ));

    if (!PlatformCaps.isMacOS) {
      // Windows / Linux：该组件刻意透传 child（菜单由窗口内自绘菜单栏承担）。
      expect(find.byType(PlatformMenuBar), findsNothing);
      return;
    }

    final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
    final labels = bar.menus.map((m) => m.label).toList();

    // 应用菜单（以应用名命名）在最前，随后是业务菜单 + 窗口菜单。
    expect(
        labels,
        equals(<String?>[
          '滑洲云图',
          '文件',
          '编辑',
          '工程',
          '视图',
          '底图',
          '同步',
          '窗口',
          '帮助',
        ]));

    // 「上面一排英文菜单」的回归护栏：绝不能出现这些英文顶层菜单。
    for (final bad in const ['Edit', 'View', 'Window', 'Help', 'File']) {
      expect(labels, isNot(contains(bad)),
          reason: '顶层菜单不应再出现英文「$bad」');
    }

    // 应用菜单必须自带「退出」—— PlatformMenuBar 接管整个主菜单后，
    // 系统不会替我们生成它，漏掉等于用户失去 ⌘Q。
    // 注意系统项是包在 `PlatformMenuItemGroup` 里的（分隔线用），
    // 所以要递归进分组，而不是只看菜单的直接子项。
    final appMenu = bar.menus.first as PlatformMenu;
    final appMenuTypes = _providedTypesOf(appMenu);
    expect(appMenuTypes, contains(PlatformProvidedMenuItemType.quit));
    expect(appMenuTypes, contains(PlatformProvidedMenuItemType.hide));

    // 业务菜单的项也必须是中文、且带 id 对应的实现（抽查本轮修复项）。
    final fileMenu = bar.menus[1] as PlatformMenu;
    expect(_labelsOf(fileMenu), contains('新建工程'));
    final viewMenu = bar.menus[4] as PlatformMenu;
    expect(_labelsOf(viewMenu), contains('切到竣工模式'));
    expect(_labelsOf(viewMenu), contains('专注地图（两侧全收）'));
}

/// 取一个菜单下所有条目的文案（含分组展开）。
List<String?> _labelsOf(PlatformMenu menu) => <String?>[
      for (final m in menu.menus)
        if (m is PlatformMenuItemGroup)
          for (final s in m.members) s.label
        else
          m.label,
    ];

/// 取一个菜单里出现的**系统提供项**类型（递归进分组，系统项都包在分组里）。
Set<PlatformProvidedMenuItemType> _providedTypesOf(PlatformMenu menu) {
  final out = <PlatformProvidedMenuItemType>{};
  void scan(List<PlatformMenuItem> items) {
    for (final m in items) {
      if (m is PlatformMenuItemGroup) {
        scan(m.members);
      } else if (m is PlatformProvidedMenuItem) {
        out.add(m.type);
      }
    }
  }

  scan(menu.menus);
  return out;
}

/// 一组空回调（本测试只关心菜单结构，不触发动作）。
class _Noop {
  const _Noop();
  void call() {}
}
