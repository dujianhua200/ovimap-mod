/// 出图图框：从用户的 DXF **原样搬用**，尺寸不变，装不下就多张。
///
/// ## 用户口径
/// "把这个导入到软件里面，这是个图框，导出 DXF 的时候用这个图框，
///  大小不要变，把导出的放到图框里面，如果无法放下，就导出 2 个图框"
///
/// ## 实现要点
/// 1. **大小不变**：图框的块定义、尺寸、线型、文字全部按原 DXF 逐字搬运，
///    不做任何缩放。用户给的 A3 图框内框 392×281，导出的图正好这么大。
/// 2. **装不下就分幅**：内容超出一张图框可用区域时，按行/列切成多张，
///    每张独立一套完整图框（不是拼接），符合施工现场按图幅打印的习惯。
/// 3. **坐标对齐**：用户的图框原点在 (22950.71, -8633.58) 这种远处坐标上，
///    如果直接搬用，导出物体会落在离图框很远的原点附近 —— 所以要把
///    图框平移、旋转对齐到内容坐标系（块内 bbox 归一化到原点）。
library;

import 'dart:convert' show latin1, LineSplitter, Utf8Decoder, Utf8Encoder;
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:gbk_codec/gbk_codec.dart' show gbk_bytes;

/// 图框图元（统一成简单几何，便于写进 R12/R2000）。
sealed class FrameShape {
  const FrameShape();
}

class FrameLine extends FrameShape {
  final double x1, y1, x2, y2;
  final String layer;
  const FrameLine(this.x1, this.y1, this.x2, this.y2, this.layer);
}

class FramePoly extends FrameShape {
  final List<List<double>> pts;
  final bool closed;
  final String layer;
  const FramePoly(this.pts, this.closed, this.layer);
}

class FrameCircle extends FrameShape {
  final double cx, cy, r;
  final String layer;
  const FrameCircle(this.cx, this.cy, this.r, this.layer);
}

class FrameText extends FrameShape {
  final double x, y, h, rot;
  final String text;
  final String layer;
  const FrameText(
      this.x, this.y, this.h, this.rot, this.text, this.layer);
}

/// 解析好的图框。
class FrameTemplate {
  /// 图框线稿（已归一化：左下角在原点）。
  final List<FrameShape> shapes;

  /// 图框原始尺寸（图面单位）。
  final double width;
  final double height;

  const FrameTemplate(this.shapes, this.width, this.height);

  /// 可用内容区（留出图框边距 + 图签/图例区）。
  ///
  /// 图签在图框右下、图例在左下，都是压在图面上的，所以要预留。
  double get contentInset => math.max(8.0, width * 0.03);

  double get contentWidth => width - contentInset * 2;
  double get contentHeight => height - contentInset * 2 - height * 0.10;

  /// 平移整份图框：让它的左下角落在 (dx, dy)。
  FrameTemplate translated(double dx, double dy) {
    List<FrameShape> moved = [];
    for (final s in shapes) {
      switch (s) {
        case FrameLine l:
          moved.add(FrameLine(l.x1 + dx, l.y1 + dy, l.x2 + dx, l.y2 + dy,
              l.layer));
        case FramePoly p:
          moved.add(FramePoly(
              [for (final q in p.pts) [q[0] + dx, q[1] + dy]],
              p.closed,
              p.layer));
        case FrameCircle cc:
          moved.add(FrameCircle(cc.cx + dx, cc.cy + dy, cc.r, cc.layer));
        case FrameText t:
          moved.add(FrameText(
              t.x + dx, t.y + dy, t.h, t.rot, t.text, t.layer));
      }
    }
    return FrameTemplate(moved, width, height);
  }

