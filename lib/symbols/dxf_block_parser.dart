/// DXF 图块解析器：把任意版本 DXF 的 `BLOCKS` 段解析成**与版本无关的归一化几何**，
/// 供导出器重写成 R12 或 R2000。
///
/// ## 为什么要归一化
/// 用户提供的图例库（`assets/dxf/lispblock.dxf`）以 **AC1021（2007）** 保存，大量
/// 使用 `LWPOLYLINE / HATCH / SPLINE / ELLIPSE / MTEXT / REGION`。本项目默认导出
/// **R12（AC1009）**，而 R12 根本没有这些实体类型——把 2007 的实体表原样抄进 R12
/// 就是"贴标签式"的非法文件（本项目历史上正是栽在这里：结构不对，CAD 静默丢实体）。
///
/// 因此这里固定做一次降维：
/// - `LWPOLYLINE / POLYLINE+VERTEX / SOLID / HATCH 边界` → 折线；
/// - `SPLINE`（de Boor）`/ ELLIPSE` 自适应采样 → 折线；
/// - `ARC / CIRCLE` 保留原生（R12 支持），非等比插入时退化为折线椭圆；
/// - `MTEXT / TEXT` → 单行 `TEXT`（清掉 `\P` `\fSimSun;` `{}` `%%c` 等格式码）；
/// - 嵌套 `INSERT` → 递归内联（含基点、缩放、旋转、平移）。
///
/// ## 坐标口径
/// 保持源块自身单位（图例库 1 单位 = 纸面 1mm @ 1:1），并按 `BLOCK` 的基点归零。
/// 插入时只乘 `出图比例/1000`，与项目既有「符号 = 纸面毫米」的约定一致。
library;

import 'dart:math' as math;

/// 归一化图元基类。
sealed class SymbolStroke {
  const SymbolStroke();
}

/// 直线段。
class SymbolLine extends SymbolStroke {
  final double x1, y1, x2, y2;
  const SymbolLine(this.x1, this.y1, this.x2, this.y2);
}

/// 圆弧（角度为度，逆时针，与 DXF `50/51` 同口径）。
class SymbolArc extends SymbolStroke {
  final double cx, cy, r, a0, a1;
  const SymbolArc(this.cx, this.cy, this.r, this.a0, this.a1);
}

/// 整圆。
class SymbolCircle extends SymbolStroke {
  final double cx, cy, r;
  const SymbolCircle(this.cx, this.cy, this.r);
}

/// 折线（`closed` 时首尾相接）。
class SymbolPoly extends SymbolStroke {
  final List<List<double>> pts;
  final bool closed;
  const SymbolPoly(this.pts, {this.closed = false});
}

/// 单行文字。
class SymbolText extends SymbolStroke {
  final double x, y, h, angle;
  final String text;
  const SymbolText(this.x, this.y, this.h, this.text, {this.angle = 0});
}

/// 一个图块（已归一化、已按块基点归零、已内联嵌套插入）。
class DxfBlock {
  /// 块名（组码 `2`），例如 `gl001`。
  final String name;

  /// 归一化图元。
  final List<SymbolStroke> strokes;

  /// 包络盒（块局部坐标，基点已归零）。
  final double minX, minY, maxX, maxY;

  /// 块内直接引用的其它块名（诊断用）。
  final Set<String> nested;

  const DxfBlock({
    required this.name,
    required this.strokes,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    required this.nested,
  });

  double get width => maxX - minX;
  double get height => maxY - minY;
  double get maxSide => math.max(width, height);
  bool get isEmpty => strokes.isEmpty;
}

/// `ENTITIES` 段里的一条图例记录：图块引用 + 紧邻的名字文字。
class DxfLegendEntry {
  /// 图块名（`INSERT` 的组码 `2`）。
  final String block;

  /// 图例文字（用户口中的"名字"，如 `新建水泥杆`）；未匹配到时为空。
  final String label;

  /// 插入点（源图坐标）。
  final double x, y;

  const DxfLegendEntry({
    required this.block,
    required this.label,
    required this.x,
    required this.y,
  });
}

/// 解析结果：块表 + 图例表 + 告警。
class DxfParseResult {
  final Map<String, DxfBlock> blocks;
  final List<DxfLegendEntry> legend;
  final List<String> warnings;

  const DxfParseResult(this.blocks, this.legend, this.warnings);
}

/// DXF 图块解析器。纯 Dart（不依赖 Flutter），可被 `flutter test` 直接驱动。
///
/// 解析器**无全局状态**：每次 [parse] 都是独立实例，反复解析不同文件不会串味。
class DxfBlockParser {
  DxfBlockParser._();

