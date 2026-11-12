import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../geo/geo_util.dart';
import '../../models/map_label.dart';
import '../../services/platform_caps.dart';
import '../../services/tile_cache.dart';
import '../../state/app_state.dart';
import '../dialogs.dart';
import '../label_marker.dart';
import '../../ui/design_tokens.dart';

/// 共享地图核心（从 `home_page` 抽出，供移动壳 / 桌面壳复用）。
///
/// 只负责「地图 + 图层 + 交互」这一块，**不含**任何平台专属 Chrome：
/// - 底图 / 叠加图瓦片层、杆路 / 拓扑 / 测量 / 轨迹折线、测面积多边形；
/// - 段距离文字叠加层（每帧按屏幕坐标绘制，与线平行）；
/// - 用户位置精度圈 + 航向箭头；
/// - 框选覆盖层（`boxSelect` 模式）；
/// - 点按 / 长按 / 右键的地图交互分发与命中测试。
///
/// 业务符号 `MarkerLayer`（草稿点、可见收藏、搜索临时标记等）由**调用方**通过
/// [extraLayers] 注入（两套壳的 Chrome 不同，符号层从各自壳注入，逻辑复用
/// [buildBusinessMarkers]）。瓦片供给器由壳持有并传入，便于壳做离线下载 / 缓存清理。
class MapCanvas extends StatefulWidget {
  const MapCanvas({
    super.key,
    required this.st,
    required this.controller,
    required this.baseProvider,
    this.overlayProvider,
    this.extraLayers = const <Widget>[],
    this.heading = 0,
    this.hasHeading = false,
    this.openDetailOnTap = true,
    this.onSelect,
    this.interactionFlags,
    this.onMapReady,
    this.onCameraChanged,
    this.onSecondaryTap,
    this.onPointerGeo,
  });

  final AppState st;

  /// 外部持有的地图控制器（壳用它做定位/跳转/缩放）。
  final MapController controller;

  /// 底图瓦片供给器（壳持有，便于清缓存后让 generation 失效）。
  final CacheTileProvider baseProvider;

  /// 叠加图瓦片供给器（无叠加层时为 null）。
  final CacheTileProvider? overlayProvider;

  /// 壳注入的额外 FlutterMap 子层（业务符号 / 搜索临时标记等），
  /// 插在折线/多边形之后、段文字叠加层之前。
  final List<Widget> extraLayers;

  /// 航向（度）与是否可信：驱动用户位置箭头；桌面端无罗盘时传 0 / false。
  final double heading;
  final bool hasHeading;

  /// 点选时是否**直接**弹详情对话框。
  /// 移动端 true（现状）；桌面端 false——改由右栏展示所选点属性。
  final bool openDetailOnTap;

  /// 点选回调（桌面右栏用）：命中点或空白（null）。移动端可不传。
  final void Function(MapLabel? label, String sourceCid)? onSelect;

  /// 交互开关（flutter_map `InteractiveFlag`）；缺省 = 移动端现有口径。
  final int? interactionFlags;

  /// 地图首帧就绪回调（壳据此镜像 `mapReady`）。
  final VoidCallback? onMapReady;

  /// 相机变化回调（壳据此刷新罗盘/坐标等）。
  final void Function(MapCamera camera)? onCameraChanged;

  /// 右键（`MapOptions.onSecondaryTap`）回调，用于桌面右键菜单。
  final void Function(TapPosition tap, LatLng point)? onSecondaryTap;

  /// 鼠标悬停位置回调（桌面）：回传 WGS-84 经纬度；移出地图时回传 (null, null)。
  /// 供状态栏显示「鼠标所在经纬度」（奥维桌面版的状态栏口径）。
  final void Function(double? lat, double? lon)? onPointerGeo;

  @override
  State<MapCanvas> createState() => _MapCanvasState();
}

class _MapCanvasState extends State<MapCanvas> {
  bool _mapReady = false;
  double _infoZoom = 5;

  /// 最近一次相机快照（由 `onPositionChanged` / `onMapReady` 回传）。
  ///
  /// 切勿在 `build()` 里直接读 `_mc.camera`：该 getter 在 FlutterMap 首帧渲染前
  /// 会抛异常（`value.camera ?? throw`），首帧必崩（ErrorWidget，地图渲染不出来）。
  MapCamera? _cam;
  Timer? _camSaveTimer;

