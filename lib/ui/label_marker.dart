import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/label_type.dart';
import '../models/map_label.dart';

/// 地图标签符号（按图例形状绘制）。
///
/// 锚点约定：符号几何中心 = 地图点（连线接到符号外围中心）；
/// 名称文字挂在符号下方，不影响锚点。
/// 轨迹/无标签类型不画符号（只画连线+距离）。
class LabelSymbol extends StatelessWidget {
  final MapLabel label;
  final bool selected;
  final double scale;

  const LabelSymbol({
    super.key,
    required this.label,
    this.selected = false,
    this.scale = 1.0,
  });

  static const double symbolSize = 28;

  @override
  Widget build(BuildContext context) {
    final lt = label.type;

    // 轨迹/无标签：不画符号，仅连线与距离
    if (lt.id == 'none' || lt.id == 'track') return const SizedBox.shrink();

    // 区域顶点：小圆点
    if (lt.id == 'area') {
      return CustomPaint(
        size: Size(8 * scale, 8 * scale),
        painter: _DotPainter(color: lt.color, selected: selected),
      );
    }

    // 纯文字标注
    if (lt.id == 'text') {
      final txt = label.name.trim().isNotEmpty ? label.name.trim() : label.note;
      if (txt.isEmpty) return const SizedBox.shrink();
      return _OutlinedText(txt, 12 * scale);
    }

    final disp = label.name.trim().isNotEmpty
        ? label.name.trim()
        : (lt.symbol.isNotEmpty ? lt.symbol : lt.name);

    return SizedBox(
      width: symbolSize * scale,
      height: symbolSize * scale,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(symbolSize * scale, symbolSize * scale),
            painter: _ShapePainter(
              type: lt,
              symbol: disp,
              selected: selected,
            ),
          ),
          if (label.name.trim().isNotEmpty)
            Positioned(
              top: symbolSize * scale * 0.62,
              left: -70,
              right: -70,
              child: Center(
                child: _OutlinedText(label.name.trim(), 9.5 * scale),
              ),
            ),
        ],
      ),
    );
  }
}

class _DotPainter extends CustomPainter {
  final Color color;
  final bool selected;
  _DotPainter({required this.color, required this.selected});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    if (selected) {
      canvas.drawCircle(c, size.width / 2 + 2,
          Paint()..color = const Color(0xFFFFD740));
    }
    canvas.drawCircle(c, size.width / 2, Paint()..color = color);
    canvas.drawCircle(
        c,
        size.width / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = Colors.white);
  }

  @override
  bool shouldRepaint(_DotPainter old) =>
      old.color != color || old.selected != selected;
}

class _ShapePainter extends CustomPainter {
  final LabelType type;
  final String symbol;
  final bool selected;

  _ShapePainter(
      {required this.type, required this.symbol, required this.selected});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final w = size.width;

    if (selected) {
      canvas.drawCircle(c, w / 2 + 2, Paint()..color = const Color(0xFFFFD740));
    }
    // 阴影
    canvas.drawCircle(Offset(c.dx + 0.8, c.dy + 1.2), w / 2 - 2,
        Paint()..color = const Color(0x55000000));

    final fill = Paint()..color = type.color;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..color = Colors.white;

    switch (type.shape) {
      case 'oval':
        final r = Rect.fromCenter(center: c, width: w * 0.92, height: w * 0.62);
        canvas.drawOval(r, fill);
        canvas.drawOval(r, stroke);
        break;
      case 'box':
        final r = Rect.fromCenter(center: c, width: w * 0.86, height: w * 0.72);
        canvas.drawRRect(
            RRect.fromRectAndRadius(r, const Radius.circular(2)), fill);
        canvas.drawRRect(
            RRect.fromRectAndRadius(r, const Radius.circular(2)), stroke);
        break;
      case 'tri':
        final p = Path()
          ..moveTo(c.dx, c.dy - w * 0.42)
          ..lineTo(c.dx - w * 0.4, c.dy + w * 0.3)
          ..lineTo(c.dx + w * 0.4, c.dy + w * 0.3)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        break;
      default: // pin：圆形 + 尖角
        final tail = Path()
          ..moveTo(c.dx - w * 0.16, c.dy + w * 0.18)
          ..lineTo(c.dx, c.dy + w * 0.46)
          ..lineTo(c.dx + w * 0.16, c.dy + w * 0.18)
          ..close();
        canvas.drawPath(tail, fill);
        canvas.drawCircle(c, w / 2 - 3, fill);
        canvas.drawCircle(c, w / 2 - 3, stroke);
    }

