import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../geo/geo_util.dart';
import '../../models/map_label.dart';
import '../../state/app_state.dart';
import '../dialogs.dart';
import '../../ui/design_tokens.dart';

/// 桌面地图右键菜单（架构文档 §3.3 / T12）。
///
/// 由 `MapCanvas.onSecondaryTap` 回调 → 本函数。命中判定分三态：
/// - **点**：草稿点优先、其次可见收藏点（地理近邻命中，容差随缩放自适应）；
/// - **线段**：杆路/收藏折线的某一段（点到线段的地面距离命中）；
/// - **空白**：以上都不命中。
///
/// 用 Flutter 原生 `showMenu`（零依赖）在鼠标位置弹出对应菜单。
///
/// [point] 为 flutter_map 传入的**显示坐标**（与 `MapOptions.onTap` 一致）；
/// 内部换算为 WGS84 后再做业务操作。
Future<void> showMapContextMenu(
  BuildContext context,
  AppState st, {
  required Offset globalPosition,
  required LatLng point,
  required MapController controller,
  VoidCallback? onLocate,
}) async {
  final hit = _hitTest(st, controller, point);

  final items = <PopupMenuEntry<String>>[];
  if (hit.isPoint) {
    final draft = hit.sourceCid.isEmpty;
    items.addAll([
      PopupMenuItem<String>(value: 'edit', child: _mi(Icons.edit, '编辑属性')),
    ]);
    if (draft) {
      items.addAll([
        PopupMenuItem<String>(
            value: 'branch', child: _mi(Icons.call_split, '从此点续画分支')),
        PopupMenuItem<String>(
            value: 'drag', child: _mi(Icons.open_with, '拖动点位')),
        PopupMenuItem<String>(
            value: 'break_chain',
            child: _mi(Icons.link_off, '断开续画（下一点另起）')),
      ]);
    }
    items.addAll([
      PopupMenuItem<String>(
          value: 'copy_coord', child: _mi(Icons.copy, '复制坐标')),
      PopupMenuDivider(),
      if (draft)
        PopupMenuItem<String>(
            value: 'del_chain',
            child: _mi(Icons.clear_all, '删除整条连线', red: true)),
      PopupMenuItem<String>(
          value: 'del_point', child: _mi(Icons.delete_outline, '删除点', red: true)),
    ]);
  } else if (hit.isSeg) {
    items.addAll([
      PopupMenuItem<String>(
          value: 'seg_kind', child: _mi(Icons.timeline, '设置敷设方式')),
      PopupMenuItem<String>(
          value: 'seg_cable', child: _mi(Icons.cable, '设置光缆型号')),
      PopupMenuItem<String>(
          value: 'seg_slack', child: _mi(Icons.linear_scale, '设置盘留')),
      PopupMenuItem<String>(
          value: 'seg_copy', child: _mi(Icons.copy, '复制段长')),
      PopupMenuDivider(),
      PopupMenuItem<String>(
          value: 'seg_del',
          child: _mi(Icons.delete_outline, '删除该段（删终点）', red: true)),
    ]);
  } else {
    items.addAll([
      PopupMenuItem<String>(value: 'add', child: _mi(Icons.add_location_alt, '在此打点')),
      PopupMenuItem<String>(
          value: 'paste_coord', child: _mi(Icons.paste, '粘贴坐标点')),
      PopupMenuItem<String>(
          value: 'import_file', child: _mi(Icons.file_open, '导入文件到此')),
    ]);
    if (st.hasFix) {
      items.add(PopupMenuItem<String>(
          value: 'locate', child: _mi(Icons.my_location, '回到当前位置')));
    }
  }

  final picked = await showMenu<String>(
    context: context,
    color: kPanelBg,
    position: RelativeRect.fromLTRB(
        globalPosition.dx, globalPosition.dy, globalPosition.dx, globalPosition.dy),
    items: items,
  );
  if (picked == null || !context.mounted) return;

  switch (picked) {
    case 'edit':
      await showLabelProperties(context, st, hit.label!,
          sourceCid: hit.sourceCid,
          title: hit.label!.name.trim().isNotEmpty
              ? hit.label!.name.trim()
              : hit.label!.type.name);
      break;
    case 'branch':
      st.setMode(AppMode.edit);
      st.startRouteFrom(hit.label!);
      toast(context,
          '已从「${_nm(hit.label!)}」开始新分支杆路，继续点地图绘制');
      break;
    case 'break_chain':
      st.breakChain();
      toast(context, '已断开续画：下一点将另起新线，不接任何已有杆路');
      break;
    case 'drag':
      st.draggingLabelId = hit.label!.id;
      st.refreshUi();
      toast(context, '拖动模式：在地图上点一下，把「${_nm(hit.label!)}」移到那里');
      break;
    case 'copy_coord':
      _copy(context, _coord(st, hit.label!));
      break;
    case 'del_chain':
      final n0 = st.deleteChain(hit.label!);
      if (n0 > 0) {
        toast(context, '已删除整条连线（$n0 个点），Ctrl+Z 可整条还原');
      }
      break;
    case 'del_point':
      if (hit.sourceCid.isEmpty) {
        st.removeLabel(hit.label!);
      } else {
        await st.removeOverlayLabel(hit.sourceCid, hit.label!);
      }
      break;
    case 'seg_kind':
      await _editSegKind(context, st, hit.seg!);
      break;
    case 'seg_cable':
      await _editSegText(context, st, hit.seg!, cable: true);
      break;
    case 'seg_slack':
      await _editSegText(context, st, hit.seg!, cable: false);
      break;
    case 'seg_copy':
      final d = GeoUtil.haversine(hit.seg!.a.lat, hit.seg!.a.lon,
          hit.seg!.b.lat, hit.seg!.b.lon);
      _copy(context, GeoUtil.fmtDist(d));
      break;
    case 'seg_del':
      await _deleteSegPoint(context, st, hit.seg!);
      break;
    case 'add':
      st.setMode(AppMode.edit);
      st.addLabelAtDisp(point.latitude, point.longitude);
      break;
    case 'paste_coord':
      await _pasteCoord(context, st);
      break;
    case 'import_file':
      await showKmlImportDialog(context, st);
      break;
    case 'locate':
      onLocate?.call();
      break;
  }
}

