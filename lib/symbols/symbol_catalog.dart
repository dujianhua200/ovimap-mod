/// 图例符号目录：把随包发出的 `assets/dxf/lispblock.dxf` 变成软件的符号库。
///
/// ## 为什么要这一层
/// 用户的图例库是一份 AutoCAD 图例图纸（`lispblock.dxf`，AC1021），里面既有
/// **图块定义**（`gl001` 新建水泥杆、`gx005_x` 新建人井……），又有**版式说明**
/// （块定义区上方那一排名字文字、`杆路块定义` / `管道块定义` 分组标题）。
///
/// 软件要的是"符号目录"，CAD 给的是"图纸"。本层负责把后者翻译成前者：
/// - **编号**取图块名（`gl001`）——用户口径："图标ID就是图块的编号"；
/// - **名称**取图例里紧挨着它的那行文字（`新建水泥杆`）——用户口径：
///   "名字就是图块的名字"；没有图例文字的块（`机房` / `基站`）直接用块名；
/// - 只收**点状符号**：标题栏（`TK_A1_001` 841×594）、`铁路`（374×170）这类
///   整幅/线性图元不是点符号，混进符号库只会让用户在几百个选项里翻。
library;

import 'dart:async';

import 'package:flutter/services.dart' show rootBundle;

import 'dxf_block_parser.dart';

/// 一个可用的图例符号。
class SymbolDef {
  /// 图块编号（`gl001`）——同时作为 `LabelType.id` 与 DXF 里的 INSERT 块名。
  final String blockId;

  /// 显示名（`新建水泥杆`）。
  final String name;

  /// 归一化几何（纸面毫米，已按块基点归零）。
  final DxfBlock block;

  /// 分组（杆 / 井 / 拉线 / 设施 / 其他），供符号库分栏用。
  final String group;

  const SymbolDef({
    required this.blockId,
    required this.name,
    required this.block,
    required this.group,
  });

  /// 符号在纸面上的最大边（毫米）。决定符号库里格子的相对大小。
  double get sizeMm =>
      block.maxSide <= 0 ? 3.0 : block.maxSide.clamp(1.0, 40.0);
}

/// 符号目录（进程内单例，解析一次）。
class SymbolCatalog {
  SymbolCatalog._(this.symbols, this.warnings);

  /// 全部点状符号，按"杆 → 井 → 拉线 → 设施 → 其他"分组顺序排列。
  final List<SymbolDef> symbols;

  /// 解析告警（块循环引用、退化几何等）；空表示干净。
  final List<String> warnings;

  static SymbolCatalog? _instance;

  /// 已加载的目录；未加载时为 null（测试/无资源环境下调用方须自行兜底）。
  static SymbolCatalog? get instance => _instance;

  /// 清空单例（测试用）。
  static void resetForTest() => _instance = null;

  /// 资源路径。改文件名只改这一处。
  static const String assetPath = 'assets/dxf/lispblock.dxf';

  /// 从 Flutter 资源加载（重复调用返回同一实例）。
  static Future<SymbolCatalog> ensureLoaded({String asset = assetPath}) {
    final cached = _instance;
    if (cached != null) return Future.value(cached);
    return _load(asyncLoader(asset));
  }

  /// 从任意文本源同步构建（测试注入内存 DXF，不碰资源包）。
  ///
  /// **不写单例**：测试里反复构造不同目录时不能互相污染。
  static SymbolCatalog fromTextSync(String dxf) {
    final parsed = DxfBlockParser.parse(dxf);
    return SymbolCatalog._(_toDefs(parsed), parsed.warnings);
  }

  /// 从任意文本源构建并**装成单例**（生产路径用）。
  static Future<SymbolCatalog> fromText(String dxf) => _load(Future.value(dxf));

  /// 默认的文本加载器（可被测试替换）。
  static Future<String> Function(String asset) asyncLoader =
      (asset) => rootBundle.loadString(asset);

  static Future<SymbolCatalog> _load(Future<String> textF) async {
    final text = await textF;
    final parsed = DxfBlockParser.parse(text);
    final defs = _toDefs(parsed);
    final cat = SymbolCatalog._(defs, parsed.warnings);
    _instance = cat;
    return cat;
  }

  /// 由解析结果挑出"点状符号"并定名分组。
  static List<SymbolDef> _toDefs(DxfParseResult parsed) {
    // 图例文字 → 块编号（一份 DXF 里同一块可被引用多次，取首个非空名字）。
    final labelOf = <String, String>{};
    for (final e in parsed.legend) {
      if (e.label.trim().isEmpty) continue;
      labelOf.putIfAbsent(e.block, () => e.label.trim());
    }

    final out = <SymbolDef>[];
    for (final entry in parsed.blocks.entries) {
      final block = entry.value;
      final id = entry.key;
      if (block.isEmpty) continue;
      // 点状符号的尺寸上限：超过 60mm 的（标题栏、铁路、桥梁跨幅）不是点符号。
      if (block.maxSide > 60) continue;
      // 极扁/极细的长条（接图符号 56.8×2.5）同样不是点符号。
      final minSide = block.width < block.height ? block.width : block.height;
      if (block.maxSide > 20 && minSide < 3) continue;

      final name = labelOf[id] ?? id;
      out.add(SymbolDef(
        blockId: id,
        name: name,
        block: block,
        group: _groupOf(id, name),
      ));
    }

    // 分组顺序 + 组内按名称的"新建/原有"习惯排序（新建在前）。
    const groupRank = {'杆': 0, '井': 1, '拉线': 2, '设施': 3, '其他': 4};
    out.sort((a, b) {
      final g = (groupRank[a.group] ?? 9).compareTo(groupRank[b.group] ?? 9);
      if (g != 0) return g;
      final n = a.name.compareTo(b.name);
      if (n != 0) return n;
      return a.blockId.compareTo(b.blockId);
    });
    return out;
  }

  /// 按块编号前缀与名称关键词分组。
  ///
  /// 前缀是行业图例的固定约定（`gl`=杆、`gx`=井、`lx`=拉线），比按名字猜更可靠；
  /// 中文名的块（`机房` / `基站` / `交接箱`）按关键词落到"设施"。
  static String _groupOf(String id, String name) {
    final lower = id.toLowerCase();
    if (lower.startsWith('gl')) return '杆';
    if (lower.startsWith('gx')) return '井';
    if (lower.startsWith('lx')) return '拉线';
    if (name.contains('杆') && !name.contains('拉线')) return '杆';
    if (name.contains('井') || name.contains('手孔')) return '井';
    if (name.contains('拉线')) return '拉线';
    if (name.contains('箱') ||
        name.contains('机房') ||
        name.contains('基站') ||
        name.contains('ODB') ||
        name.contains('接头') ||
        name.contains('光缆') ||
        name.contains('施工')) {
      return '设施';
    }
    return '其他';
  }

  /// 按块编号查符号。
  SymbolDef? byId(String id) {
    for (final s in symbols) {
      if (s.blockId == id) return s;
    }
    return null;
  }

  /// 分组顺序（符号库分栏用）。
  List<String> get groups {
    final seen = <String>[];
    for (final s in symbols) {
      if (!seen.contains(s.group)) seen.add(s.group);
    }
    return seen;
  }
}
