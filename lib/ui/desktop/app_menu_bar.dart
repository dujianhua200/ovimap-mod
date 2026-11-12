import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../dialogs.dart';
import 'menu_model.dart';
import '../../ui/design_tokens.dart';

/// 桌面顶部菜单栏（Windows / Linux 用；macOS 走 `app_platform_menu_bar.dart`
/// 的系统原生菜单）。
///
/// ## 为什么不用 `PopupMenuButton` / `MenuBar`
///
/// 旧实现用 `PopupMenuButton`，交互是「点标题展开 → 点条目执行」，且**展开后
/// 想换一个菜单必须先把它点掉**（切换要两次点击）。用户明确要求
/// 「鼠标放到哪个菜单就自动弹出」。而 Flutter 的 `MenuBar` / `SubmenuButton`
/// **都没有悬停展开能力**（`menu_anchor.dart` 里没有 `MouseRegion`/`onHover`），
/// 所以这里自己用 `Overlay` + `MouseRegion` 实现：
///
/// - 指针在标题上**停留 120ms** 即展开（留一个停留阈值，避免鼠标横扫顶部时
///   一路误弹）；
/// - 展开状态下，指针移到别的标题上**立即切换**（零延迟，这才是"切换不用点两次"）；
/// - 指针离开标题/面板 200ms 后收起（延迟是为了让指针能"路过缝隙"进面板）。
///
/// 菜单项定义与快捷键全部来自 [oviMenuGroups] —— 与 macOS 原生菜单同源，
/// 不会出现两端功能漂移。
class AppMenuBar extends StatefulWidget {
  const AppMenuBar({super.key, required this.st, required this.actions});

  final AppState st;
  final OviMenuActions actions;

  /// 条形高度（与改造前一致，桌面壳布局依赖这个值）。
  static const double barHeight = 34;

  @override
  State<AppMenuBar> createState() => _AppMenuBarState();
}

class _AppMenuBarState extends State<AppMenuBar> {
  /// 每个顶层菜单标题的定位锚（用于把下拉面板对齐到标题下方）。
  final List<GlobalKey> _anchors = [
    for (var i = 0; i < oviMenuGroups.length; i++) GlobalKey(),
  ];

  /// 当前展开的菜单下标；null 表示全部收起。
  int? _open;

  OverlayEntry? _entry;
  Timer? _hoverTimer;
  Timer? _closeTimer;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    _closeTimer?.cancel();
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  // ---------------- 展开 / 收起 ----------------

  /// 指针进入标题：已展开 → 立即切换；未展开 → 停留 120ms 后展开。
  void _onEnterTitle(int i) {
    _closeTimer?.cancel();
    if (_open != null) {
      if (_open != i) _show(i);
      return;
    }
    _hoverTimer?.cancel();
    _hoverTimer = Timer(const Duration(milliseconds: 120), () {
      if (mounted && _open == null) _show(i);
    });
  }

  /// 指针离开标题：给 200ms 宽限，让指针能往下进入面板而不被收起。
  void _onExitTitle() {
    _hoverTimer?.cancel();
    _scheduleClose();
  }

  void _onTapTitle(int i) {
    _hoverTimer?.cancel();
    if (_open == i) {
      _close();
    } else {
      _show(i);
    }
  }

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _close();
    });
  }

  void _close() {
    _hoverTimer?.cancel();
    _closeTimer?.cancel();
    _entry?.remove();
    _entry = null;
    if (_open != null) setState(() => _open = null);
  }

  void _show(int i) {
    _hoverTimer?.cancel();
    final anchorCtx = _anchors[i].currentContext;
    if (anchorCtx == null) return;
    final box = anchorCtx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    final origin = box.localToGlobal(Offset.zero);
    final rect = Rect.fromLTWH(origin.dx, origin.dy, box.size.width, box.size.height);

    _entry?.remove();
    _entry = OverlayEntry(builder: (_) => _dropdown(i, rect));
    Overlay.of(context).insert(_entry!);
    setState(() => _open = i);
  }

  // ---------------- 下拉面板 ----------------

  Widget _dropdown(int index, Rect anchor) {
    final group = oviMenuGroups[index];
    return Stack(
      children: [
        // 点到面板以外（且不在菜单栏上）→ 收起。
        // 上边界压在菜单栏下沿，保证顶部标题仍可点击（点标题=切换/收起）。
        Positioned(
          left: 0,
          right: 0,
          top: anchor.bottom,
          bottom: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: anchor.left,
          top: anchor.bottom,
          child: MouseRegion(
            onEnter: (_) => _closeTimer?.cancel(),
            onExit: (_) => _scheduleClose(),
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 252,
                padding: const EdgeInsets.symmetric(vertical: 5),
                decoration: const BoxDecoration(
                  color: kPanelBg,
                  border: Border.fromBorderSide(BorderSide(color: TokC.divider)),
                  boxShadow: [
                    BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 10,
                        offset: Offset(0, 4)),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var k = 0; k < group.items.length; k++) ...[
                      if (k > 0 && group.items[k].dividerBefore)
                        const Divider(height: 7, color: TokC.divider),
                      _menuRow(group.items[k]),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuRow(OviMenuItemDef item) {
    return InkWell(
      onTap: () {
        _close();
        // 分发是异步的（要弹对话框），菜单回调签名同步 —— 菜单此刻已关，
        // 没有后续依赖，故不 await。
        dispatchOviMenuItem(context, widget.st, item.id, widget.actions);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kTextMain, fontSize: 12.5)),
            ),
            if (item.keys != null)
              Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Text(item.keys!,
                    style: const TextStyle(color: kTextSub, fontSize: 11)),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------- 菜单栏本体 ----------------

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AppMenuBar.barHeight,
      decoration: const BoxDecoration(
        color: TokC.toolbar,
        border: Border(bottom: BorderSide(color: TokC.divider)),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('滑洲云图',
                style: TextStyle(
                    color: kTextMain,
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
          ),
          for (var i = 0; i < oviMenuGroups.length; i++)
            MouseRegion(
              key: _anchors[i],
              onEnter: (_) => _onEnterTitle(i),
              onExit: (_) => _onExitTitle(),
              child: GestureDetector(
                onTap: () => _onTapTitle(i),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  color: _open == i ? TokC.field : null,
                  child: Text(oviMenuGroups[i].label,
                      style: TextStyle(
                          color: _open == i ? kAccent : kTextMain,
                          fontSize: 12.5)),
                ),
              ),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}
