import '../models/label_type.dart';
import '../models/map_label.dart';

/// ODN 配线拓扑树节点。
class TopoNode {
  final MapLabel src;
  final int level;
  int depth = 0;
  String title;
  final String sub;
  final String cable;
  final int cableCores;
  TopoNode? parent;
  final List<TopoNode> children = [];
  double x = 0, y = 0;

  TopoNode({
    required this.src,
    required this.level,
    required this.title,
    required this.sub,
    required this.cable,
    required this.cableCores,
  });
}

class TopoException implements Exception {
  final String message;
  TopoException(this.message);
  @override
  String toString() => message;
}

/// 配线拓扑树构建器：把收藏里的"有源节点"（机房/交接箱/分光器箱/分纤盒/ONU）
/// 连成 ODN 树。
///
/// 建树规则：
/// 1) 节点若设置了 topoParentId（拓扑编辑里手工指定）→ 直接挂到该父节点（带环检测）；
/// 2) 否则按 seq 顺序自动挂到其之前最近的、ODN 层级更高（数字更小）的节点。
class Topology {
  Topology._();

  static int _levelOf(int role) {
    switch (role) {
      case 7:
        return 0; // 机房/局端
      case 4:
        return 1; // 交接箱/光交
      case 1:
        return 2; // 分光器箱（一级分光）
      case 2:
        return 3; // 分纤盒（二级分光/楼层箱）
      case 3:
        return 4; // ONU
      default:
        return 5;
    }
  }

  /// 解析分光比 "1:8"/"1：16" → 下行端口数；无效返回 0。
  static int parseRatio(String? s) {
    if (s == null) return 0;
    final t = s.replaceAll('：', ':').replaceAll(' ', '');
    final i = t.indexOf(':');
    if (i < 0) return 0;
    final digits = t.substring(i + 1).replaceAll(RegExp(r'[^0-9]'), '');
    final down = int.tryParse(digits) ?? 0;
    return (down > 0 && down <= 128) ? down : 0;
  }

  /// 解析光缆规格里的芯数："48芯GYTS" → 48；无则 0。
  static int parseCores(String? s) {
    if (s == null) return 0;
    final m = RegExp(r'(\d+)\s*芯').firstMatch(s);
    if (m == null) return 0;
    return int.tryParse(m.group(1) ?? '') ?? 0;
  }

  /// 从标签集合构建拓扑树（仅含拓扑角色节点）。返回根列表。
  static List<TopoNode> buildTree(List<MapLabel> labels) {
    final nodes = <TopoNode>[];
    final byId = <String, TopoNode>{};
    for (final l in labels) {
      final lt = l.type;
      if (!lt.isTopoNode || lt.role == 5 || lt.role == 6) continue; // 杆/井不进拓扑
      final sub = StringBuffer();
      if (l.splitterRatio.trim().isNotEmpty) sub.write(l.splitterRatio.trim());
      if (l.holes > 0) {
        if (sub.isNotEmpty) sub.write(' ');
        sub.write('${l.holes}孔');
        if (l.usedHoles > 0) sub.write('用${l.usedHoles}');
      }
      final cable = l.cableSpec.trim();
      final nd = TopoNode(
        src: l,
        level: _levelOf(lt.role),
        title: l.name.trim().isNotEmpty ? l.name.trim() : lt.name,
        sub: sub.toString(),
        cable: cable,
        cableCores: l.cableCores > 0 ? l.cableCores : parseCores(cable),
      );
      nodes.add(nd);
      byId[l.id] = nd;
    }
    if (nodes.isEmpty) {
      throw TopoException('该收藏没有可成拓扑的节点（需在地图上标记光交箱/分光器箱/分纤盒/ONU 等）');
    }

    final roots = <TopoNode>[];
    for (var i = 0; i < nodes.length; i++) {
      final cur = nodes[i];
      TopoNode? parent;
      if (cur.src.topoParentId.isNotEmpty) {
        final cand = byId[cur.src.topoParentId];
        if (cand != null &&
            !identical(cand, cur) &&
            !_isAncestor(cur, cand)) {
          parent = cand;
        }
      }
      if (parent == null) {
        for (var j = i - 1; j >= 0; j--) {
          if (nodes[j].level < cur.level) {
            parent = nodes[j];
            break;
          }
        }
      }
      if (parent != null && !_isDescendant(parent, cur)) {
        cur.parent = parent;
        parent.children.add(cur);
        continue;
      }
      roots.add(cur);
    }
    return roots;
  }

  static bool _isAncestor(TopoNode n, TopoNode cand) {
    for (var p = n.parent; p != null; p = p.parent) {
      if (identical(p, cand)) return true;
    }
    return false;
  }

  static bool _isDescendant(TopoNode n, TopoNode child) {
    for (final c in n.children) {
      if (identical(c, child) || _isDescendant(c, child)) return true;
    }
    return false;
  }

  /// 收集树的全部节点（先序）。
  static List<TopoNode> flatten(List<TopoNode> roots) {
    final out = <TopoNode>[];
    for (final r in roots) {
      _flatten(r, out);
    }
    return out;
  }

  static void _flatten(TopoNode n, List<TopoNode> out) {
    out.add(n);
    for (final c in n.children) {
      _flatten(c, out);
    }
  }

  /// 与地图一致的编号：有名称用名称，无名称按类型自动编号。
  static void assignTitles(List<TopoNode> roots) {
    final counters = <String, int>{};
    for (final n in flatten(roots)) {
      var nm = n.src.name.trim();
      if (nm.isEmpty) {
        final pfx = topoPrefix(n.src.typeId);
        final k = (counters[pfx] ?? 0) + 1;
        counters[pfx] = k;
        nm = '$pfx-$k';
      }
      n.title = nm;
    }
  }

  static String topoPrefix(String typeId) {
    switch (typeId) {
      case 'crossbox':
        return '光交';
      case 'splitterbox':
        return '分光箱';
      case 'fiberbox':
        return '分纤盒';
      case 'onubox':
        return 'ONU';
      case 'room':
        return '机房';
      case 'bts':
        return '基站';
      case 'riser':
        return '引上';
      default:
        return '节点';
    }
  }
}

/// LabelType 的拓扑前缀引用（避免循环依赖的便捷导出）。
String topoPrefixOf(LabelType lt) => Topology.topoPrefix(lt.id);
