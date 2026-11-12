import 'dart:ui' show Color;

import '../symbols/dxf_block_parser.dart';
import '../symbols/symbol_catalog.dart';

/// 通信线路图符号库（对齐联通线路 CAD 图例 / YDT 5015 制图标准）。
///
/// shape：pin=水滴定位针，oval=椭圆（人井/手井），box=矩形框（各类箱），
///        tri=三角（引上），text=纯文字，block=**图例库 DXF 图块**（真几何）。
/// role ：拓扑角色，用于配线/拓扑图生成：
///   0=普通点  1=分光器  2=分交箱  3=ONU  4=交接箱
///   5=杆路    6=管道/井  7=机房/局端  8=终端
///
/// ## 两套符号来源（同一份 all 列表）
/// 1. **预置符号**（`pipe` / `concrete` / `crossbox`…）：v3.9 之前就在用，
///    id 是英文代号，出图靠形状近似（椭圆/矩形/三角）+ 文字。老工程 JSON 里的
///    `typeId` 全是这些代号，**必须继续认识**，否则旧数据一打开就全变"管道口"。
/// 2. **图例库符号**（`gl001` / `gx005_x`…）：来自随包的 `lispblock.dxf`，
///    id 就是图块编号，出图时 INSERT 真图块、几何与用户 CAD 图例一致。
///
/// 后者由 [SymbolCatalog] 在启动时灌进 [installCatalog]，追加在预置符号之后。
/// 这样"老工程照旧、新工程可用自己的图例"，同一份 id 空间不冲突（英文代号 vs 编号）。
class LabelType {
  final String id;
  final String name;
  final String symbol;
  final Color color;
  final String shape;
  final int role;

  /// 图例库图块（`shape == 'block'` 时非 null）：出图用它的真实几何。
  final DxfBlock? block;

  /// 符号所属分组（符号库分栏用；预置符号为空串）。
  final String group;

  const LabelType(this.id, this.name, this.symbol, this.color, this.shape, this.role,
      {this.block, this.group = ''});

  // ---- 预置符号 ----
  static const LabelType pipe =
      LabelType('pipe', '管道口', '管', Color(0xFF1565C0), 'pin', 6);
  static const LabelType concrete =
      LabelType('concrete', '水泥杆', '电', Color(0xFF6A1B9A), 'pin', 5);
  static const LabelType wood =
      LabelType('wood', '木杆', '木', Color(0xFF5D4037), 'pin', 5);
  static const LabelType electric =
      LabelType('electric', '电力杆', 'P', Color(0xFFE53935), 'pin', 5);
  static const LabelType manhole =
      LabelType('manhole', '人孔', '人', Color(0xFF00838F), 'oval', 6);
  static const LabelType handwell =
      LabelType('handwell', '手井', '井', Color(0xFFEF6C00), 'oval', 6);
  static const LabelType fiberbox =
      LabelType('fiberbox', '分交箱', '纤', Color(0xFF2E7D32), 'box', 2);
  static const LabelType splitterbox =
      LabelType('splitterbox', '分光器箱', '光', Color(0xFF00695C), 'box', 1);
  static const LabelType onubox =
      LabelType('onubox', 'ONU箱', 'U', Color(0xFF3949AB), 'box', 3);
  static const LabelType crossbox =
      LabelType('crossbox', '交接箱', '交', Color(0xFFAD1457), 'box', 4);
  static const LabelType riser =
      LabelType('riser', '引上', '↑', Color(0xFF6D4C41), 'tri', 0);
  static const LabelType room =
      LabelType('room', '机房', '机', Color(0xFF455A64), 'box', 7);
  static const LabelType bts =
      LabelType('bts', '基站', '站', Color(0xFF0097A7), 'box', 7);
  static const LabelType track =
      LabelType('track', '轨迹', '', Color(0xFFFFC107), 'pin', 0);
  static const LabelType none =
      LabelType('none', '无标签', '', Color(0xFF9E9E9E), 'pin', 0);
  static const LabelType text =
      LabelType('text', '文字', '', Color(0xFF37474F), 'text', 0);
  static const LabelType area =
      LabelType('area', '区域', '', Color(0xFFAB47BC), 'pin', 0);