// ================= 命中判定 =================

class _Seg {
  final MapLabel a;
  final MapLabel b;
  final bool isDraft;
  final String cid;
  const _Seg(this.a, this.b, this.isDraft, this.cid);
}

class _Hit {
  final MapLabel? label;
  final String sourceCid;
  final _Seg? seg;
  const _Hit.point(this.label, this.sourceCid) : seg = null;
  const _Hit.seg(this.seg) : label = null, sourceCid = '';
  const _Hit.blank() : label = null, sourceCid = '', seg = null;
  bool get isPoint => label != null;
  bool get isSeg => seg != null;
}

_Hit _hitTest(AppState st, MapController controller, LatLng point) {
  final zoom = controller.camera.zoom;

  // ① 点命中：草稿 → 可见收藏。
  final draft = _hitPoint(st, st.labels, point, zoom);
  if (draft != null) return _Hit.point(draft, '');
  for (final cid in st.visibleCids) {
    final list = st.overlayLabels[cid];
    if (list == null || list.isEmpty) continue;
    final hit = _hitPoint(st, list, point, zoom);
    if (hit != null) return _Hit.point(hit, cid);
  }

  // ② 线段命中：草稿链 → 可见收藏链。
  final seg = _hitSegment(st, controller, point);
  if (seg != null) return _Hit.seg(seg);

  // ③ 空白。
  return const _Hit.blank();
}

MapLabel? _hitPoint(
    AppState st, List<MapLabel> list, LatLng point, double zoom) {
  final mpp = GeoUtil.metersPerPixel(
      st.toDisplay(point.latitude, point.longitude)[0], zoom);
  var best = 35.0 * mpp;
  if (best > 50) best = 50;
  if (best < 3) best = 3;
  MapLabel? hit;
  for (final l in list) {
    final d = st.toDisplay(l.lat, l.lon);
    final dist =
        GeoUtil.haversine(d[0], d[1], point.latitude, point.longitude);
    if (dist < best) {
      best = dist;
      hit = l;
    }
  }
  return hit;
}

_Seg? _hitSegment(AppState st, MapController controller, LatLng point) {
  final mpp = GeoUtil.metersPerPixel(point.latitude, controller.camera.zoom);
  final tol = math.max(6.0, 12.0 * mpp); // 地面米容差

  _Seg? best;
  var bestDist = tol;

  void scan(List<MapLabel> pts, bool isDraft, String cid) {
    for (final chain in buildLabelChains(pts)) {
      for (var i = 1; i < chain.length; i++) {
        final a = chain[i - 1];
        final b = chain[i];
        final da = st.toDisplay(a.lat, a.lon);
        final db = st.toDisplay(b.lat, b.lon);
        final d = _distToSegMeters(point.latitude, point.longitude, da[0],
            da[1], db[0], db[1], point.latitude);
        if (d < bestDist) {
          bestDist = d;
          best = _Seg(a, b, isDraft, cid);
        }
      }
    }
  }

  scan(st.labels, true, '');
  for (final e in st.overlayLabels.entries) {
    if (st.visibleCids.contains(e.key)) scan(e.value, false, e.key);
  }
  return best;
}

