import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/map_label.dart';
import '../services/store.dart';
import 'topo.dart';

/// 配线拓扑图 PNG 生成器（对齐设计院配线图样式）：
/// 每个节点一个方框（名称 + 分光比/孔数），连线（光缆段）旁标注光缆规格。
class TopoPngExporter {
  TopoPngExporter._();

  static Future<File> render(
      List<MapLabel> labels, String title, int widthPx) async {
    final roots = Topology.buildTree(labels);
    Topology.assignTitles(roots);

    final d = widthPx / 1400;
    final nodeW = 150 * d;
    final nodeH = 56 * d;
    final hGap = 40 * d;
    final vGap = 120 * d;
    final topPad = 120 * d;
    final sidePad = 40 * d;
    final botPad = 40 * d;

    var cursor = sidePad;
    for (final r in roots) {
      cursor = _layout(r, cursor, 0, nodeW, hGap);
    }
    var maxDepth = 0;
    for (final r in roots) {
      maxDepth = maxDepth > _depth(r) ? maxDepth : _depth(r);
    }
    var w = cursor + sidePad;
    if (w < widthPx) w = widthPx.toDouble();
    final h = topPad + (maxDepth + 1) * (nodeH + vGap) + botPad;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
    canvas.drawRect(
        Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);

    // 标题
    _drawText(canvas, '$title　配线拓扑图', Offset(sidePad, 30 * d),
        fontSize: 26 * d, bold: true);

    for (final r in roots) {
      _drawNode(canvas, r, nodeW, nodeH, topPad, vGap, d);
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(w.ceil(), h.ceil());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData!.buffer.asUint8List();

    final dir = await LabelStore.instance.exportDir();
    final f = File('${dir.path}/${sanitizeName(title)}_配线图.png');
    await robustWriteBytes(f, bytes);
    return f;
  }

  static double _layout(
      TopoNode n, double startX, int depth, double nodeW, double hGap) {
    n.depth = depth;
    if (n.children.isEmpty) {
      n.x = startX;
      return startX + nodeW + hGap;
    }
    var cur = startX;
    for (final c in n.children) {
      cur = _layout(c, cur, depth + 1, nodeW, hGap);
    }
    n.x = (n.children.first.x + n.children.last.x) / 2;
    return cur;
  }

  static int _depth(TopoNode n) {
    var m = 0;
    for (final c in n.children) {
      final dd = 1 + _depth(c);
      if (dd > m) m = dd;
    }
    return m;
  }

  static void _drawNode(Canvas canvas, TopoNode n, double nodeW, double nodeH,
      double topPad, double vGap, double d) {
    n.y = topPad + n.depth * (nodeH + vGap);
    final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(n.x, n.y, nodeW, nodeH), Radius.circular(8 * d));
    canvas.drawRRect(r, Paint()..color = const Color(0xFFF2F2F2));
    canvas.drawRRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * d
          ..color = n.src.type.color);

    final subEmpty = n.sub.isEmpty;
    _drawText(canvas, n.title,
        Offset(n.x + nodeW / 2, n.y + nodeH / 2 - (subEmpty ? 8 * d : 12 * d)),
        fontSize: 15 * d, bold: true, center: true);
    if (!subEmpty) {
      _drawText(canvas, n.sub, Offset(n.x + nodeW / 2, n.y + nodeH / 2 + 10 * d),
          fontSize: 14 * d, color: const Color(0xFFB71C1C), center: true);
    }

    for (final c in n.children) {
      _drawNode(canvas, c, nodeW, nodeH, topPad, vGap, d);
      final x1 = n.x + nodeW / 2, y1 = n.y + nodeH;
      final x2 = c.x + nodeW / 2, y2 = c.y;
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2),
          Paint()
            ..color = const Color(0xFF455A64)
            ..strokeWidth = 2.2 * d);
      if (c.cable.isNotEmpty) {
        final mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
        final tp = _textPainter(c.cable, 13 * d, const Color(0xFF0D47A1));
        tp.layout();
        canvas.drawRect(
            Rect.fromCenter(
                center: Offset(mx, my),
                width: tp.width + 8 * d,
                height: tp.height + 4 * d),
            Paint()..color = Colors.white);
        tp.paint(canvas, Offset(mx - tp.width / 2, my - tp.height / 2));
      }
    }
  }

  static TextPainter _textPainter(
      String text, double fontSize, Color color,
      {bool bold = false}) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    );
  }

  static void _drawText(Canvas canvas, String text, Offset at,
      {required double fontSize,
      Color color = Colors.black,
      bool bold = false,
      bool center = false}) {
    final tp = _textPainter(text, fontSize, color, bold: bold);
    tp.layout();
    final dx = center ? at.dx - tp.width / 2 : at.dx;
    tp.paint(canvas, Offset(dx, at.dy));
  }
}