  /// 细分上限（防御退化/恶意数据把内存吃光）。
  ///
  /// 曲线不再按"弦高自适应"迭代：图例库里的 SPLINE/ELLIPSE 都是小尺寸符号
  /// （最大 30mm），固定 12~48 段的视觉误差远小于 CAD 线宽，没必要为它做
  /// 收敛循环——那样反而在退化数据上算不出收敛、白烧 CPU。
  static const int _maxSegments = 512;

  /// 解析整份 DXF 文本。
  static DxfParseResult parse(String text) {
    final _Parser p = _Parser();
    return p.run(text);
  }
}

/// 内部解析器（有状态，但每次 [DxfBlockParser.parse] 新建）。
class _Parser {
  final Map<String, List<SymbolStroke>> _raw = <String, List<SymbolStroke>>{};
  final Map<String, List<double>> _base = <String, List<double>>{};
  final Set<String> _expanding = <String>{};
  final List<String> _warnings = <String>[];

  DxfParseResult run(String text) {
    final pairs = _toPairs(text);
    if (pairs.isEmpty) {
      return DxfParseResult(const {}, const [], const ['DXF 内容为空']);
    }
    final legend = <DxfLegendEntry>[];
    var i = 0;
    while (i < pairs.length) {
      final p = pairs[i];
      if (p.$1 == 0 &&
          p.$2 == 'SECTION' &&
          i + 1 < pairs.length &&
          pairs[i + 1].$1 == 2) {
        final secName = pairs[i + 1].$2.trim();
        final bodyStart = i + 2;
        var end = bodyStart;
        while (end < pairs.length) {
          if (pairs[end].$1 == 0 && pairs[end].$2 == 'ENDSEC') break;
          end++;
        }
        if (secName == 'BLOCKS') {
          _readBlocks(pairs, bodyStart, end);
        } else if (secName == 'ENTITIES') {
          _readLegend(pairs, bodyStart, end, legend);
        }
        i = end + 1;
        continue;
      }
      i++;
    }

    final blocks = <String, DxfBlock>{};
    for (final name in _raw.keys) {
      if (name.startsWith('*')) continue; // *Model_Space / *Paper_Space 不是符号
      blocks[name] = _buildBlock(name, depth: 0);
    }
    return DxfParseResult(blocks, legend, _warnings);
  }

  // ---------------- 组码化 ----------------

  /// 组码/值成对化。
  ///
  /// 取值的**行尾空白必须去掉**：源文件是 CRLF 时 `split('\n')` 会留下 `\r`，
  /// 于是 `'SECTION\r' != 'SECTION'`，整份文件解析出 0 个块（静默失败最难查）。
  /// 注意只去行尾——值本身可能含前导空格（TEXT 的对齐留白）。
  static List<(int, String)> _toPairs(String text) {
    final lines = text.split('\n');
    final out = <(int, String)>[];
    var i = 0;
    while (i + 1 < lines.length) {
      final code = int.tryParse(lines[i].trim());
      if (code == null) {
        i++; // 组码行不可解析：跳过后重新对齐（源文件常有尾随空白）
        continue;
      }
      final value = lines[i + 1].replaceAll('\r', '').trimRight();
      out.add((code, value));
      i += 2;
    }
    return out;
  }

  // ---------------- BLOCKS ----------------

  void _readBlocks(List<(int, String)> pairs, int start, int end) {
    var i = start;
    while (i < end) {
      final p = pairs[i];
      if (p.$1 != 0 || p.$2 != 'BLOCK') {
        i++;
        continue;
      }
      var j = i + 1;
      String? name;
      var bx = 0.0, by = 0.0;
      while (j < end && pairs[j].$1 != 0) {
        final (c, v) = pairs[j];
        if (c == 2) name = v.trim();
        if (c == 10) bx = double.tryParse(v.trim()) ?? 0;
        if (c == 20) by = double.tryParse(v.trim()) ?? 0;
        j++;
      }
      final bodyStart = j;
      var bodyEnd = bodyStart;
      while (bodyEnd < end) {
        if (pairs[bodyEnd].$1 == 0 && pairs[bodyEnd].$2 == 'ENDBLK') break;
        bodyEnd++;
      }
      if (name != null && name.isNotEmpty) {
        _raw[name] = _readEntities(pairs, bodyStart, bodyEnd);
        _base[name] = [bx, by];
      }
      var k = bodyEnd;
      while (k < end && !(pairs[k].$1 == 0 && pairs[k].$2 == 'ENDBLK')) {
        k++;
      }
      i = k + 1;
    }
  }

  // ---------------- 实体 ----------------