  AppState get st => widget.st;
  MapController get _mc => widget.controller;

  @override
  void dispose() {
    _camSaveTimer?.cancel();
    super.dispose();
  }

  // ================= 地图事件 =================

  void _onPositionChanged(MapCamera cam, bool hasGesture) {
    _cam = cam;
    _infoZoom = cam.zoom;
    final w = st.toWgs(cam.center.latitude, cam.center.longitude);
    if (hasGesture && st.followUser) {
      st.setFollow(false);
    }
    _camSaveTimer?.cancel();
    _camSaveTimer = Timer(const Duration(milliseconds: 700), () {
      st.saveCamera(w[0], w[1], cam.zoom);
    });
    widget.onCameraChanged?.call(cam);
    if (mounted) setState(() {});
  }

  double _pzZoom = 0;

  /// 触控板双指平移/捏合：pan 像素 → 相机平移；scale → 级别增量。
  /// 平移以「内容跟手」方向移动（中心点向手指反方向走）。
  void _onTrackpad(PointerPanZoomUpdateEvent e) {
    if (!_mapReady) return;
    final cam = _mc.camera;
    final pan = e.localPanDelta;
    if (pan.distanceSquared > 0) {
      final mpp =
          GeoUtil.metersPerPixel(cam.center.latitude, cam.zoom);
      final dLat = pan.dy * mpp / 111320.0;
      final dLon = pan.dx * mpp /
          (111320.0 * math.cos(cam.center.latitude * math.pi / 180.0));
      final nl = (cam.center.latitude - dLat).clamp(-85.0, 85.0);
      _mc.move(LatLng(nl, cam.center.longitude - dLon), cam.zoom);
    }
    final z = _pzZoom + (math.log(e.scale <= 0 ? 1 : e.scale) / math.ln2);
    if ((z - cam.zoom).abs() > 0.001 && z >= 3 && z <= 21.5) {
      _mc.move(cam.center, z);
    }
  }

  void _onTap(TapPosition tap, LatLng point) {
    // 标记模式最高优先（任何模式下点地图都只落独立标记，自动存根目录「标记」）。
    if (st.markMode) {
      final w = st.toWgs(point.latitude, point.longitude);
      unawaited(st.addMarkAtWgs(w[0], w[1]).then((_) {
        if (context.mounted) toast(context, '已标记并自动保存到收藏夹根目录');
      }));
      return;
    }
    switch (st.mode) {
      case AppMode.edit:
        // 待定编辑优先处理：拖动点位（奥维顶点编辑式）
        if (st.draggingLabelId != null) {
          final l = st.labelById(st.draggingLabelId!);
          st.draggingLabelId = null;
          if (l != null) {
            final w = st.toWgs(point.latitude, point.longitude);
            st.moveLabelToWgs(l, w[0], w[1]);
            toast(context,
                '已移动「${l.name.isEmpty ? l.type.name : l.name}」，相邻段距自动重算');
          }
          return;
        }
        final l = st.addLabelAtDisp(point.latitude, point.longitude);
        widget.onSelect?.call(l, '');
        if (l.typeId == 'text') {
          // 文字符号必须先输入内容才有意义，保留提示框。
          showTextPrompt(context, st, l);
        }
        // 竣工模式不再逐点弹属性/段属性框（用户反馈「点击打点时属性对话框
        // 老蹦出来影响体验」）：连续打点是高频动作，弹窗打断节奏。补属性走
        // 右键「编辑属性」或右栏属性面板，语义不变、入口不丢。
        break;
      case AppMode.topoLink:
        final target = _hitTestGeo(
            st.topoColl.where((l) => l.type.isTopoLinkable).toList(), point);
        if (target == null) return;
        final msg = st.topoTap(target);
        if (msg.isNotEmpty) toast(context, msg);
        if (target.topoParentId.isNotEmpty && msg.startsWith('已连接')) {
          showCableDialog(context, st, target);
        }
        break;
      case AppMode.measureDist:
      case AppMode.measureArea:
        st.addMeasurePoint(point.latitude, point.longitude);
        break;
      case AppMode.boxSelect:
        // 框选由覆盖层 _MarqueeLayer 处理；地图点击不落点。
        break;
      case AppMode.view:
        // 普通模式点选：先草稿、再可见收藏工程。
        // 移动端 true 时点中即弹详情；桌面端 false 时仅回调选中（右栏展示）。
        final hit = _hitTestAny(point);
        widget.onSelect?.call(hit?.$1, hit?.$2 ?? '');
        if (hit != null && widget.openDetailOnTap) {
          showLabelProperties(context, st, hit.$1,
              sourceCid: hit.$2,
              title: hit.$1.name.trim().isNotEmpty
                  ? hit.$1.name.trim()
                  : hit.$1.type.name);
        }
        break;
    }
  }

