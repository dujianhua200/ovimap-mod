import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'design_tokens.dart';

/// 右上角罗盘：显示地图朝向（红针指北）与手机航向（蓝楔）。
/// 点按/长按=回正北朝上（地图不随手机旋转，仅位置箭头跟随航向）。
class CompassWidget extends StatelessWidget {
  /// 地图当前旋转角（度，顺时针）。
  final double mapRotation;

  /// 手机航向（度，顺时针自北）。
  final double heading;
  final bool hasHeading;
  final bool compassMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const CompassWidget({
    super.key,
    required this.mapRotation,
    required this.heading,
    required this.hasHeading,
    required this.compassMode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: const Color(0xB3151A1F),
          shape: BoxShape.circle,
          border: Border.all(
              color: compassMode ? TokC.accent : TokC.divider,
              width: compassMode ? 2 : 1),
        ),
        child: CustomPaint(
          painter: _CompassPainter(
            mapRotation: mapRotation,
            heading: heading,
            hasHeading: hasHeading,
            compassMode: compassMode,
          ),
        ),
      ),
    );
  }
}

class _CompassPainter extends CustomPainter {
  final double mapRotation;
  final double heading;
  final bool hasHeading;
  final bool compassMode;

  _CompassPainter({
    required this.mapRotation,
    required this.heading,
    required this.hasHeading,
    required this.compassMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;

    canvas.save();
    canvas.translate(c.dx, c.dy);
    // 地图旋转的逆 = 真北在屏幕上的方向
    canvas.rotate(-mapRotation * math.pi / 180);

    // 刻度圈
    final tick = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi / 6;
      canvas.drawLine(
          Offset(math.sin(a) * (r - 5), -math.cos(a) * (r - 5)),
          Offset(math.sin(a) * (r - 2), -math.cos(a) * (r - 2)),
          tick);
    }

    // 北针（红）+ 南针（白）
    final north = Path()
      ..moveTo(0, -r + 7)
      ..lineTo(-4.5, 0)
      ..lineTo(4.5, 0)
      ..close();
    canvas.drawPath(north, Paint()..color = const Color(0xFFE53935));
    final south = Path()
      ..moveTo(0, r - 7)
      ..lineTo(-4.5, 0)
      ..lineTo(4.5, 0)
      ..close();
    canvas.drawPath(south, Paint()..color = const Color(0xAAFFFFFF));

    // N 字
    final tp = TextPainter(
      text: const TextSpan(
        text: 'N',
        style: TextStyle(
            fontSize: 8, color: Colors.white, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(-tp.width / 2, -r + 7));

    canvas.restore();

    // 手机航向楔（蓝色三角）：真北在屏幕上位于 -mapRotation，手机航向相对真北为
    // heading，故屏幕角度 = heading - mapRotation（与地图上的定位箭头口径一致）。
    if (hasHeading) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate((heading - mapRotation) * math.pi / 180);
      final wedge = Path()
        ..moveTo(0, -r + 1)
        ..lineTo(-5, -r + 9)
        ..lineTo(5, -r + 9)
        ..close();
      canvas.drawPath(wedge, Paint()..color = TokC.accent);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_CompassPainter old) =>
      old.mapRotation != mapRotation ||
      old.heading != heading ||
      old.hasHeading != hasHeading ||
      old.compassMode != compassMode;
}
