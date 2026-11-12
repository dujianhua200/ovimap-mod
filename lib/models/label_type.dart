import 'dart:ui' show Color;

/// 通信线路图符号库（对齐联通线路 CAD 图例 / YDT 5015 制图标准）。
///
/// shape：pin=水滴定位针，oval=椭圆（人孔/手井），box=矩形框（各类箱），
///        tri=三角（引上），text=纯文字，vertex=顶点小圆。
/// role ：拓扑角色，用于配线/拓扑图生成
///   0=普通点  1=分光器  2=分纤盒  3=ONU  4=交接箱
///   5=杆路    6=管道/井 7=机房/局端 8=终端
class LabelType {
  final String id;
  final String name;
  final String symbol;
  final Color color;
  final String shape;
  final int role;

  const LabelType(this.id, this.name, this.symbol, this.color, this.shape, this.role);

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
      LabelType('fiberbox', '分纤盒', '纤', Color(0xFF2E7D32), 'box', 2);
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

  /// 底部可放置符号条（横向可滚动，对齐图例）。
  static const List<LabelType> all = [
    pipe, concrete, wood, electric, manhole, handwell,
    fiberbox, splitterbox, onubox, crossbox, riser, room, bts,
    track, none, text,
  ];

  bool get isOval => shape == 'oval';
  bool get isBox => shape == 'box';
  bool get isTri => shape == 'tri';

  /// 该类型是否参与拓扑（有配线角色）。
  bool get isTopoNode => role >= 1 && role <= 8;

  /// 独立个体：光交/分光器箱/分纤盒/ONU箱/机房/基站/引上/文字。
  /// 画完杆路后单独添加的点，不参与连线绘制（杆路线从它们"穿过"继续连）。
  bool get isStandalone => const [
        'crossbox', 'splitterbox', 'fiberbox', 'onubox',
        'room', 'bts', 'riser', 'text'
      ].contains(id);

  /// 拓扑连线模式可选节点类型。
  bool get isTopoLinkable => const [
        'crossbox', 'splitterbox', 'fiberbox', 'onubox',
        'room', 'bts', 'riser'
      ].contains(id);

  static LabelType fromId(String? id) {
    for (final t in all) {
      if (t.id == id) return t;
    }
    if (area.id == id) return area;
    return pipe;
  }
}