  void _onLongPress(TapPosition tap, LatLng point) {
    if (st.mode == AppMode.edit) {
      final near = _hitTestGeo(st.labels, point);
      if (near != null) showContinueRouteDialog(context, st, near);
      return;
    }
    if (st.mode == AppMode.view) {
      // 长按点到已画点位：同样直接编辑（比短按更不易误触），覆盖草稿+可见收藏
      final near = _hitTestAny(point);
      if (near != null) {
        showLabelProperties(context, st, near.$1,
            sourceCid: near.$2,
            title: near.$1.name.trim().isNotEmpty
                ? near.$1.name.trim()
                : near.$1.type.name);
        return;
      }
      showContextCard(context, st, point.latitude, point.longitude);
    }
  }

  /// 地理近邻命中：点击经纬度与各点直接算距离，容差 = 35px 换算的地面距离
  /// （限制在 3~50 米）。不经过屏幕坐标换算——地图旋转、刘海安全区、
  /// 设备像素比都不会影响，比旧的屏幕像素命中法可靠。
  MapLabel? _hitTestGeo(List<MapLabel> list, LatLng point) {
    final mpp = GeoUtil.metersPerPixel(
        st.toDisplay(point.latitude, point.longitude)[0], _mc.camera.zoom);
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

  /// 命中任意可见点：先草稿、再可见收藏工程。返回 (label, 来源收藏id，空串=草稿)。
  (MapLabel, String)? _hitTestAny(LatLng point) {
    final draft = _hitTestGeo(st.labels, point);
    if (draft != null) return (draft, '');
    for (final cid in st.visibleCids) {
      final list = st.overlayLabels[cid];
      if (list == null || list.isEmpty) continue;
      final hit = _hitTestGeo(list, point);
      if (hit != null) return (hit, cid);
    }
    return null;
  }

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    // 可空：首帧尚未就绪时为 null；不得直接读 _mc.camera（首帧会抛异常）。
    final MapCamera? cam = _cam;
    final ovl = st.currentOverlay();

    final userDisp = (st.curLat != null && st.curLon != null)
        ? st.toDisplay(st.curLat!, st.curLon!)
        : null;
    final zoomForAcc = _mapReady ? (cam?.zoom ?? _infoZoom) : _infoZoom;

    final polylines = <Polyline>[
      ...buildSegLines(st, st.labels, isDraft: true),
      for (final e in st.overlayLabels.entries)
        if (st.visibleCids.contains(e.key)) ...buildSegLines(st, e.value),
      if (st.mode == AppMode.topoLink) ...buildTopoLines(st),
      if (st.measurePts.length >= 2)
        Polyline(
          points: [
            for (final m in st.measurePts)
              LatLng(st.toDisplay(m.lat, m.lon)[0],
                  st.toDisplay(m.lat, m.lon)[1]),
          ],
          strokeWidth: 2.6,
          color: const Color(0xFF00BCD4),
        ),
      if (st.recordPts.length >= 2)
        Polyline(
          points: [
            for (final m in st.recordPts)
              LatLng(st.toDisplay(m.lat, m.lon)[0],
                  st.toDisplay(m.lat, m.lon)[1]),
          ],
          strokeWidth: 3,
          color: const Color(0xFFFFC107),
        ),
    ];

    // 交互开关缺省值按平台给：
    //
    // - 桌面：必须有 `scrollWheelZoom`，否则鼠标滚轮完全不能缩放（本壳此前把它漏了，
    //   是「地图缩放不管用」的根因之一）；不含 `rotate` —— 桌面出图要求正北朝上，
    //   且旋转手势会与右键菜单/框选抢事件；不含 `doubleTapZoom` —— 开了它，
    //   每次单击落点都要等 250ms 双击判定窗口（详见
    //   [defaultFlagsForCurrentPlatform] 的「250ms 代价」）。
    // - 移动：保持原口径（双指缩放 + 旋转）。
    final int flags = widget.interactionFlags ?? defaultFlagsForCurrentPlatform();

    return Listener(
      // macOS 触控板（用户反馈「触控板功能全部失效」）：Flutter 把 trackpad
      // 双指平移/捏合发成 PointerPanZoom*，而 flutter_map 的 scrollWheelZoom
      // 只认 PointerScrollEvent → 触控板无人响应。在此自实现平移与捏合缩放。
      onPointerPanZoomStart: (e) {
        _pzZoom = _mc.camera.zoom;
      },
      onPointerPanZoomUpdate: _onTrackpad,
      child: Stack(
      children: [
        FlutterMap(
          mapController: _mc,
          options: MapOptions(
            initialCenter: LatLng(st.toDisplay(st.initLat, st.initLon)[0],
                st.toDisplay(st.initLat, st.initLon)[1]),
            initialZoom: st.initZoom,
            minZoom: 3,
            maxZoom: 21.5,
            backgroundColor: TokC.panelSolid,
            onPositionChanged: _onPositionChanged,
            onMapReady: () {
              _mapReady = true;
              _onPositionChanged(_mc.camera, false);
              widget.onMapReady?.call();
              if (mounted) setState(() {});
            },
            onTap: _onTap,
            onLongPress: _onLongPress,
            onSecondaryTap: widget.onSecondaryTap,
            onPointerHover: (e, point) {
              // 悬停点位的坐标系与其它回调一致（显示基准）；交回调用方前转成 WGS-84。
              final w = st.toWgs(point.latitude, point.longitude);
              widget.onPointerGeo?.call(w[0], w[1]);
            },
            interactionOptions: InteractionOptions(
              flags: flags,
              // ⚠️ 桌面必须关掉「按住 Ctrl 移动鼠标 = 旋转地图」：
              // flutter_map 的 `CursorKeyboardRotationOptions` 默认把 Control 键当旋转触发键，
              // 于是 Ctrl+Z / Ctrl+S / Ctrl+E 等桌面快捷键在鼠标移动时会顺带把地图转掉。
              // 移动端无此冲突，保持默认。
              cursorKeyboardRotationOptions: PlatformCaps.isDesktop
                  ? CursorKeyboardRotationOptions.disabled()
                  : const CursorKeyboardRotationOptions(),
            ),
          ),
          children: [
            TileLayer(
              key: ValueKey(
                  'base-${st.curSource.id}-${widget.baseProvider.generation}'),
              tileProvider: widget.baseProvider,
              maxNativeZoom: st.curSource.maxZoom,
              maxZoom: 21.5,
              errorImage: MemoryImage(Uint8List.fromList(kTransparentPng)),
            ),
            if (widget.overlayProvider != null && ovl != null)
              TileLayer(
                key: ValueKey(
                    'ovl-${st.overlayId}-${widget.overlayProvider!.generation}'),
                tileProvider: widget.overlayProvider!,
                maxNativeZoom: ovl.maxZoom,
                maxZoom: 21.5,
                errorImage: MemoryImage(Uint8List.fromList(kTransparentPng)),
              ),
            PolylineLayer(polylines: polylines),
            if (st.mode == AppMode.measureArea && st.measurePts.length >= 3)
              PolygonLayer(polygons: [
                Polygon(
                  points: [
                    for (final m in st.measurePts)
                      LatLng(st.toDisplay(m.lat, m.lon)[0],
                          st.toDisplay(m.lat, m.lon)[1]),
                  ],
                  color: const Color(0x33AB47BC),
                  borderColor: const Color(0xFFAB47BC),
                  borderStrokeWidth: 1.5,
                ),
              ]),
            // 壳注入的业务符号 / 搜索临时标记等
            ...widget.extraLayers,
            // 段距离文字叠加层：每帧按屏幕坐标绘制，永远与线平行
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: SegTextPainter(
                      _mapReady && cam != null
                          ? collectSegTexts(st, cam)
                          : const []),
                ),
              ),
            ),
            // 用户位置
            if (userDisp != null)
              MarkerLayer(markers: [
                Marker(
                  point: LatLng(userDisp[0], userDisp[1]),
                  width: (st.curAcc ?? 20) *
                      2 *
                      (1.0 / GeoUtil.metersPerPixel(userDisp[0], zoomForAcc)),
                  height: (st.curAcc ?? 20) *
                      2 *
                      (1.0 / GeoUtil.metersPerPixel(userDisp[0], zoomForAcc)),
                  alignment: Alignment.center,
                  child: CustomPaint(
                      painter: const AccuracyCirclePainter(),
                      child: const SizedBox.expand()),
                ),
                Marker(
                  point: LatLng(userDisp[0], userDisp[1]),
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  child: Transform.rotate(
                    angle: deg2rad(widget.heading - (cam?.rotation ?? 0)),
                    child: const CustomPaint(
                      size: Size(24, 24),
                      painter: UserArrowPainter(),
                    ),
                  ),
                ),
              ]),
          ],
        ),

        // ---- 框选覆盖层（仅 boxSelect 模式）：拖出矩形选择草稿点 ----
        if (st.mode == AppMode.boxSelect)
          Positioned.fill(
            child: _MarqueeLayer(
              onDone: (rect) {
                final c = _mc.camera;
                final a = c.offsetToCrs(rect.topLeft);
                final b = c.offsetToCrs(rect.bottomRight);
                final minLat = math.min(a.latitude, b.latitude);
                final maxLat = math.max(a.latitude, b.latitude);
                final minLon = math.min(a.longitude, b.longitude);
                final maxLon = math.max(a.longitude, b.longitude);
                st.selectInDisplayBounds(minLat, minLon, maxLat, maxLon);
                toast(context, '已选 ${st.selectedIds.length} 点');
              },
            ),
          ),
      ],
      ),
    );
  }
}

