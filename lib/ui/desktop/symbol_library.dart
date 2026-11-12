import 'package:flutter/material.dart';

import '../../models/label_type.dart';
import '../../state/app_state.dart';
import '../dialogs.dart';
import '../../ui/design_tokens.dart';

/// 符号库选择器（桌面壳）。
///
/// ## 为什么要有这个文件
///
/// 16 种预置工程符号的选择入口此前**只有移动端有**（`lib/ui/home_page.dart`
/// 的「符号行」横排）。桌面壳的工具栏与菜单里都没有 —— 也就是说桌面端
/// 「打点之前没法选符号」，只能先落个默认的「管道口」再逐个改属性。
/// 用户反馈的「很多标签都没有了」正是这一条。
///
/// 这里做成**一个实现、两个入口**：工具栏的符号按钮与
/// 「工程 → 符号库…」菜单项都调 [showSymbolLibrary]，
/// 保证不会出现两套选符号的界面各自漂移。
///
/// 移动端继续用它自己的横排符号行（窄屏下横排比弹窗更快），
/// 两端共用同一份 [LabelType.all] 数据源，符号口径不会分叉。

/// 单个符号格子：色块 + 符号字 + 名称。
///
/// 形状提示（`LabelType.shape`）体现在圆角上，让「人孔是椭圆、箱体是方框」
/// 这类图例差异在选符号时一眼可见，而不是只看到文字。
class SymbolTile extends StatelessWidget {
  const SymbolTile({
    super.key,
    required this.type,
    required this.selected,
    required this.onTap,
    this.width = 96,
  });

  final LabelType type;
  final bool selected;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    // 无符号字的类型（轨迹/无标签/文字/区域）退化为名称首字，避免格子空着。
    // 用 substring 而非 characters：这些名称都是单 UTF-16 单元的汉字。
    final glyph = type.symbol.isNotEmpty
        ? type.symbol
        : (type.name.isNotEmpty ? type.name.substring(0, 1) : '·');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: selected ? TokC.field : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected ? kAccent : TokC.divider,
              width: selected ? 1.4 : 0.6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _shapeBox(type, glyph),
            const SizedBox(height: 6),
            Text(type.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: selected ? kAccent : kTextMain,
                    fontSize: 11.5)),
          ],
        ),
      ),
    );
  }

  /// 按图例形状画一个占位框，并填入符号字。
  Widget _shapeBox(LabelType type, String glyph) {
    final radius = switch (type.shape) {
      'oval' => BorderRadius.circular(999),
      'box' => BorderRadius.circular(3),
      'tri' => BorderRadius.circular(2),
      'text' => BorderRadius.circular(2),
      _ => BorderRadius.circular(999),
    };
    return Container(
      width: 30,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: type.color.withValues(alpha: 0.85),
        borderRadius: radius,
      ),
      child: Text(type.symbol.isNotEmpty ? type.symbol : glyph,
          style: const TextStyle(
              color: Colors.white, fontSize: 12, height: 1.1)),
    );
  }
}

/// 符号网格（对话框与任何未来入口共用）。
class SymbolGrid extends StatelessWidget {
  const SymbolGrid({super.key, required this.st, this.onPicked});

  final AppState st;

  /// 选中后的回调（对话框用它来关闭；其他宿主可为空）。
  final void Function(LabelType t)? onPicked;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final t in LabelType.all)
          SymbolTile(
            type: t,
            selected: st.curType.id == t.id,
            onTap: () {
              st.setType(t);
              onPicked?.call(t);
            },
          ),
      ],
    );
  }
}

/// 「符号库…」：桌面壳选符号的唯一入口。
///
/// 选中即生效（`st.setType`），并顺手把地图切到打点模式 —— 用户点开符号库的
/// 语义就是「我要放这个符号」，不该再让他回去点一次「打点」。
Future<void> showSymbolLibrary(BuildContext context, AppState st) async {
  await showDarkDialog(
    context,
    title: '符号库（打点使用）',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('当前：${st.curType.name}　（选中后地图自动进入打点模式）',
            style: const TextStyle(color: kTextSub, fontSize: 12)),
        const SizedBox(height: 10),
        SizedBox(
          width: 520,
          child: SymbolGrid(
            st: st,
            onPicked: (t) {
              st.setMode(AppMode.edit);
              Navigator.pop(context);
              toast(context, '已选符号「${t.name}」，在地图上点击落点');
            },
          ),
        ),
      ],
    ),
    actions: [
      darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
    ],
  );
}
