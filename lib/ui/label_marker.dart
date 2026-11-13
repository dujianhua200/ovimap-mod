import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/label_type.dart';
import '../models/map_label.dart';
import 'desktop/symbol_library.dart' show DxfBlockThumb;

/// 鍦板浘鏍囩绗﹀彿锛堟寜鍥句緥褰㈢姸缁樺埗锛夈€?
///
/// 閿氱偣绾﹀畾锛氱鍙峰嚑浣曚腑蹇?= 鍦板浘鐐癸紙杩炵嚎鎺ュ埌绗﹀彿澶栧洿涓績锛夛紱
/// 鍚嶇О鏂囧瓧鎸傚湪绗﹀彿涓嬫柟锛屼笉褰卞搷閿氱偣銆?
/// 杞ㄨ抗/鏃犳爣绛剧被鍨嬩笉鐢荤鍙凤紙鍙敾杩炵嚎+璺濈锛夈€?
class LabelSymbol extends StatelessWidget {
  final MapLabel label;
  final bool selected;
  final double scale;

  /// 鐢ㄦ埛鍙厤鐨勬爣绛鹃鑹诧紙null = 鐢ㄧ被鍨嬭嚜甯﹁壊锛夈€?
  ///
  /// 鐢ㄦ埛鍙ｅ緞锛?鍦板浘鏍囩鐨勯鑹插彲浠ヨ缃?銆傚彧鏈?*绗﹀彿鏈綋**璺熺潃鍙橈紝
  /// 鍚嶇О鏂囧瓧浠嶇敤鐧藉瓧榛戞弿杈?鈥斺€?閭ｆ槸涓轰簡鍦ㄤ换浣曞簳鍥句笂閮借寰楀嚭鏉ャ€?
  final Color? overrideColor;

  const LabelSymbol({
    super.key,
    required this.label,
    this.selected = false,
    this.scale = 1.0,
    this.overrideColor,
  });

  /// 鍦板浘涓婄鍙风殑鍩哄噯杈归暱锛堥€昏緫鍍忕礌锛夈€?
  ///
  /// v3.13 鐢?28 缂╁埌 **18**锛氱敤鎴峰弽棣?鍦板浘鏍囩澶ぇ"銆?
  /// 娉ㄦ剰锛氳繖鍙奖鍝?*灞忓箷娓叉煋**锛涘鍑虹殑 DXF 鍥惧潡灏哄鐢?
  /// `DxfExporter` 鐙珛鎺у埗锛?:1 鎻掑叆锛屼笌鐢ㄦ埛鎻掍欢涓€鑷达級锛屼袱鑰呬簰涓嶅奖鍝嶃€?
  static const double symbolSize = 18;