  /// 从图框里**实测**图签格位（v3.21）。
  ///
  /// ## 为什么必须实测
  /// 之前 `_fillFrameTitleCells` 按凭空估的 "30 单位高、46% 宽" 算格子，
  /// 而用户图框的真实格线是 y = 0.70 / 6.60 / 12.49 / 18.39 / 24.29 / 30.18，
  /// 格高 5.89~5.90（不是 6.0）。估出来的中心和真实中心差 1~1.6 个单位，
  /// 文字就掉到格子下沿 —— 用户说的"字老错行，没在表格内"。
  ///
  /// ## 识别方法
  /// 图签是"右下角一组等距水平线"。做法：
  ///  · 取所有水平线，按 y 聚类；
  ///  · 找连续 4~6 条、间距相近（±15%）、且都落在右下角（x 起点偏右）的那组；
  ///  · 返回这组线的 y 值（从高到低）与其 x 范围。
  ///
  /// 找不到就返回 null，调用方回退到估算。
  ({List<double> ys, double x0, double x1})? findTitleBlockRows() {
    // 收集水平线（y 相同即水平）
    final hs = <({double y, double x0, double x1})>[];
    for (final s in shapes) {
      if (s is FrameLine && (s.y1 - s.y2).abs() < 0.01) {
        final a = math.min(s.x1, s.x2), b = math.max(s.x1, s.x2);
        hs.add((y: (s.y1 + s.y2) / 2, x0: a, x1: b));
      }
    }
    if (hs.length < 4) return null;

    // 按 y 降序
    hs.sort((a, b) => b.y.compareTo(a.y));

    // 图签在右下角：x 起点应大于图框宽度的一半
    final rightHalf = width * 0.42;

    // 找"最短的那批横线"作为候选（图签格线通常比图框边框短）
    final cand = hs.where((h) => h.x0 >= rightHalf - width * 0.05).toList();
    if (cand.length < 4) return null;

    // 从候选里找 4~6 条间距一致的连续组
    ({List<double> ys, double x0, double x1})? best;
    var bestScore = double.infinity;

    for (var start = 0; start < cand.length; start++) {
      final group = <({double y, double x0, double x1})>[cand[start]];
      for (var k = start + 1; k < cand.length; k++) {
        final prev = group.last;
        final d = prev.y - cand[k].y;
        if (d <= 0.05) continue; // 同一条线的重复
        if (d > 20) break; // 跨度太大，不是同一组格线
        group.add(cand[k]);
        if (group.length > 6) break;
      }
      if (group.length < 4) continue;

      // 间距一致性：标准差越小越好
      final gaps = <double>[
        for (var i = 1; i < group.length; i++) group[i - 1].y - group[i].y
      ];
      final mean = gaps.reduce((a, b) => a + b) / gaps.length;
      if (mean < 1.0 || mean > 15) continue;
      var varSum = 0.0;
      for (final g in gaps) {
        varSum += (g - mean) * (g - mean);
      }
      final sd = math.sqrt(varSum / gaps.length);
      if (sd / mean > 0.15) continue; // 间距不齐，不是图签

      if (sd < bestScore) {
        bestScore = sd;
        best = (
          ys: [for (final g in group) g.y],
          x0: group.map((g) => g.x0).reduce(math.min),
          x1: group.map((g) => g.x1).reduce(math.max),
        );
      }
    }
    return best;
  }

  /// 给定内容尺寸，算需要几行几列图框。
  ({int cols, int rows}) tilesFor(double contentW, double contentH) {
    final cols = math.max(1, (contentW / contentWidth).ceil());
    final rows = math.max(1, (contentH / contentHeight).ceil());
    return (cols: cols, rows: rows);
  }

  /// **替换图框里写死的工程名**（v3.20）。
  ///
  /// 用户图框的"新县福星园三期"是硬编码在图块里的示例工程名。
  /// 导出时应换成用户自己的工程名 —— 用户口径：
  /// "新县福星园三期 这个用工程名称自动代替"。
  ///
  /// 做法：找出文字里含 [placeholder] 的那条，把 content 换掉；
  /// 找不到就**保留原样**（不猜、不乱改别的文字）。
  FrameTemplate replaceProjectName(String newName, {String placeholder = '新县福星园三期'}) {
    if (newName.trim().isEmpty) return this;
    final out = <FrameShape>[];
    for (final s in shapes) {
      if (s is FrameText && s.text.contains(placeholder)) {
        out.add(FrameText(s.x, s.y, s.h, s.rot,
            s.text.replaceAll(placeholder, newName.trim()), s.layer));
      } else {
        out.add(s);
      }
    }
    return FrameTemplate(out, width, height);
  }
}