// ================= 交互开关（两套壳共用一份口径） =================

/// 当前平台的默认地图交互开关。
///
/// **桌面与移动的差别是刻意的，不是漏配**：
///
/// | 能力 | 移动 | 桌面 | 原因 |
/// |---|---|---|---|
/// | `drag` 平移 | ✅ | ✅ | 桌面为左键拖拽 |
/// | `scrollWheelZoom` 滚轮缩放 | — | ✅ | **桌面缩放的主力入口**，缺了滚轮就没反应 |
/// | `doubleTapZoom` 双击放大 | ✅ | — | 见下方「500ms 代价」说明 |
/// | `pinchZoom` 双指缩放 | ✅ | — | 桌面无多指；触控板双指滚动已由 `scrollWheelZoom` 覆盖 |
/// | `rotate` 旋转 | ✅ | — | 桌面出图要求正北朝上，且旋转会抢右键/框选事件 |
/// | `flingAnimation` 惯性滑动 | — | — | 测绘场景要「停手即停」，惯性会让定点对不准 |
///
/// ### 桌面为何**不**开 `doubleTapZoom`：单击会被延迟 250ms
///
/// flutter_map 的点击判定在 `PositionedTapDetector2`（`gestures/
/// positioned_tap_detector_2.dart`）里，它把「是否为双击」与「单击」放在同一个
/// 判定流程上：
///
/// ```dart
/// static const _defaultDelay = Duration(milliseconds: 250); // 双击判定窗口
/// ...
/// if (widget.onDoubleTap == null) {
///   _postCallback(pending, widget.onTap);   // 立刻回调，零延迟
/// } else {
///   _sink.add(pending);                     // 进流，等 250ms 超时才算「单击」
/// }
/// ```
///
/// 而 `MapInteractiveViewer` 只在 `flags` 含 `doubleTapZoom` 时才会给
/// `onDoubleTap` 传值（`InteractiveFlag.hasDoubleTapZoom(flags) ? ... : null`）。
/// 结论：**开双击缩放 = 每一次单击落点都要等 250ms 才发生**。
///
/// 对本应用（现场打点，一条线要点几十上百下）这个延迟是硬伤，因此桌面端
/// 主动关闭双击缩放，改用「滚轮 / Ctrl± / 工具栏 / 方向键」四条缩放通道。
/// 移动端维持原有口径不动（改它会牵动既有手感与回归）。
///
/// ### 与奥维桌面版的有意差异
///
/// 奥维用「双击结束折线绘制」，本应用不采用：我们**没有**连续画线状态机 ——
/// 每次单击独立落点，链是由点位自动串起来的，结束动作交给 `Esc`（以及各模式
/// 提示栏里的「完成」按钮）。这样既省掉点击延迟，也不会和落点抢同一次手势。
///
/// 方向键平移由 flutter_map 的 `KeyboardOptions` 默认提供（`enableArrowKeysPanning`），
/// 与奥维桌面版一致，无需额外配置。
int defaultFlagsForCurrentPlatform() {
  if (PlatformCaps.isDesktop) {
    return InteractiveFlag.drag | InteractiveFlag.scrollWheelZoom;
  }
  return InteractiveFlag.pinchZoom |
      InteractiveFlag.drag |
      InteractiveFlag.doubleTapZoom |
      InteractiveFlag.rotate;
}