  @override
  Widget build(BuildContext context) {
    final lt = label.type;

    // 杞ㄨ抗/鏃犳爣绛撅細涓嶇敾绗﹀彿锛屼粎杩炵嚎涓庤窛绂?
    if (lt.id == 'none' || lt.id == 'track') return const SizedBox.shrink();

    // 鍖哄煙椤剁偣锛氬皬鍦嗙偣
    if (lt.id == 'area') {
      return CustomPaint(
        size: Size(8 * scale, 8 * scale),
        painter: _DotPainter(
            color: overrideColor ?? lt.color, selected: selected),
      );
    }

    // 绾枃瀛楁爣娉?
    if (lt.id == 'text') {
      final txt = label.name.trim().isNotEmpty ? label.name.trim() : label.note;
      if (txt.isEmpty) return const SizedBox.shrink();
      return _OutlinedText(txt, 12 * scale);
    }

    final disp = label.name.trim().isNotEmpty
        ? label.name.trim()
        : (lt.symbol.isNotEmpty ? lt.symbol : lt.name);

    // 鍥句緥搴撶鍙凤細鐢?DXF 鐪熷嚑浣曠敾锛堜笌鍑哄浘涓€鑷达級锛屼笉鍐嶇敤褰㈢姸杩戜技銆?
    if (lt.isBlock) {
      return SizedBox(
        width: symbolSize * scale,
        height: symbolSize * scale,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            if (selected)
              Positioned.fill(
                child: Center(
                  child: Container(
                    width: symbolSize * scale * 0.86,
                    height: symbolSize * scale * 0.86,
                    decoration: BoxDecoration(
                      color: const Color(0x33FFD740),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(2),
              child: DxfBlockThumb(
                block: lt.block!,
                // 鐢ㄦ埛鍙厤棰滆壊锛涙湭閰嶇疆鏃剁敤娣辩伆锛堢嚎绋胯鎰燂級銆?
                color: selected
                    ? const Color(0xFF0288D1)
                    : (overrideColor ?? const Color(0xFF263238)),
                strokeWidth: selected ? 1.6 : 1.2,
              ),
            ),
            if (label.name.trim().isNotEmpty)
              Positioned(
                top: symbolSize * scale * 0.78,
                left: -70,
                right: -70,
                child: Center(
                  child: _OutlinedText(label.name.trim(), 8.0 * scale),
                ),
              ),
          ],
        ),
      );
    }

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
              overrideColor: overrideColor,
            ),
          ),
          if (label.name.trim().isNotEmpty)
            Positioned(
              top: symbolSize * scale * 0.62,
              left: -70,
              right: -70,
              child: Center(
                child: _OutlinedText(label.name.trim(), 8.0 * scale),
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
  final Color? overrideColor;

  _ShapePainter(
      {required this.type,
      required this.symbol,
      required this.selected,
      this.overrideColor});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final w = size.width;

    if (selected) {
      canvas.drawCircle(c, w / 2 + 2, Paint()..color = const Color(0xFFFFD740));
    }
    // 娉細杩欓噷鍘熸湰鐢讳簡涓€涓崐閫忔槑榛戣壊**闃村奖鍦?*锛岃瑙変笂鍍忕粰姣忎釜鏍囩濂椾簡涓?
    // 榛戝湀锛堢敤鎴峰弽棣?鏍囩涓嶈杩炵嚎/涓嶈鍦?锛夈€傞槾褰卞湪娣辫壊鍗槦鍥句笂鍙嶈€屾洿绯婏紝
    // 鐜版敼涓轰笉鐢?鈥斺€?绗﹀彿鏈綋 + 鐧借壊鎻忚竟宸茶冻澶熶粠搴曞浘涓婂垎杈ㄣ€?

    final fill = Paint()..color = overrideColor ?? type.color;
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
      default: // pin锛氬渾褰?+ 灏栬
        final tail = Path()
          ..moveTo(c.dx - w * 0.16, c.dy + w * 0.18)
          ..lineTo(c.dx, c.dy + w * 0.46)
          ..lineTo(c.dx + w * 0.16, c.dy + w * 0.18)
          ..close();
        canvas.drawPath(tail, fill);
        canvas.drawCircle(c, w / 2 - 3, fill);
        canvas.drawCircle(c, w / 2 - 3, stroke);
    }

    // 绗﹀彿瀛?
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
      old.type != type ||
      old.symbol != symbol ||
      old.selected != selected ||
      old.overrideColor != overrideColor;
}

/// 鐧藉瓧榛戣竟鏂囨湰锛堝湴鍥炬爣娉級銆?
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

/// 鐢ㄦ埛浣嶇疆绠ご锛堝ゥ缁撮鏍硷細灏忓阀绾搁鏈哄舰 + 鐧借壊鎻忚竟 + 鏂瑰悜鎵囬潰锛夈€?
/// 绠ご濮嬬粓璺熼殢鎵嬫満鑸悜鏃嬭浆锛涘湴鍥句笉璺熼殢銆?
class UserArrowPainter extends CustomPainter {
  final Color color;
  const UserArrowPainter({this.color = const Color(0xFF2196F3)});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;

    // 鏂瑰悜鎵囬潰锛堣埅鍚戝彲淇″煙锛屾贰钃濆崐閫忔槑锛?
    final fan = Path()
      ..moveTo(c.dx, c.dy)
      ..arcTo(Rect.fromCircle(center: c, radius: r * 1.9), _deg(-65),
          _deg(130), false)
      ..close();
    canvas.drawPath(fan, Paint()..color = const Color(0x2A2196F3));

    // 绾搁鏈虹澶达細灏栫鏈濅笂锛屽熬閮ㄥ唴鍑癸紝鍦嗘粦鎻忚竟
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
    // 涓績楂樺厜鐐?
    canvas.drawCircle(Offset(c.dx, c.dy - r * 0.1), r * 0.14,
        Paint()..color = const Color(0xCCFFFFFF));
  }

  double _deg(double d) => d * math.pi / 180;

  @override
  bool shouldRepaint(UserArrowPainter old) => old.color != color;
}

/// 绮惧害鍦堛€?
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

/// 娈佃窛绂绘枃瀛楋紙灞忓箷鍧愭爣 + 灞忓箷瑙掑害锛岀敱鍙犲姞灞傜粯鍒讹紝淇濊瘉涓庣嚎骞宠锛?
class SegText {
  final Offset center; // 绾挎涓偣锛堝睆骞曞潗鏍囷級
  final double angleRad; // 绾垮湪灞忓箷涓婄殑鏂瑰悜瑙掞紙宸茶皟鏁村埌 卤90掳 鍐咃級
  final String text;
  const SegText(this.center, this.angleRad, this.text);
}

/// 璺濈鏂囧瓧鍙犲姞灞傜敾绗旓細鏂囧瓧鏃嬭浆瑙?= 绾挎柟鍚戣锛屽瀭鐩翠簬绾夸笂鏂瑰亸绉伙紝
/// 鍦板浘缂╂斁/鏃嬭浆/骞崇Щ鍚庨殢甯ч噸绠楋紝姘歌繙涓庣嚎骞宠銆?
class SegTextPainter extends CustomPainter {
  final List<SegText> items;
  final double offset; // 鍨傜洿浜庣嚎鍚戜笂鐨勫亸绉伙紙鍍忕礌锛?
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
      // 榛戞弿杈?
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