/// 可选图框规格（用户口径："弄个选择，比如选择 A3 或者 A4"）。
enum FrameSize {
  /// 原图框（用户自己画的 A3 内框，392×281）。
  legacy('新块（A3 内框）', 'assets/frames/frame_a3.dxf', 392, 281),

  /// 标准 A3 图框（从 A4模板.dxf 提取，420×297）。
  a3('A3 标准图框', 'assets/frames/frame_tk_a3.dxf', 420, 297),

  /// 标准 A4 图框（从 A4模板.dxf 提取，297×210）。
  a4('A4 标准图框', 'assets/frames/frame_tk_a4.dxf', 297, 210);

  const FrameSize(this.label, this.asset, this.widthMm, this.heightMm);

  final String label;
  final String asset;
  final double widthMm;
  final double heightMm;

  /// 宽高比（供 UI 画小预览用）。
  double get aspect => widthMm / heightMm;
}

/// 加载内置图框。
///
/// 支持多套图框（A3/A4/原图框），按 [FrameSize] 选择；
/// 每套单独缓存，切换时不重复解析。
class FrameLibrary {
  FrameLibrary._();
  static final Map<FrameSize, FrameTemplate> _cache = {};
  static bool enabled = true;

  /// 默认图框规格（与旧行为一致：用户画的 A3 内框）。
  static FrameSize defaultSize = FrameSize.legacy;

  static Future<FrameTemplate?> load([FrameSize? size]) async {
    if (!enabled) return null;
    final s = size ?? defaultSize;
    final c = _cache[s];
    if (c != null) return c;
    try {
      final raw = await rootBundle.load(s.asset);
      final bytes = raw.buffer.asUint8List();
      // AS-IS 文本：图框 DXF 的 `$DWGCODEPAGE = ANSI_936`（中文 GBK）。
      // 解析只用 ASCII 组码/数值，中文按 GBK 还原（见 _decodeDxfText）。
      final text = latin1.decode(bytes);
      final t = parseDxfFrame(text);
      _cache[s] = t;
      return t;
    } catch (_) {
      return null;
    }
  }

  static void setForTest(FrameTemplate? t, [FrameSize? size]) {
    if (t == null) {
      _cache.remove(size ?? defaultSize);
    } else {
      _cache[size ?? defaultSize] = t;
    }
  }

  static void resetForTest() => _cache.clear();
}

/// 清理 MTEXT 的富文本控制码，只留可读文字。
///
/// ## 为什么必须清
/// 用户图框的 MTEXT 原文长这样（`$DWGCODEPAGE = ANSI_936`）：
///
///     {\fSimSun|b0|i0|c134|p2;\H1.2x;专业负责人}
///
/// 我们把它当**纯文字**写进导出的 `TEXT` 实体，CAD 打开时看到
/// `\fSimSun|b0|...` 这种非法转义 → **"无效或不完整的 DXF 输入，图形被放弃"**。
/// 这正是用户导出后打不开的直接原因。
///
/// ## 清理规则
/// · 去掉 `\f<字体>|b|i|c|p;`、`\H<倍数>x;`、`\W<倍数>x;` 等格式指令；
/// · 去掉成对的 `{ }` 分组符；
/// · `\P` 换行 → 空格（TEXT 不支持多行）；
/// · `%%d/%%c/%%p` 等 AutoCAD 控制码保留（它们是合法的）；
/// · 中文按 **GBK** 还原（文件声明 ANSI_936，直接 latin1 解出来是乱码）。
String _cleanMText(String raw) {
  var s = _decodeDxfText(raw);

  // 反复剥离，处理嵌套
  for (var guard = 0; guard < 8; guard++) {
    final before = s;
    // \fSimSun|b0|i0|c134|p2;   /  \H1.2x;  /  \W0.8x;  /  \C1;  /  \T1.1;
    s = s.replaceAll(
        RegExp(r'\\[fFWHCTQAhwq][^;\\{}]*;'), '');
    // \P（换行）、\~（不换行空格）
    s = s.replaceAll(RegExp(r'\\P'), ' ');
    s = s.replaceAll(RegExp(r'\\~'), ' ');
    // 其它反斜杠转义（\L \O \K \o 等单字符开关）
    s = s.replaceAll(RegExp(r'\\[LOKlo]'), '');
    // 成组花括号
    s = s.replaceAll('{', '').replaceAll('}', '');
    if (s == before) break;
  }

  // 收尾：只去首尾空白。**不合并内部空格** —— 图框里「审  核」「图  例」
  // 这种排版空格是设计的一部分，压掉会变成「审 核」。
  s = s.replaceAll(RegExp(r'^\s+|\s+$'), '');
  return s;
}