  /// 预置符号（顺序即 UI 顺序，与 v3.9 一致）。
  static const List<LabelType> builtin = [
    pipe, concrete, wood, electric, manhole, handwell,
    fiberbox, splitterbox, onubox, crossbox, riser, room, bts,
    track, none, text,
  ];

  /// 图例库符号（由 [installCatalog] 填充；未装资源时为空）。
  static List<LabelType> _fromCatalog = const [];

  /// 已装好的图例目录（符号库 UI 用它画真几何、分栏）。
  static SymbolCatalog? catalog;

  /// 把图例库装进符号表（启动时调一次；重复调用覆盖）。
  ///
  /// 返回新增符号数。同名 id 已被预置符号占用时跳过（不覆盖既有语义）。
  static int installCatalog(SymbolCatalog cat) {
    catalog = cat;
    final taken = {for (final t in builtin) t.id};
    final out = <LabelType>[];
    for (final s in cat.symbols) {
      if (taken.contains(s.blockId)) continue;
      out.add(LabelType(
        s.blockId, // id = 图块编号（用户口径：图标ID就是图块的编号）
        s.name, // 名字 = 图例里那行文字（用户口径：名字就是图块的名字）
        _glyphOf(s),
        _colorOf(s),
        'block',
        _roleOf(s),
        block: s.block,
        group: s.group,
      ));
    }
    _fromCatalog = out;
    return out.length;
  }

  /// 符号库里的格子字：取名称首字（与旧版预置符号的视觉重量一致）。
  static String _glyphOf(SymbolDef s) {
    final n = s.name.trim();
    return n.isEmpty ? '' : n.substring(0, 1);
  }

  /// 图例符号统一用深灰描边色：真实几何本身就是"线稿"，不需要再用色块区分。
  static Color _colorOf(SymbolDef s) {
    const palette = [
      Color(0xFF455A64),
      Color(0xFF6A1B9A),
      Color(0xFF1565C0),
      Color(0xFF00695C),
      Color(0xFFAD1457),
      Color(0xFFEF6C00),
    ];
    final i = s.name.hashCode.abs() % palette.length;
    return palette[i];
  }

  /// 从名称推拓扑角色（新建/原有杆=5，人井/手孔=6，交接箱/分纤箱=2，机房/基站=7）。
  static int _roleOf(SymbolDef s) {
    final n = s.name;
    if (n.contains('拉线')) return 5;
    if (n.contains('人井') || n.contains('手孔') || n.contains('页井')) return 6;
    if (n.contains('交接箱') || n.contains('分纤箱') || n.contains('分光')) return 2;
    if (n.contains('机房') || n.contains('基站')) return 7;
    if (n.contains('杆')) return 5;
    return 0;
  }

  /// 底部可放置符号条（横向可滚动，对齐图例）：预置 + 图例库。
  static List<LabelType> get all => [...builtin, ..._fromCatalog];

  bool get isOval => shape == 'oval';
  bool get isBox => shape == 'box';
  bool get isTri => shape == 'tri';

  /// 图例库图块符号（出图时 INSERT 真块）。
  bool get isBlock => shape == 'block' && block != null;

  /// 该类是否参与拓扑（有配线角色）。
  bool get isTopoNode => role >= 1 && role <= 8;

  /// 独立个体：光交/分光器箱/分交箱/ONU箱/机房/基站/引上/文字。
  /// 画完杆路后单独添加的点，不参与连线绘制（杆路线从它们"穿过"继续走）。
  bool get isStandalone => const [
        'crossbox', 'splitterbox', 'fiberbox', 'onubox',
        'room', 'bts', 'riser', 'text'
      ].contains(id) ||
      // 图例库里的箱体/机房同样是独立个体（否则会打断杆路）。
      (isBlock && const ['交接箱', '分纤箱', '机房', '基站', '接头', 'ODB', '分光']
          .any(name.contains));

  /// 拓扑连线模式可选节点类型。
  bool get isTopoLinkable => const [
        'crossbox', 'splitterbox', 'fiberbox', 'onubox',
        'room', 'bts', 'riser'
      ].contains(id) ||
      (isBlock && const ['交接箱', '分纤箱', '机房', '基站', '分光'].any(name.contains));

  static LabelType fromId(String? id) {
    for (final t in all) {
      if (t.id == id) return t;
    }
    if (area.id == id) return area;
    return pipe;
  }
}