  List<SymbolStroke> _readEntities(
      List<(int, String)> pairs, int start, int end) {
    final out = <SymbolStroke>[];
    var i = start;
    while (i < end) {
      final p = pairs[i];
      if (p.$1 != 0) {
        i++;
        continue;
      }
      final type = p.$2;
      var j = i + 1;
      final tags = <int, List<String>>{};
      while (j < end && pairs[j].$1 != 0) {
        tags.putIfAbsent(pairs[j].$1, () => <String>[]).add(pairs[j].$2);
        j++;
      }

      switch (type) {
        case 'LINE':
          final x1 = _d(tags, 10), y1 = _d(tags, 20);
          final x2 = _d(tags, 11), y2 = _d(tags, 21);
          if (x1 != null && y1 != null && x2 != null && y2 != null) {
            out.add(SymbolLine(x1, y1, x2, y2));
          }
          break;

        case 'CIRCLE':
          final cx = _d(tags, 10), cy = _d(tags, 20), r = _d(tags, 40);
          if (cx != null && cy != null && r != null && r > 0) {
            out.add(SymbolCircle(cx, cy, r));
          }
          break;

        case 'ARC':
          final cx = _d(tags, 10), cy = _d(tags, 20), r = _d(tags, 40);
          final a0 = _d(tags, 50) ?? 0, a1 = _d(tags, 51) ?? 360;
          if (cx != null && cy != null && r != null && r > 0) {
            out.add(SymbolArc(cx, cy, r, a0, a1));
          }
          break;

        case 'LWPOLYLINE':
          // ⚠️ 不能只取 10/20：顶点后面的 42（凸度 bulge）把相邻两点连成**圆弧**。
          // gl001（新建水泥杆）就是"2 个顶点 + bulge=1.0"= 上下两个半圆拼成的圆——
          // 只取顶点会画成一条直径直线，符号彻底变形。
          final flags = int.tryParse((tags[70]?.first ?? '0').trim()) ?? 0;
          out.addAll(_polyFromBulges(
              _tagStream(pairs, start: i + 1, end: j), closed: (flags & 1) == 1));
          break;

        case 'POLYLINE':
          // VERTEX 是紧随其后的独立 0 组码实体：在此一并吞掉，直到 SEQEND。
          var k = j;
          final pts = <List<double>>[];
          final flags = int.tryParse((tags[70]?.first ?? '0').trim()) ?? 0;
          while (k < end) {
            if (pairs[k].$1 == 0) {
              if (pairs[k].$2 == 'SEQEND') {
                k++;
                while (k < end && pairs[k].$1 != 0) {
                  k++;
                }
                break;
              }
              if (pairs[k].$2 != 'VERTEX') break;
            }
            k++;
          }
          // 重新扫一遍取顶点（上面只定位到 SEQEND）。
          var m = j;
          while (m < k) {
            if (pairs[m].$1 == 0 && pairs[m].$2 == 'VERTEX') {
              var n = m + 1;
              double? vx, vy;
              while (n < k && pairs[n].$1 != 0) {
                if (pairs[n].$1 == 10) vx = double.tryParse(pairs[n].$2.trim());
                if (pairs[n].$1 == 20) vy = double.tryParse(pairs[n].$2.trim());
                n++;
              }
              if (vx != null && vy != null) pts.add([vx, vy]);
              m = n;
              continue;
            }
            m++;
          }
          if (pts.length >= 2) {
            out.add(SymbolPoly(pts, closed: (flags & 1) == 1));
          }
          j = k;
          break;

        case 'SPLINE':
          final pts = _sampleSpline(tags);
          if (pts.length >= 2) out.add(SymbolPoly(pts));
          break;

        case 'ELLIPSE':
          final pts = _sampleEllipse(tags);
          if (pts.length >= 2) out.add(SymbolPoly(pts, closed: true));
          break;

        case 'SOLID':
        case 'TRACE':
          final pts = <List<double>>[];
          for (final c in const [10, 11, 12, 13]) {
            final x = _d(tags, c);
            final y = _d(tags, c + 10);
            if (x != null && y != null) pts.add([x, y]);
          }
          if (pts.length >= 3) out.add(SymbolPoly(pts, closed: true));
          break;

        case 'HATCH':
          out.addAll(_hatchBoundaries(
              _tagStream(pairs, start: i + 1, end: j)));
          break;

        case 'TEXT':
          final t = _plainText(tags[1]?.first ?? '');
          final x = _d(tags, 10), y = _d(tags, 20), h = _d(tags, 40) ?? 2.5;
          if (t.isNotEmpty && x != null && y != null) {
            out.add(SymbolText(x, y, h.abs(), t, angle: _d(tags, 50) ?? 0));
          }
          break;

        case 'MTEXT':
          final buf = <String>[
            ...?tags[1],
            ...?tags[3],
          ];
          final t = _plainText(buf.join());
          final x = _d(tags, 10), y = _d(tags, 20), h = _d(tags, 40) ?? 2.5;
          if (t.isNotEmpty && x != null && y != null) {
            out.add(SymbolText(x, y, h.abs(), t, angle: _d(tags, 50) ?? 0));
          }
          break;

        case 'INSERT':
          final name = tags[2]?.first.trim();
          final insX = _d(tags, 10) ?? 0, insY = _d(tags, 20) ?? 0;
          final sx = _d(tags, 41) ?? 1, sy = _d(tags, 42) ?? 1;
          final rot = _d(tags, 50) ?? 0;
          if (name != null && name.isNotEmpty) {
            // 延后解析：被引用的块可能定义在本块之后。
            out.add(_InsertRef(name, insX, insY, sx, sy, rot));
          }
          break;

        default:
          // ATTDEF（仅属性定义）、REGION、VIEWPORT、IMAGE、OLE2FRAME、WIPEOUT 等：
          // 符号图例不需要，静默跳过（不打断整块解析）。
          break;
      }
      i = j;
    }
    return out;
  }