/// DXF 文本还原中文。
///
/// ## 坑：`$DWGCODEPAGE` 会撒谎
/// 用户图框头部写的是 `ANSI_936`（GBK），但实际字节是 **UTF-8**：
/// `\xe5\xae\xa1` = UTF-8 的「审」，按 GBK 解就报错/乱码。
/// （很多国内 CAD 插件导出 DXF 时都这样：抄了 R12 的头部模板，
///  内容却按现代 UTF-8 写。）
///
/// ## 策略：先 UTF-8，失败再 GBK
/// 解析器全程用 `latin1` 读（保证组码/数值不错位），
/// 所以这里要把 char 还原成字节再按正确编码解码。
/// 顺序很重要：UTF-8 校验很严（非法序列必抛），能当探测器用；
/// 解不出来时再退回 GBK（老图纸常见）。
String _decodeDxfText(String s) {
  var hasHigh = false;
  for (final c in s.codeUnits) {
    if (c > 0x7F) {
      hasHigh = true;
      break;
    }
  }
  if (!hasHigh) return s;

  final bytes = <int>[];
  for (final c in s.codeUnits) {
    if (c <= 0xFF) {
      bytes.add(c);
    } else {
      bytes.addAll(Utf8Encoder().convert(String.fromCharCode(c)));
    }
  }

  // ① UTF-8（严格：非法序列会抛）
  try {
    return const Utf8Decoder().convert(bytes);
  } catch (_) {}
  // ② GBK / GB18030（老 R12 图纸）
  try {
    return gbk_bytes.decode(bytes);
  } catch (_) {}
  // ③ 都失败：原样返回（绝不因编码问题丢掉整份图框）
  return s;
}


FrameTemplate parseDxfFrame(String text) {
  final lines = const LineSplitter().convert(text.replaceAll('\r', ''));
  // 组成 (code, value) 对
  final pairs = <List<String>>[];
  for (var i = 0; i + 1 < lines.length; i += 2) {
    pairs.add([lines[i].trim(), lines[i + 1]]);
  }

  // 收集 BLOCKS 段里每个块的实体
  final blocks = <String, List<FrameShape>>{};
  // **同时收集 ENTITIES 段**（v3.26）：
  // ezdxf 提取出的图框把实体放在 modelspace 里，不在 BLOCKS。
  // 两种来源都要支持，否则新图框会解析成空。
  final entities = <FrameShape>[];
  var i = 0;
  while (i < pairs.length) {
    if (pairs[i][0] == '0' && pairs[i][1].trim() == 'SECTION') {
      final secName = (i + 1 < pairs.length && pairs[i + 1][0] == '2')
          ? pairs[i + 1][1].trim()
          : '';
      if (secName == 'BLOCKS') {
        i = _parseBlocks(pairs, i + 2, blocks);
        continue;
      }
      if (secName == 'ENTITIES') {
        i = _parseEntities(pairs, i + 2, entities);
        continue;
      }
    }
    i++;
  }

  // modelspace 里有实体 → 直接用它（新提取的 A3/A4 图框走这条）
  if (entities.isNotEmpty) {
    return _normalize(entities);
  }

  // 否则取 BLOCKS 里"含最多几何"的块（用户手画图框走这条）
  String? rootName;
  for (final e in blocks.entries) {
    if (e.value.isNotEmpty) {
      rootName ??= e.key;
    }
  }
  if (rootName == null) {
    return const FrameTemplate([], 420, 297);
  }

  // 展开嵌套 INSERT：把内层块图元按插入点平移
  final flat = <FrameShape>[];
  _flatten(rootName, blocks, 0, 0, flat, <String>{});

  if (flat.isEmpty) return const FrameTemplate([], 420, 297);
  return _normalize(flat);
}