/// 点到线段的地面距离（米）。用等距圆柱近似做局部平面投影：
/// 纬度方向 111320 m/deg，经度方向按 [refLat] 缩放。
double _distToSegMeters(double pLat, double pLon, double aLat, double aLon,
    double bLat, double bLon, double refLat) {
  const mPerDegLat = 111320.0;
  final mPerDegLon = 111320.0 * math.cos(refLat * math.pi / 180.0);
  final px = pLon * mPerDegLon;
  final py = pLat * mPerDegLat;
  final ax = aLon * mPerDegLon;
  final ay = aLat * mPerDegLat;
  final bx = bLon * mPerDegLon;
  final by = bLat * mPerDegLat;

  final dx = bx - ax;
  final dy = by - ay;
  final len2 = dx * dx + dy * dy;
  if (len2 <= 1e-9) {
    return math.sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
  }
  var t = ((px - ax) * dx + (py - ay) * dy) / len2;
  if (t < 0) t = 0;
  if (t > 1) t = 1;
  final cx = ax + t * dx;
  final cy = ay + t * dy;
  return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
}

// ================= 线段编辑 =================

Future<void> _editSegKind(BuildContext context, AppState st, _Seg seg) async {
  var kind = seg.b.segKind;
  await showDarkDialog(
    context,
    title: '本段敷设方式',
    content: StatefulBuilder(
      builder: (ctx, setSt) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final kv in const {
            0: '默认',
            1: '架空',
            2: '埋地',
            3: '管道',
          }.entries)
            RadioListTile<int>(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(kv.value,
                  style: const TextStyle(color: kTextMain, fontSize: 13)),
              value: kv.key,
              groupValue: kind,
              activeColor: kAccent,
              onChanged: (v) => setSt(() => kind = v ?? 0),
            ),
        ],
      ),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('应用', () async {
        Navigator.pop(context);
        if (seg.isDraft) st.pushUndoSnapshot();
        seg.b.segKind = kind;
        await _saveSeg(st, seg);
        if (context.mounted) toast(context, '已设置该段敷设方式');
      }),
    ],
  );
}

Future<void> _editSegText(BuildContext context, AppState st, _Seg seg,
    {required bool cable}) async {
  final ctl = TextEditingController(
      text: cable ? seg.b.segCable : _fmtSlack(seg.b.slackM));
  await showDarkDialog(
    context,
    title: cable ? '本段光缆型号' : '本段接头盘留（米）',
    content: TextField(
      controller: ctl,
      autofocus: true,
      keyboardType:
          cable ? TextInputType.text : const TextInputType.numberWithOptions(decimal: true),
      style: const TextStyle(color: kTextMain, fontSize: 14),
      decoration: dec(cable ? '如 48芯GYTS' : '如 1.5（结算用量=丈量+盘留）'),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('保存', () async {
        Navigator.pop(context);
        if (seg.isDraft) st.pushUndoSnapshot();
        if (cable) {
          seg.b.segCable = ctl.text.trim();
        } else {
          final v = double.tryParse(ctl.text.trim());
          seg.b.slackM = (v != null && v > 0) ? v : 0;
        }
        await _saveSeg(st, seg);
        if (context.mounted) toast(context, '已保存');
      }),
    ],
  );
}

Future<void> _deleteSegPoint(
    BuildContext context, AppState st, _Seg seg) async {
  await showDarkDialog(
    context,
    title: '删除该段',
    content: Text('确定删除该段终点「${_nm(seg.b)}」？相邻段会重新连接。',
        style: const TextStyle(color: kTextMain, fontSize: 13)),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('删除', () async {
        Navigator.pop(context);
        if (seg.isDraft) {
          st.removeLabel(seg.b);
        } else {
          await st.removeOverlayLabel(seg.cid, seg.b);
        }
      }, color: TokC.danger),
    ],
  );
}

Future<void> _saveSeg(AppState st, _Seg seg) async {
  if (seg.isDraft) {
    st.updateLabel(seg.b);
  } else {
    await st.updateOverlayLabel(seg.cid, seg.b);
  }
}

// ================= 空白菜单动作 =================

Future<void> _pasteCoord(BuildContext context, AppState st) async {
  final data = await Clipboard.getData('text/plain');
  final text = data?.text?.trim() ?? '';
  if (text.isEmpty) {
    if (context.mounted) toast(context, '剪贴板为空');
    return;
  }
  final coord = GeoUtil.parseCoordInput(text);
  if (coord == null) {
    if (context.mounted) toast(context, '无法识别坐标（支持「32.07,114.05」或度分秒）');
    return;
  }
  st.setMode(AppMode.edit);
  st.addLabelAtWgs(coord[0], coord[1]);
  if (context.mounted) toast(context, '已按剪贴板坐标打点');
}

// ================= 小工具 =================

String _nm(MapLabel l) => l.name.trim().isNotEmpty ? l.name.trim() : l.type.name;

String _coord(AppState st, MapLabel l) {
  final d = st.toDisplay(l.lat, l.lon);
  return GeoUtil.formatCoord(d[0], d[1], st.coordFmt);
}

String _fmtSlack(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

void _copy(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  toast(context, '已复制：$text');
}

Widget _mi(IconData icon, String text, {bool red = false}) => Row(
      children: [
        Icon(icon, size: 16, color: red ? TokC.danger : kTextSub),
        const SizedBox(width: 10),
        Text(text,
            style: TextStyle(
                color: red ? TokC.danger : kTextMain,
                fontSize: 13)),
      ],
    );
