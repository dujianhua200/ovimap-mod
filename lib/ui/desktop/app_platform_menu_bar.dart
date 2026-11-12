import 'package:flutter/material.dart';

import '../../services/platform_caps.dart';
import '../../state/app_state.dart';
import 'menu_model.dart';

/// macOS 原生菜单栏渲染器。
///
/// 把 [oviMenuGroups] 渲染到**屏幕顶部的系统菜单栏**，取代窗口内自绘菜单栏。
/// 带来三件事（都是用户明确要求的）：
///
/// 1. **只有一行菜单** —— 不再出现「系统一行英文 + 窗口内一行中文」的割裂；
/// 2. **悬停即展开** —— 菜单展开后鼠标横扫即切换，不用「点一下关、再点一下开」；
/// 3. **⌘ 快捷键原生生效** —— 快捷键提示由系统绘制，且优先于窗口内容吃按键。
///
/// ## 应用菜单必须自己给
///
/// `PlatformMenuBar` 接管的是**整个主菜单**（含 macOS 那个以应用名命名的
/// 第一个菜单）。Flutter 不会替我们生成它 —— 官方示例里也是把 `Quit`
/// 作为第一个菜单的成员显式写进去的。所以这里必须自己建「关于 / 隐藏 / 退出」，
/// 否则用户会失去 ⌘Q 退出与 ⌘H 隐藏。
/// 系统级行为（隐藏、隐藏其他、全部显示、退出）走 [PlatformProvidedMenuItem]，
/// 因为那些是 `hide:` / `terminate:` 这类 selector，纯 Flutter 复刻不了；
/// 「关于」走我们自己的对话框（比系统面板信息多）。窗口菜单同理。
class AppPlatformMenuBar extends StatelessWidget {
  const AppPlatformMenuBar({
    super.key,
    required this.st,
    required this.actions,
    required this.child,
  });

  final AppState st;
  final OviMenuActions actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 非 macOS 直接透传：Windows / Linux 走自绘菜单栏（`app_menu_bar.dart`）。
    if (!PlatformCaps.isMacOS) return child;
    return PlatformMenuBar(menus: _buildMenus(context), child: child);
  }

  List<PlatformMenuItem> _buildMenus(BuildContext context) {
    final groups = oviMenuGroups;
    return <PlatformMenuItem>[
      PlatformMenu(label: '滑洲云图', menus: _appMenu(context)),
      // 业务菜单：全部，但把「帮助」留到最后（前面插「窗口」）
      for (final g in groups.take(groups.length - 1)) _group(context, g),
      PlatformMenu(label: '窗口', menus: _windowMenu()),
      _group(context, groups.last),
    ];
  }

  /// 应用菜单（macOS 上第一个、以应用名命名的菜单）。
  List<PlatformMenuItem> _appMenu(BuildContext context) {
    return <PlatformMenuItem>[
      PlatformMenuItemGroup(members: [
        PlatformMenuItem(
          label: '关于 滑洲云图',
          onSelected: () => _fire(context, 'about'),
        ),
      ]),
      if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.hide))
        PlatformMenuItemGroup(members: [
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
          if (PlatformProvidedMenuItem.hasMenu(
              PlatformProvidedMenuItemType.hideOtherApplications))
            const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.hideOtherApplications),
          if (PlatformProvidedMenuItem.hasMenu(
              PlatformProvidedMenuItemType.showAllApplications))
            const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.showAllApplications),
        ]),
      if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.quit))
        PlatformMenuItemGroup(members: const [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
        ]),
    ];
  }

  /// 窗口菜单：最小化 / 缩放 / 全屏 —— 全走系统 selector。
  List<PlatformMenuItem> _windowMenu() {
    final items = <PlatformMenuItem>[];
    for (final t in const [
      PlatformProvidedMenuItemType.minimizeWindow,
      PlatformProvidedMenuItemType.zoomWindow,
      PlatformProvidedMenuItemType.toggleFullScreen,
    ]) {
      if (PlatformProvidedMenuItem.hasMenu(t)) {
        items.add(PlatformProvidedMenuItem(type: t));
      }
    }
    return items.isEmpty
        ? const <PlatformMenuItem>[]
        : <PlatformMenuItem>[PlatformMenuItemGroup(members: items)];
  }

  /// 一个顶层菜单：按 [OviMenuItemDef.dividerBefore] 切成若干组，
  /// 组间由 `PlatformMenuItemGroup` 自动画分隔线。
  PlatformMenu _group(BuildContext context, OviMenuGroupDef g) {
    final chunks = <List<OviMenuItemDef>>[];
    for (final it in g.items) {
      if (it.dividerBefore || chunks.isEmpty) chunks.add(<OviMenuItemDef>[]);
      chunks.last.add(it);
    }
    return PlatformMenu(
      label: g.label,
      menus: <PlatformMenuItem>[
        for (final c in chunks)
          PlatformMenuItemGroup(members: <PlatformMenuItem>[
            for (final it in c)
              PlatformMenuItem(
                label: it.label,
                // 裸键（如 Delete）的 activator 故意留空：声明成菜单快捷键会把
                // 按键从文本框里抢走。详见 `menu_model.dart` 的类注释。
                shortcut: it.activator,
                onSelected: () => _fire(context, it.id),
              ),
          ]),
      ],
    );
  }

  /// 菜单点击 → 唯一分发点。分发是异步的（要弹对话框），
  /// 但菜单回调签名是同步的，所以这里不 await —— 菜单本身已关闭，无后续依赖。
  void _fire(BuildContext context, String id) {
    dispatchOviMenuItem(context, st, id, actions);
  }
}