/// 把一组图元归一化：整体平移到左下角在原点，返回 [FrameTemplate]。
FrameTemplate _normalize(List<FrameShape> flat) {
  if (flat.isEmpty) return const FrameTemplate([], 420, 297);

  // 归一化：整体平移到左下角在原点
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  void acc(double x, double y) {
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }

  for (final s in flat) {
    switch (s) {
      case FrameLine l:
        acc(l.x1, l.y1);
        acc(l.x2, l.y2);
      case FramePoly p:
        for (final q in p.pts) {
          acc(q[0], q[1]);
        }
      case FrameCircle c:
        acc(c.cx - c.r, c.cy - c.r);
        acc(c.cx + c.r, c.cy + c.r);
      case FrameText t:
        acc(t.x, t.y);
    }
  }

  if (!minX.isFinite || !minY.isFinite) {
    return const FrameTemplate([], 420, 297);
  }

  final dx = -minX, dy = -minY;
  final out = <FrameShape>[];
  for (final s in flat) {
    switch (s) {
      case FrameLine l:
        out.add(FrameLine(
            l.x1 + dx, l.y1 + dy, l.x2 + dx, l.y2 + dy, l.layer));
      case FramePoly p:
        out.add(FramePoly(
            [for (final q in p.pts) [q[0] + dx, q[1] + dy]], p.closed, p.layer));
      case FrameCircle c:
        out.add(FrameCircle(c.cx + dx, c.cy + dy, c.r, c.layer));
      case FrameText t:
        out.add(FrameText(t.x + dx, t.y + dy, t.h, t.rot, t.text, t.layer));
    }
  }

  return FrameTemplate(out, maxX - minX, maxY - minY);
}

/// 解析 ENTITIES 段（modelspace）里的图元，直接追加到 [out]。
///
/// 与 [_parseBlocks] 的区别：这里没有"块"的概念，遇到 ENDSEC 就结束。
int _parseEntities(
    List<List<String>> pairs, int start, List<FrameShape> out) {
  var i = start;
  var entType = '';
  var ent = <String, String>{};
  final lwVertices = <List<double>>[];
  double? pendingX;

  void flushEnt() {
    if (entType.isEmpty) {
      ent = {};
      lwVertices.clear();
      pendingX = null;
      return;
    }
    final s = _shapeFromEntity(entType, ent, lwVertices);
    if (s != null) out.add(s);
    entType = '';
    ent = {};
    lwVertices.clear();
    pendingX = null;
  }

  while (i < pairs.length) {
    final code = pairs[i][0];
    final value = pairs[i][1];
    if (code == '0') {
      final v = value.trim();
      if (v == 'ENDSEC') {
        flushEnt();
        return i + 1;
      }
      flushEnt();
      entType = v;
      i++;
      continue;
    }
    if (entType.isNotEmpty) {
      ent[code] = value.trim();
      if (entType == 'LWPOLYLINE') {
        if (code == '10') {
          pendingX = double.tryParse(value.trim());
        } else if (code == '20' && pendingX != null) {
          lwVertices.add([pendingX!, double.tryParse(value.trim()) ?? 0]);
          pendingX = null;
        }
      }
    }
    i++;
  }
  flushEnt();
  return i;
}