// ================= 共享图层构建（两套壳复用） =================

/// 杆路 / 收藏折线（统一链口径；箱体/文字不打断杆路，与导出一致）。
List<Polyline> buildSegLines(AppState st, List<MapLabel> pts,
    {bool isDraft = false}) {
  final lines = <Polyline>[];
  for (final chain in buildLabelChains(pts)) {
    for (var i = 1; i < chain.length; i++) {
      final a = chain[i - 1];
      final b = chain[i];
      Color color;
      double width = isDraft ? 3.0 : 2.4;
      bool dashed = false;
      if (a.typeId == 'area') {
        color = const Color(0xFFAB47BC);
      } else if (b.segKind == 1) {
        color = const Color(0xFFFF9800);
        dashed = true;
      } else if (b.segKind == 2) {
        color = const Color(0xFF43A047);
      } else if (b.segKind == 3) {
        color = const Color(0xFF1E88E5);
      } else if (!isDraft && (b.styleColor != 0 || b.styleWidth > 0)) {
        color = b.styleColor == 0
            ? const Color(0xFFFFC107)
            : Color(b.styleColor | 0xFF000000);
        if (b.styleWidth > 0) width = b.styleWidth;
      } else {
        color = isDraft ? const Color(0xFFFFC107) : const Color(0xFFFDD835);
      }
      final pa = st.toDisplay(a.lat, a.lon);
      final pb = st.toDisplay(b.lat, b.lon);
      if (dashed) {
        // 虚线：手工切段
        const n = 12;
        for (var k = 0; k < n; k++) {
          if (k % 2 == 1) continue;
          final t0 = k / n, t1 = (k + 1) / n;
          lines.add(Polyline(
            points: [
              LatLng(pa[0] + (pb[0] - pa[0]) * t0, pa[1] + (pb[1] - pa[1]) * t0),
              LatLng(pa[0] + (pb[0] - pa[0]) * t1, pa[1] + (pb[1] - pa[1]) * t1),
            ],
            strokeWidth: width,
            color: color,
          ));
        }
      } else {
        lines.add(Polyline(
          points: [LatLng(pa[0], pa[1]), LatLng(pb[0], pb[1])],
          strokeWidth: width,
          color: color,
        ));
      }
    }
  }
  return lines;
}

