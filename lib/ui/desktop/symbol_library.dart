import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/label_type.dart';
import '../../state/app_state.dart';
import '../../symbols/dxf_block_parser.dart';
import '../dialogs.dart';
import '../../ui/design_tokens.dart';

/// 符号库选择器（桌面壳）。
///
/// ## 为什么要有这个文件
/// 16 种预置工程符号的选择入口此前**只有移动端有**（`lib/ui/home_page.dart`
/// 的「符号行」横排）。桌面壳的工具栏与菜单里都没有 —— 也就是说桌面端
/// 「打点之前没法选符号」，只能先落个默认的「管道口」再逐个改属性。
/// 用户反馈的「很多标签都没有了」正是这一条。
///
/// 现在符号来源有两套（见 `label_type.dart` 头注释）：
/// 1. 预置 16 种（英文 id，形状近似绘制）；
/// 2. 随包图例库 `assets/dxf/lispblock.dxf` 的真图块（编号 id，真几何绘制）。
/// 本库按这两套分栏列出，图例库符号**用 DXF 原始几何画缩略图**，
/// 所见即出图所得。
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
            SizedBox(
              width: 34,
              height: 26,
              child: type.isBlock
                  ? DxfBlockThumb(
                      block: type.block!,
                      color: selected ? kAccent : TokC.textMain,
                      strokeWidth: selected ? 1.3 : 1.0,
                    )
                  : Center(child: _shapeChip(type, glyph)),
            ),
            const SizedBox(height: 6),
            Text(type.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: selected ? kAccent : kTextMain, fontSize: 11)) ,
            // 图例库符号把编号显示出来：用户就是按 gl001 / gx005_x 找块的。
            if (type.isBlock)
              Text(type.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kTextSub, fontSize: 9.5)),
          ],
        ),
      ),
    );
  }

  /// 按图例形状画一个占位框，并填入符号字（预置符号用）。
  Widget _shapeChip(LabelType type, String glyph) {
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

/// 用归一化 DXF 几何画一个符号缩略图（保持长宽比、留 2px 边距）。
///
/// 这是"所见即所得"的关键：符号库里看到的形状，就是导出到 CAD 里的形状。
class DxfBlockThumb extends StatelessWidget {
  const DxfBlockThumb({
    super.key,
    required this.block,
    this.color = const Color(0xFF37474F),
    this.strokeWidth = 1.0,
  });

  final DxfBlock block;
  final Color color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _BlockThumbPainter(block, color, strokeWidth),
        child: const SizedBox.expand(),
      );
}

class _BlockThumbPainter extends CustomPainter {
  _BlockThumbPainter(this.block, this.color, this.strokeWidth);