int _parseBlocks(List<List<String>> pairs, int start,
    Map<String, List<FrameShape>> out) {
  var i = start;
  String? curName;
  var curShapes = <FrameShape>[];

  // 临时收集当前实体的组码
  var entType = '';
  var ent = <String, String>{};
  // LWPOLYLINE 的全部顶点（组码 10/20 成对重复出现）
  final lwVertices = <List<double>>[];
  double? pendingX;

  void flushEnt() {
    if (curName == null || entType.isEmpty) {
      entType = '';
      ent = {};
      lwVertices.clear();
      pendingX = null;
      return;
    }
    final s = _shapeFromEntity(entType, ent, lwVertices);
    if (s != null) curShapes.add(s);
    entType = '';
    ent = {};
    lwVertices.clear();
    pendingX = null;
  }

  while (i < pairs.length) {
    final code = pairs[i][0];
    final value = pairs[i][1];
    if (code == '0') {
      final v = value.trim();
      if (v == 'ENDSEC') {
        flushEnt();
        if (curName != null) out[curName] = curShapes;
        return i + 1;
      }
      if (v == 'BLOCK') {
        flushEnt();
        curName = null;
        curShapes = [];
        // 下一个 code 2 是块名
        var j = i + 1;
        while (j < pairs.length && pairs[j][0] != '0') {
          if (pairs[j][0] == '2') {
            curName = pairs[j][1].trim();
            break;
          }
          j++;
        }
      } else if (v == 'ENDBLK') {
        flushEnt();
        if (curName != null) out[curName] = curShapes;
        curName = null;
        curShapes = [];
      } else {
        flushEnt();
        entType = v;
      }
      i++;
      continue;
    }
    if (entType.isNotEmpty) {
      ent[code] = value.trim();
      // LWPOLYLINE / POLYLINE 的顶点：组码 10 与 20 成对出现
      if (entType == 'LWPOLYLINE') {
        if (code == '10') {
          pendingX = double.tryParse(value.trim());
        } else if (code == '20' && pendingX != null) {
          lwVertices.add([pendingX!, double.tryParse(value.trim()) ?? 0]);
          pendingX = null;
        }
      }
    }
    i++;
  }
  if (curName != null) out[curName] = curShapes;
  return i;
}

FrameShape? _shapeFromEntity(
    String type, Map<String, String> e, List<List<double>> lwVertices) {
  double d(String k, [double def = 0]) => double.tryParse(e[k] ?? '') ?? def;
  final layer = e['8'] ?? '0';
  switch (type) {
    case 'LINE':
      return FrameLine(d('10'), d('20'), d('11'), d('21'), layer);
    case 'LWPOLYLINE':
      // ⚠️ LWPOLYLINE 的顶点是**多个 10/20 对**，不是单个 10/20。
      // 早期实现只取第一对，导致图框外框（4 顶点矩形 392×281）被截成两个点，
      // 解析出来的图框宽度只剩 176 —— 图框就画残了。
      // 这里由 _parseBlocks 收集全部顶点后传入（见 lwVertices）。
      final pts = <List<double>>[];
      for (final p in lwVertices) {
        pts.add([p[0], p[1]]);
      }
      if (pts.length < 2) return null;
      // 组码 70 第 0 位 = 闭合
      final flags = int.tryParse(e['70'] ?? '0') ?? 0;
      return FramePoly(pts, (flags & 1) == 1, layer);
    case 'CIRCLE':
      return FrameCircle(d('10'), d('20'), d('40'), layer);
    case 'TEXT':
      return FrameText(d('10'), d('20'), d('40', 2.5), d('50'),
          _cleanMText(e['1'] ?? ''), layer);
    case 'MTEXT':
      return FrameText(d('10'), d('20'), d('40', 2.5), d('50'),
          _cleanMText(e['1'] ?? ''), layer);
    default:
      return null;
  }
}

void _flatten(String name, Map<String, List<FrameShape>> blocks, double ox,
    double oy, List<FrameShape> out, Set<String> seen) {
  if (seen.contains(name)) return;
  final shapes = blocks[name];
  if (shapes == null) return;
  seen.add(name);
  for (final s in shapes) {
    switch (s) {
      case FrameLine l:
        out.add(FrameLine(l.x1 + ox, l.y1 + oy, l.x2 + ox, l.y2 + oy,
            l.layer));
      case FramePoly p:
        out.add(FramePoly(
            [for (final q in p.pts) [q[0] + ox, q[1] + oy]], p.closed,
            p.layer));
      case FrameCircle c:
        out.add(FrameCircle(c.cx + ox, c.cy + oy, c.r, c.layer));
      case FrameText t:
        out.add(FrameText(t.x + ox, t.y + oy, t.h, t.rot, t.text, t.layer));
    }
  }
  seen.remove(name);
}