/// 拓扑父子连线。
List<Polyline> buildTopoLines(AppState st) {
  final byId = {for (final e in st.topoColl) e.id: e};
  return [
    for (final l in st.topoColl)
      if (l.topoParentId.isNotEmpty && byId.containsKey(l.topoParentId))
        () {
          final p = byId[l.topoParentId]!;
          final da = st.toDisplay(p.lat, p.lon);
          final db = st.toDisplay(l.lat, l.lon);
          return Polyline(
            points: [LatLng(da[0], da[1]), LatLng(db[0], db[1])],
            strokeWidth: 1.8,
            color: const Color(0xFFCE93D8),
          );
        }(),
  ];
}

/// 业务符号标记（可见收藏 → 草稿 → 拓扑选中 → 测量点）。供两套壳注入。
List<Marker> buildBusinessMarkers(AppState st, MapCamera cam,
    {required bool mapReady}) {
  final markers = <Marker>[];
  if (!mapReady) return markers;

  void addFor(MapLabel l,
      {bool selected = false, bool draft = false, bool batchSel = false}) {
    // 轨迹/无标签：不画符号，只保留连线与距离
    if (l.typeId == 'track' || l.typeId == 'none') return;
    final d = st.toDisplay(l.lat, l.lon);
    final skipName = cam.zoom < 14.5 && !draft;
    final child = LabelSymbol(
      label: skipName ? (l.clone()..name = '') : l,
      selected: selected || batchSel,
    );
    markers.add(Marker(
      point: LatLng(d[0], d[1]),
      width: LabelSymbol.symbolSize,
      height: LabelSymbol.symbolSize,
      alignment: Alignment.center,
      child: child,
    ));
  }

  // 可见收藏（底层）
  for (final entry in st.overlayLabels.entries) {
    if (!st.visibleCids.contains(entry.key)) continue;
    for (final l in entry.value) {
      addFor(l);
    }
  }
  // 草稿（批量选择集高亮）
  for (final l in st.labels) {
    addFor(l, draft: true, batchSel: st.selectedIds.contains(l.id));
  }
  // 拓扑选中高亮
  if (st.mode == AppMode.topoLink && st.topoSelId != null) {
    for (final l in st.topoColl) {
      if (l.id == st.topoSelId) addFor(l, selected: true);
    }
  }
  // 测量点
  for (var i = 0; i < st.measurePts.length; i++) {
    final l = st.measurePts[i];
    final d = st.toDisplay(l.lat, l.lon);
    markers.add(Marker(
      point: LatLng(d[0], d[1]),
      width: 40,
      height: 40,
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xFF00BCD4),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.6),
        ),
        child: Center(
          child: Text('${i + 1}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
        ),
      ),
    ));
  }

  return markers;
}