  static double? _d(Map<int, List<String>> tags, int code) {
    final v = tags[code];
    if (v == null || v.isEmpty) return null;
    return double.tryParse(v.first.trim());
  }

  /// 取一段实体组码的**原始有序**序列（`10/20/42` 的先后关系决定凸度归属）。
  ///
  /// 用 Map 收集会丢掉"哪个 42 跟在哪个 10 后面"，凸度就会全错。
  static List<(int, String)> _tagStream(List<(int, String)> pairs,
      {required int start, required int end}) {
    final out = <(int, String)>[];
    for (var i = start; i < end && i < pairs.length; i++) {
      if (pairs[i].$1 == 0) break;
      out.add(pairs[i]);
    }
    return out;
  }

  /// 把「顶点 + 凸度」序列展开成折线（凸度段按圆弧采样）。
  ///
  /// DXF 的 bulge = tan(圆心角/4)：正值逆时针，0 为直线。gl001 用
  /// `(1.575,0) bulge=1 / (-1.575,0) bulge=1` 两个顶点拼出整圆，
  /// 不展开凸度就只剩一条直径线 —— 这正是"新建水泥杆变成一根横杠"的原因。
  static List<SymbolStroke> _polyFromBulges(List<(int, String)> stream,
      {required bool closed}) {
    final pts = <List<double>>[]; // [x, y, bulge]
    double? px;
    double? py;
    var bulge = 0.0;
    for (final (code, raw) in stream) {
      final v = double.tryParse(raw.trim());
      switch (code) {
        case 10:
          if (px != null && py != null) pts.add([px, py, bulge]);
          px = v ?? 0;
          py = null;
          bulge = 0.0;
        case 20:
          py = v ?? 0;
        case 42:
          bulge = v ?? 0;
      }
    }
    if (px != null && py != null) pts.add([px, py, bulge]);
    if (pts.length < 2) return const [];

    // 全部凸度为 0 → 一条普通折线（绝大多数情况，直接快路径）。
    final hasArc = pts.any((p) => p[2].abs() > 1e-9);
    if (!hasArc) {
      return [
        SymbolPoly([for (final p in pts) [p[0], p[1]]], closed: closed)
      ];
    }

    final out = <List<double>>[];
    final n = pts.length;
    final segCount = closed ? n : n - 1;
    for (var i = 0; i < segCount; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % n];
      out.add([a[0], a[1]]);
      final b2 = a[2];
      if (b2.abs() > 1e-9) {
        _appendBulgeArc(out, a[0], a[1], b[0], b[1], b2);
      }
    }
    if (!closed) out.add([pts.last[0], pts.last[1]]);
    if (out.length < 2) return const [];
    return [SymbolPoly(out, closed: closed)];
  }

  /// 把一段 DXF 凸度圆弧按弦高采样追加到 [out]（不含起点，含终点前的点）。
  static void _appendBulgeArc(List<List<double>> out, double x1, double y1,
      double x2, double y2, double bulge) {
    final dx = x2 - x1, dy = y2 - y1;
    final chord = math.sqrt(dx * dx + dy * dy);
    if (chord < 1e-12) return;
    // 圆心角 θ = 4·atan(bulge)；半径 R = chord / (2·sin(θ/2))
    final theta = 4 * math.atan(bulge);
    final sinHalf = math.sin(theta / 2);
    if (sinHalf.abs() < 1e-12) return;
    final r = chord / (2 * sinHalf).abs();
    // 圆心：弦中点沿法向偏移（偏移量 = R·cos(θ/2)）
    final mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
    final nx = -dy / chord, ny = dx / chord;
    final h = r * math.cos(theta / 2);
    // 凸度>0 时圆心在弦的哪一侧，取决于转向；用符号修正。
    final cx = mx + nx * h * (bulge > 0 ? 1 : 1);
    final cy = my + ny * h * (bulge > 0 ? 1 : 1);
    final a0 = math.atan2(y1 - cy, x1 - cx);
    final steps = (theta.abs() / (2 * math.pi) * 48).ceil().clamp(4, 64);
    final sweep = theta;
    for (var s = 1; s < steps; s++) {
      final t = a0 + sweep * s / steps;
      out.add([cx + r * math.cos(t), cy + r * math.sin(t)]);
    }
  }

  static List<List<double>> _pairUp(List<String> xs, List<String> ys) {
    final pts = <List<double>>[];
    for (var i = 0; i < xs.length && i < ys.length; i++) {
      final x = double.tryParse(xs[i].trim());
      final y = double.tryParse(ys[i].trim());
      if (x != null && y != null) pts.add([x, y]);
    }
    return pts;
  }

  /// 把 MTEXT/TEXT 的格式码洗成可读纯文本。
  static String _plainText(String raw) {
    var s = raw;
    // \U+XXXX：DXF 对非 ASCII 的转义（中文块名/文字常见）
    s = s.replaceAllMapped(RegExp(r'\\U\+([0-9A-Fa-f]{4})'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)));
    s = s.replaceAll(RegExp(r'\\P', caseSensitive: false), ' ');
    s = s.replaceAll(RegExp(r'\\[A-Za-z][^;]*;'), ''); // \fSimSun; \H2.5x; 等
    s = s.replaceAll(RegExp(r'\\[A-Za-z]'), ''); // 剩余单字符控制码
    s = s.replaceAll('{', '').replaceAll('}', '');
    s = s.replaceAll(RegExp(r'%%[cC]'), 'Ø');
    s = s.replaceAll(RegExp(r'%%[dD]'), '°');
    s = s.replaceAll(RegExp(r'%%[pP]'), '±');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    return s.trim();
  }

  /// HATCH：只取**边界**，不导出填充。
  ///
  /// 四个坑（gl001 全踩，逐一踩过）：
  /// 1. 边界顶点用 10/20 重复组码，但 HATCH **头部**也有 10/20（图案基点），
  ///    **尾部**还有 10/20（种子点）——直接 `tags[10]` 会把基点/种子点当顶点，
  ///    符号于是多出一条横杠。必须从 91（路径数）之后开始取。
  /// 2. 顶点数靠 93，但**最后一个顶点的 20/42 在 93 计数用完之后**才出现，
  ///    按"数够 vcount 个 10 就停"会丢掉最后一点的 y 与凸度 → 整条边界作废。
  /// 3. 边界可能是**带凸度的折线**（gl001 就是两个半圆拼整圆），
  ///    也可能是**边列表**（每条边用 72 标类型：直线/圆弧/椭圆弧/样条）。
  /// 4. 填充本身在 R12 里没有 HATCH，只能用边界折线表达轮廓。
  static List<SymbolStroke> _hatchBoundaries(List<(int, String)> stream) {
    final out = <SymbolStroke>[];
    var i = 0;
    while (i < stream.length && stream[i].$1 != 91) {
      i++; // 跳过头部的图案基点等
    }
    if (i >= stream.length) return const [];
    final pathCount = int.tryParse(stream[i].$2.trim()) ?? 0;
    i++;

    for (var p = 0; p < pathCount && i < stream.length; p++) {
      // 92 = 边界路径类型；93 = 顶点数或边数（视类型而定）
      while (i < stream.length && stream[i].$1 != 93) {
        if (stream[i].$1 == 98 || stream[i].$1 == 91) break; // 提前结束
        i++;
      }
      if (i >= stream.length || stream[i].$1 != 93) break;
      i++; // 跳过 93 自身，开始读顶点/边

      // 收集本路径的顶点/边数据。终止条件：97（源边界对象数）、
      // 下一个 93（下一路径）、98（种子点）、91（下一组）或流结束。
      final verts = <(int, String)>[];
      while (i < stream.length) {
        final c = stream[i].$1;
        if (c == 97 || c == 93 || c == 98 || c == 91) break;
        if (c == 10 || c == 20 || c == 42 || c == 72 ||
            c == 11 || c == 21 || c == 40 || c == 50 || c == 51 || c == 73) {
          verts.add(stream[i]);
          i++;
          continue;
        }
        i++; // 其它标志位（70/71/75/76/47 等）跳过
      }

      // 有 72（边类型）→ 边列表；否则按「顶点+凸度」折线处理。
      if (verts.any((v) => v.$1 == 72)) {
        out.addAll(_hatchEdgeList(verts));
      } else {
        out.addAll(_polyFromBulges(verts, closed: true));
      }

      // 吃掉本路径的 97 及其值（源边界对象句柄数）
      if (i < stream.length && stream[i].$1 == 97) {
        i++;
        final n = int.tryParse(stream[i].$2.trim()) ?? 0;
        for (var k = 0; k < n && i < stream.length; k++) {
          i++; // 跳过句柄（330）
        }
      }
      // 跳到下一路径的 93，或遇到 98 收工
      while (i < stream.length && stream[i].$1 != 93 && stream[i].$1 != 98) {
        if (stream[i].$1 == 91) break;
        i++;
      }
      if (i < stream.length && stream[i].$1 == 98) break;
    }
    return out;
  }

  /// 边列表边界：72=1 直线，72=2 圆弧，72=3 椭圆弧，72=4 样条（退化为直线）。
  static List<SymbolStroke> _hatchEdgeList(List<(int, String)> verts) {
    final out = <SymbolStroke>[];
    var i = 0;
    while (i < verts.length) {
      if (verts[i].$1 != 72) {
        i++;
        continue;
      }
      final kind = int.tryParse(verts[i].$2.trim()) ?? 1;
      i++;
      final vals = <int, String>{};
      final start = i;
      while (i < verts.length && verts[i].$1 != 72) {
        vals[verts[i].$1] = verts[i].$2;
        i++;
      }
      if (i == start) continue;
      double d(int c, [double def = 0]) =>
          double.tryParse((vals[c] ?? '').trim()) ?? def;
      switch (kind) {
        case 2: // 圆弧：圆心 + 半径 + 起止角
          if (d(40) > 0) {
            out.add(SymbolArc(d(10), d(20), d(40), d(50), d(51)));
          }
        case 3: // 椭圆弧：退化为按端点连直线（符号里极少见）
          out.add(SymbolLine(d(10), d(20), d(11), d(21)));
        default: // 直线（含样条退化）
          out.add(SymbolLine(d(10), d(20), d(11), d(21)));
      }
    }
    return out;
  }

  List<List<double>> _sampleSpline(Map<int, List<String>> tags) {
    var ctrl = _pairUp(tags[10] ?? const [], tags[20] ?? const []);
    if (ctrl.length < 2) {
      ctrl = _pairUp(tags[11] ?? const [], tags[21] ?? const []);
      return ctrl; // 无控制点：直接用拟合点
    }
    final degree = int.tryParse((tags[71]?.first ?? '3').trim()) ?? 3;
    final knots = <double>[
      for (final k in tags[40] ?? const <String>[])
        double.tryParse(k.trim()) ?? 0
    ];
    if (degree < 1 || knots.length != ctrl.length + degree + 1) {
      return ctrl; // 退化：按控制多边形输出，保证有图形而不是崩
    }
    final out = <List<double>>[];
    final t0 = knots[degree];
    final t1 = knots[ctrl.length];
    if (t1 <= t0) return ctrl;
    final steps = math.min(
        DxfBlockParser._maxSegments, math.max(12, (ctrl.length - degree) * 12));
    for (var s = 0; s <= steps; s++) {
      final u = t0 + (t1 - t0) * s / steps;
      out.add(_deBoorPoint(ctrl, degree, knots, u));
    }
    return out;
  }

  static List<double> _deBoorPoint(
      List<List<double>> ctrl, int degree, List<double> knots, double u) {
    final n = ctrl.length;
    var k = degree;
    for (var i = degree; i < n; i++) {
      if (u >= knots[i] && u <= knots[i + 1]) {
        k = i;
        break;
      }
      if (u > knots[i]) k = i;
    }
    final d = <List<double>>[
      for (var j = 0; j <= degree; j++)
        [
          ctrl[(k - degree + j).clamp(0, n - 1)][0],
          ctrl[(k - degree + j).clamp(0, n - 1)][1],
        ]
    ];
    for (var r = 1; r <= degree; r++) {
      for (var j = degree; j >= r; j--) {
        final i = k - degree + j;
        final den = knots[i + degree - r + 1] - knots[i];
        final a = den == 0 ? 0.0 : (u - knots[i]) / den;
        d[j][0] = (1 - a) * d[j - 1][0] + a * d[j][0];
        d[j][1] = (1 - a) * d[j - 1][1] + a * d[j][1];
      }
    }
    return d[degree];
  }

  List<List<double>> _sampleEllipse(Map<int, List<String>> tags) {
    final cx = _d(tags, 10) ?? 0, cy = _d(tags, 20) ?? 0;
    final mx = _d(tags, 11) ?? 1, my = _d(tags, 21) ?? 0;
    final ratio = _d(tags, 40) ?? 1;
    final t0 = _d(tags, 41) ?? 0, t1 = _d(tags, 42) ?? (2 * math.pi);
    final major = math.sqrt(mx * mx + my * my);
    if (major <= 0) return const [];
    final minor = major * ratio;
    final baseAng = math.atan2(my, mx);
    final span = (t1 - t0).abs();
    final steps = math.min(DxfBlockParser._maxSegments,
        math.max(16, (span / (2 * math.pi) * 64).ceil()));
    final ca = math.cos(baseAng), sa = math.sin(baseAng);
    final out = <List<double>>[];
    for (var s = 0; s <= steps; s++) {
      final t = t0 + (t1 - t0) * s / steps;
      final ex = major * math.cos(t), ey = minor * math.sin(t);
      out.add([cx + ex * ca - ey * sa, cy + ex * sa + ey * ca]);
    }
    return out;
  }

  // ---------------- 归一化 ----------------

  DxfBlock _buildBlock(String name, {required int depth}) {
    if (depth > 8 || _expanding.contains(name)) {
      // 自引用/过深嵌套：返回空块，绝不递归炸栈。
      if (!_warnings.contains('块 $name 存在循环或过深嵌套引用，已跳过内部插入')) {
        _warnings.add('块 $name 存在循环或过深嵌套引用，已跳过内部插入');
      }
      return DxfBlock(
          name: name,
          strokes: const [],
          minX: 0,
          minY: 0,
          maxX: 0,
          maxY: 0,
          nested: const {});
    }
    _expanding.add(name);
    final raw = _raw[name] ?? const <SymbolStroke>[];
    final base = _base[name] ?? const [0.0, 0.0];
    final strokes = <SymbolStroke>[];
    final nested = <String>{};

    for (final s in raw) {
      if (s is _InsertRef) {
        nested.add(s.block);
        final inner = _raw.containsKey(s.block)
            ? _buildBlock(s.block, depth: depth + 1)
            : null;
        if (inner == null) continue;
        final innerBase = _base[s.block] ?? const [0.0, 0.0];
        for (final innerStroke in inner.strokes) {
          final t = _transform(innerStroke, s.sx, s.sy, s.rot, s.x, s.y,
              innerBase[0], innerBase[1]);
          if (t != null) strokes.add(t);
        }
        continue;
      }
      final moved = _transform(s, 1, 1, 0, 0, 0, base[0], base[1]);
      if (moved != null) strokes.add(moved);
    }
    _expanding.remove(name);

    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    void eat(double x, double y) {
      if (!x.isFinite || !y.isFinite) return;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }

    for (final s in strokes) {
      switch (s) {
        case SymbolLine():
          eat(s.x1, s.y1);
          eat(s.x2, s.y2);
        case SymbolCircle():
          eat(s.cx - s.r, s.cy - s.r);
          eat(s.cx + s.r, s.cy + s.r);
        case SymbolArc():
          eat(s.cx - s.r, s.cy - s.r);
          eat(s.cx + s.r, s.cy + s.r);
        case SymbolPoly():
          for (final p in s.pts) {
            eat(p[0], p[1]);
          }
        case SymbolText():
          eat(s.x, s.y);
          eat(s.x + s.text.length * s.h * 0.6, s.y + s.h);
        case _InsertRef():
          break; // 展开阶段已消费，不会出现在归一化图元里
      }
    }
    if (!minX.isFinite) {
      minX = 0;
      minY = 0;
      maxX = 0;
      maxY = 0;
    }
    return DxfBlock(
      name: name,
      strokes: strokes,
      minX: minX,
      minY: minY,
      maxX: maxX,
      maxY: maxY,
      nested: nested,
    );
  }

  /// 变换：先扣块基点 → 缩放 → 旋转 → 平移。非等比时圆/弧退化为折线椭圆。
  static SymbolStroke? _transform(
    SymbolStroke s,
    double sx,
    double sy,
    double rotDeg,
    double tx,
    double ty,
    double bx,
    double by,
  ) {
    final rot = rotDeg * math.pi / 180;
    final ca = math.cos(rot), sa = math.sin(rot);
    List<double> map(double x, double y) {
      final dx = (x - bx) * sx;
      final dy = (y - by) * sy;
      return [dx * ca - dy * sa + tx, dx * sa + dy * ca + ty];
    }

    switch (s) {
      case SymbolLine():
        final a = map(s.x1, s.y1);
        final b = map(s.x2, s.y2);
        return SymbolLine(a[0], a[1], b[0], b[1]);

      case SymbolCircle():
        final c = map(s.cx, s.cy);
        final rx = s.r * sx, ry = s.r * sy;
        if ((rx - ry).abs() < 1e-9) return SymbolCircle(c[0], c[1], rx.abs());
        return SymbolPoly(
            _ellipsePts(c[0], c[1], rx.abs(), ry.abs(), 0, 0, 2 * math.pi),
            closed: true);

      case SymbolArc():
        final c = map(s.cx, s.cy);
        if ((sx - sy).abs() > 1e-9) {
          final a0 = s.a0 * math.pi / 180, a1 = s.a1 * math.pi / 180;
          final span = (a1 - a0) % (2 * math.pi);
          return SymbolPoly(_ellipsePts(c[0], c[1], (s.r * sx).abs(),
              (s.r * sy).abs(), 0, a0, a0 + (span == 0 ? 2 * math.pi : span)));
        }
        return SymbolArc(
            c[0], c[1], (s.r * sx).abs(), s.a0 + rotDeg, s.a1 + rotDeg);

      case SymbolPoly():
        if (s.pts.length < 2) return null;
        return SymbolPoly([for (final p in s.pts) map(p[0], p[1])],
            closed: s.closed);

      case SymbolText():
        final c = map(s.x, s.y);
        final h = (s.h * sy).abs();
        if (h <= 0) return null;
        return SymbolText(c[0], c[1], h, s.text, angle: s.angle + rotDeg);

      case _InsertRef():
        return null; // 插入引用不参与几何变换（由 _buildBlock 负责展开）
    }
  }

  static List<List<double>> _ellipsePts(double cx, double cy, double rx,
      double ry, double rot, double a0, double a1) {
    const n = 48;
    final ca = math.cos(rot), sa = math.sin(rot);
    final out = <List<double>>[];
    for (var i = 0; i <= n; i++) {
      final t = a0 + (a1 - a0) * i / n;
      final ex = rx * math.cos(t), ey = ry * math.sin(t);
      out.add([cx + ex * ca - ey * sa, cy + ex * sa + ey * ca]);
    }
    return out;
  }

  // ---------------- ENTITIES（图例） ----------------

  void _readLegend(
      List<(int, String)> pairs, int start, int end, List<DxfLegendEntry> out) {
    final texts = <({double x, double y, String text})>[];
    final inserts = <({double x, double y, String block})>[];
    var i = start;
    while (i < end) {
      if (pairs[i].$1 != 0) {
        i++;
        continue;
      }
      final type = pairs[i].$2;
      var j = i + 1;
      final tags = <int, List<String>>{};
      while (j < end && pairs[j].$1 != 0) {
        tags.putIfAbsent(pairs[j].$1, () => <String>[]).add(pairs[j].$2);
        j++;
      }
      if (type == 'TEXT' || type == 'MTEXT') {
        final t = _plainText(tags[1]?.first ?? '');
        final x = _d(tags, 10), y = _d(tags, 20);
        if (t.isNotEmpty && x != null && y != null) {
          texts.add((x: x, y: y, text: t));
        }
      } else if (type == 'INSERT') {
        final b = tags[2]?.first.trim();
        final x = _d(tags, 10), y = _d(tags, 20);
        if (b != null && b.isNotEmpty && x != null && y != null) {
          inserts.add((x: x, y: y, block: b));
        }
      }
      i = j;
    }

    // 配对规则（照图例版式）：名字与符号在**同一行**，取最近的未占用文字。
    final used = <int>{};
    for (final ins in inserts) {
      var best = -1;
      var bestScore = double.infinity;
      for (var k = 0; k < texts.length; k++) {
        if (used.contains(k)) continue;
        final t = texts[k];
        final dy = (t.y - ins.y).abs();
        if (dy > 8) continue; // 图例行距约 6~7
        // 纯代号（gl001 / gx004_y / lx002）是给设计员看的编号，不是名称。
        if (_isCodeLike(t.text)) continue;
        final score = dy * 10 + (t.x - ins.x).abs();
        if (score < bestScore) {
          bestScore = score;
          best = k;
        }
      }
      if (best >= 0) used.add(best);
      out.add(DxfLegendEntry(
        block: ins.block,
        label: best >= 0 ? texts[best].text : '',
        x: ins.x,
        y: ins.y,
      ));
    }
  }

  static bool _isCodeLike(String s) => RegExp(r'^[A-Za-z]{1,4}[_\-]?[A-Za-z0-9_]*$').hasMatch(s);
}

/// 内部：未展开的块引用。
class _InsertRef extends SymbolStroke {
  final String block;
  final double x, y, sx, sy, rot;
  const _InsertRef(this.block, this.x, this.y, this.sx, this.sy, this.rot);
}