  final DxfBlock block;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (block.isEmpty) return;
    final w = block.width <= 0 ? 1.0 : block.width;
    final h = block.height <= 0 ? 1.0 : block.height;
    const pad = 2.0;
    final sx = (size.width - pad * 2) / w;
    final sy = (size.height - pad * 2) / h;
    final s = math.min(sx, sy);
    // 居中：几何中心对齐画布中心。
    final cx = size.width / 2, cy = size.height / 2;
    final mx = (block.minX + block.maxX) / 2;
    final my = (block.minY + block.maxY) / 2;
    Offset map(double x, double y) =>
        Offset(cx + (x - mx) * s, cy - (y - my) * s); // DXF 的 Y 向上

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    for (final stroke in block.strokes) {
      switch (stroke) {
        case SymbolLine():
          canvas.drawLine(map(stroke.x1, stroke.y1),
              map(stroke.x2, stroke.y2), paint);
        case SymbolCircle():
          canvas.drawCircle(
              map(stroke.cx, stroke.cy), stroke.r * s, paint);
        case SymbolArc():
          // 圆弧用折线近似（缩略图不需要精度）。
          const n = 24;
          var a0 = stroke.a0 * math.pi / 180;
          var a1 = stroke.a1 * math.pi / 180;
          if (a1 <= a0) a1 += 2 * math.pi;
          final path = Path();
          for (var i = 0; i <= n; i++) {
            final t = a0 + (a1 - a0) * i / n;
            final p = map(stroke.cx + stroke.r * math.cos(t),
                stroke.cy + stroke.r * math.sin(t));
            if (i == 0) {
              path.moveTo(p.dx, p.dy);
            } else {
              path.lineTo(p.dx, p.dy);
            }
          }
          canvas.drawPath(path, paint);
        case SymbolPoly():
          if (stroke.pts.length < 2) continue;
          final path = Path();
          for (var i = 0; i < stroke.pts.length; i++) {
            final p = map(stroke.pts[i][0], stroke.pts[i][1]);
            if (i == 0) {
              path.moveTo(p.dx, p.dy);
            } else {
              path.lineTo(p.dx, p.dy);
            }
          }
          if (stroke.closed) path.close();
          canvas.drawPath(path, paint);
        case SymbolText():
          // 块内文字（图例里的"木""人""移"）：缩略图按字高画个小字。
          final tp = TextPainter(
            text: TextSpan(
                text: stroke.text,
                style: TextStyle(
                    color: color, fontSize: math.max(5, stroke.h * s))),
            textDirection: TextDirection.ltr,
          )..layout();
          final p = map(stroke.x, stroke.y);
          tp.paint(canvas, Offset(p.dx - tp.width / 2, p.dy - tp.height / 2));
        default:
          break;
      }
    }
  }

  @override
  bool shouldRepaint(_BlockThumbPainter old) =>
      old.block != block ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
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
///
/// 图例库符号按分组分栏（杆 / 井 / 拉线 / 设施 / 其他），因为图例库有 60+
/// 个点符号，平铺成一坨会让人找不到「新建水泥杆」。
Future<void> showSymbolLibrary(BuildContext context, AppState st) async {
  final groups = <String, List<LabelType>>{};
  final builtins = <LabelType>[];
  for (final t in LabelType.all) {
    if (!t.isBlock) {
      builtins.add(t);
      continue;
    }
    groups.putIfAbsent(t.group.isEmpty ? '图例库' : t.group, () => []).add(t);
  }

  await showDarkDialog(
    context,
    title: '符号库（打点使用）',
    width: 880,
    content: SizedBox(
      width: 860,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                '当前：${st.curType.name}'
                '${st.curType.isBlock ? '（图块 ${st.curType.id}）' : ''}'
                '　（选中后地图自动进入打点模式）',
                style: const TextStyle(color: kTextSub, fontSize: 12)),
            const SizedBox(height: 10),
            _sectionTitle('常用（内置符号）'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in builtins)
                  SymbolTile(
                    type: t,
                    selected: st.curType.id == t.id,
                    onTap: () => _pick(context, st, t),
                  ),
              ],
            ),
            // 图例库：有就按分组列，没有就说明资源没装上（而不是静默空白）。
            if (groups.isEmpty) ...[
              const SizedBox(height: 14),
              const Text(
                  '未加载图例库（assets/dxf/lispblock.dxf）。\n'
                  '把用户的图例 DXF 放到该路径并重新构建，符号库会自动出现图块符号。',
                  style: TextStyle(color: kTextSub, fontSize: 12, height: 1.5)),
            ] else
              for (final entry in groups.entries) ...[
                const SizedBox(height: 14),
                _sectionTitle('图例库 · ${entry.key}（${entry.value.length}）'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in entry.value)
                      SymbolTile(
                        type: t,
                        selected: st.curType.id == t.id,
                        onTap: () => _pick(context, st, t),
                      ),
                  ],
                ),
              ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
    actions: [
      darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
    ],
  );
}

void _pick(BuildContext context, AppState st, LabelType t) {
  st.setType(t);
  Navigator.pop(context);
  toast(context,
      '已选符号「${t.name}」${t.isBlock ? '（块 ${t.id}）' : ''}，在地图上点击落点');
}

Widget _sectionTitle(String s) => Text(s,
    style: const TextStyle(
        color: kTextSub, fontSize: 11.5, fontWeight: FontWeight.w600));