/// 收集段距离文字（屏幕坐标+屏幕角度），由叠加层每帧绘制，与线严格平行。
List<SegText> collectSegTexts(AppState st, MapCamera cam) {
  final out = <SegText>[];
  void addFor(List<MapLabel> pts, {required bool isDraft}) {
    if (cam.zoom < 13.5 && !isDraft) return;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i];
      if (a.lineGroupId.isEmpty) continue;
      var j = i + 1;
      while (j < pts.length && pts[j].lineGroupId != a.lineGroupId) {
        j++;
      }
      if (j >= pts.length) continue;
      final b = pts[j];
      final da = st.toDisplay(a.lat, a.lon);
      final db = st.toDisplay(b.lat, b.lon);
      final spa = cam.latLngToScreenOffset(LatLng(da[0], da[1]));
      final spb = cam.latLngToScreenOffset(LatLng(db[0], db[1]));
      final dx = spb.dx - spa.dx, dy = spb.dy - spa.dy;
      final pxDist = math.sqrt(dx * dx + dy * dy);
      if (pxDist < 30) continue;
      final dist = b.distanceM ?? GeoUtil.haversine(a.lat, a.lon, b.lat, b.lon);
      // 段标走 segTextFor（真源）：distLabel 未手填时，前缀**实时**取自本段敷设方式
      // （架空→架 / 埋地→埋 / 管道→管），退而用全局段标前缀。距离用 segDistText
      // 去掉整数的 ".0" 毛刺，与 DXF 标注、左侧段落表口径一致。
      final segText = GeoUtil.segTextFor(b, GeoUtil.segDistText(dist),
          prefix: st.segPrefix);
      if (segText.isEmpty) continue;
      var ang = math.atan2(dy, dx);
      if (ang > math.pi / 2 || ang < -math.pi / 2) ang += math.pi;
      out.add(SegText(
          Offset((spa.dx + spb.dx) / 2, (spa.dy + spb.dy) / 2), ang, segText));
    }
  }

  addFor(st.labels, isDraft: true);
  for (final entry in st.overlayLabels.entries) {
    if (st.visibleCids.contains(entry.key)) {
      addFor(entry.value, isDraft: false);
    }
  }
  // 测量线：相邻测量点也沿线标段长（与杆路段标注同风格）
  if (st.mode == AppMode.measureDist || st.mode == AppMode.measureArea) {
    for (var i = 1; i < st.measurePts.length; i++) {
      final a = st.measurePts[i - 1], b = st.measurePts[i];
      final da = st.toDisplay(a.lat, a.lon);
      final db = st.toDisplay(b.lat, b.lon);
      final spa = cam.latLngToScreenOffset(LatLng(da[0], da[1]));
      final spb = cam.latLngToScreenOffset(LatLng(db[0], db[1]));
      final dx = spb.dx - spa.dx, dy = spb.dy - spa.dy;
      final pxDist = math.sqrt(dx * dx + dy * dy);
      if (pxDist < 30) continue;
      final dist = GeoUtil.haversine(a.lat, a.lon, b.lat, b.lon);
      var ang = math.atan2(dy, dx);
      if (ang > math.pi / 2 || ang < -math.pi / 2) ang += math.pi;
      out.add(SegText(
          Offset((spa.dx + spb.dx) / 2, (spa.dy + spb.dy) / 2),
          ang,
          // 测量线没有敷设方式，只统一数字口径（去整数 ".0"）。
          GeoUtil.segDistText(dist)));
    }
  }
  return out;
}