    // 符号字
    if (symbol.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: symbol,
          style: TextStyle(
            fontSize: w * 0.42,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_ShapePainter old) =>
      old.type != type || old.symbol != symbol || old.selected != selected;
}

/// 白字黑边文本（地图标注）。
class _OutlinedText extends StatelessWidget {
  final String text;
  final double fontSize;
  const _OutlinedText(this.text, this.fontSize);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Text(text,
            style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.bold,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 2.4
                  ..color = Colors.black)),
        Text(text,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            )),
      ],
    );
  }
}

/// 用户位置箭头（奥维风格：小巧纸飞机形 + 白色描边 + 方向扇面）。
/// 箭头始终跟随手机航向旋转；地图不跟随。
class UserArrowPainter extends CustomPainter {
  final Color color;
  const UserArrowPainter({this.color = const Color(0xFF2196F3)});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;

    // 方向扇面（航向可信域，淡蓝半透明）
    final fan = Path()
      ..moveTo(c.dx, c.dy)
      ..arcTo(Rect.fromCircle(center: c, radius: r * 1.9), _deg(-65),
          _deg(130), false)
      ..close();
    canvas.drawPath(fan, Paint()..color = const Color(0x2A2196F3));

    // 纸飞机箭头：尖端朝上，尾部内凹，圆滑描边
    final p = Path()
      ..moveTo(c.dx, c.dy - r * 0.98)
      ..lineTo(c.dx - r * 0.55, c.dy + r * 0.72)
      ..quadraticBezierTo(
          c.dx, c.dy + r * 0.34, c.dx + r * 0.55, c.dy + r * 0.72)
      ..close();
    canvas.drawPath(
        p,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeJoin = StrokeJoin.round);
    canvas.drawPath(p, Paint()..color = color);
    // 中心高光点
    canvas.drawCircle(Offset(c.dx, c.dy - r * 0.1), r * 0.14,
        Paint()..color = const Color(0xCCFFFFFF));
  }

  double _deg(double d) => d * math.pi / 180;

  @override
  bool shouldRepaint(UserArrowPainter old) => old.color != color;
}

/// 精度圈。
class AccuracyCirclePainter extends CustomPainter {
  const AccuracyCirclePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(size.center(Offset.zero), size.width / 2,
        Paint()..color = const Color(0x1A2196F3));
    canvas.drawCircle(
        size.center(Offset.zero),
        size.width / 2,
        Paint()
          ..color = const Color(0x552196F3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

double deg2rad(double d) => d * math.pi / 180;

/// 段距离文字（屏幕坐标 + 屏幕角度，由叠加层绘制，保证与线平行）
class SegText {
  final Offset center; // 线段中点（屏幕坐标）
  final double angleRad; // 线在屏幕上的方向角（已调整到 ±90° 内）
  final String text;
  const SegText(this.center, this.angleRad, this.text);
}

/// 距离文字叠加层画笔：文字旋转角 = 线方向角，垂直于线上方偏移，
/// 地图缩放/旋转/平移后随帧重算，永远与线平行。
class SegTextPainter extends CustomPainter {
  final List<SegText> items;
  final double offset; // 垂直于线向上的偏移（像素）
  SegTextPainter(this.items, {this.offset = 8});

  @override
  void paint(Canvas canvas, Size size) {
    for (final it in items) {
      final style =
          const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold);
      final tp = TextPainter(
        text: TextSpan(text: it.text, style: style.copyWith(color: Colors.white)),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.save();
      canvas.translate(it.center.dx, it.center.dy);
      canvas.rotate(it.angleRad);
      // 黑描边
      final stroke = TextPainter(
        text: TextSpan(
            text: it.text,
            style: style.copyWith(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 2.6
                  ..color = Colors.black)),
        textDirection: TextDirection.ltr,
      )..layout();
      final at = Offset(-tp.width / 2, -tp.height / 2 - offset);
      stroke.paint(canvas, at);
      tp.paint(canvas, at);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(SegTextPainter old) => true;
}