/// 框选覆盖层：拖出矩形，结束后回调屏幕矩形（由调用方换算为经纬）。
class _MarqueeLayer extends StatefulWidget {
  final void Function(Rect rect) onDone;
  const _MarqueeLayer({required this.onDone});

  @override
  State<_MarqueeLayer> createState() => _MarqueeLayerState();
}

class _MarqueeLayerState extends State<_MarqueeLayer> {
  Offset? _start;
  Offset? _current;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (d) => setState(() {
        _start = d.localPosition;
        _current = d.localPosition;
      }),
      onPanUpdate: (d) => setState(() => _current = d.localPosition),
      onPanEnd: (_) {
        final s = _start, c = _current;
        setState(() {
          _start = null;
          _current = null;
        });
        if (s != null && c != null) widget.onDone(Rect.fromPoints(s, c));
      },
      child: CustomPaint(
        painter: _MarqueePainter(_start, _current),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _MarqueePainter extends CustomPainter {
  final Offset? start;
  final Offset? current;
  _MarqueePainter(this.start, this.current);

  @override
  void paint(Canvas canvas, Size size) {
    if (start == null || current == null) return;
    final rect = Rect.fromPoints(start!, current!);
    final fill = Paint()
      ..color = const Color(0x3340C4FF)
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = TokC.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(rect, fill);
    canvas.drawRect(rect, border);
  }

  @override
  bool shouldRepaint(covariant _MarqueePainter old) =>
      old.start != start || old.current != current;
}

/// 1x1 透明 PNG（瓦片加载失败时的占位图）。
final Uint8List kTransparentPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// 比例尺（简易）：按当前级别取 nice 米数画一段线。
class ScaleBar extends StatelessWidget {
  final MapCamera camera;
  const ScaleBar({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    final mpp = GeoUtil.metersPerPixel(camera.center.latitude, camera.zoom);
    const steps = [
      1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0,
      5000.0, 10000.0, 20000.0, 50000.0, 100000.0, 200000.0, 500000.0
    ];
    var best = steps.first;
    for (final s in steps) {
      if (s / mpp <= 110) best = s;
    }
    final px = best / mpp;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x99101418),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(GeoUtil.fmtScaleLabel(best),
              style: const TextStyle(color: Colors.white, fontSize: 10)),
          Container(
            width: px,
            height: 4,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 1.2),
            ),
          ),
        ],
      ),
    );
  }
}
