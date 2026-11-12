import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../geo/geo_util.dart';
import '../models/label_type.dart';
import '../models/map_label.dart';
import '../services/loc.dart';
import '../services/photos.dart';
import '../services/platform_caps.dart';
import '../services/search.dart';
import '../services/tile_cache.dart';
import '../services/track_check.dart';
import '../state/app_state.dart';
import 'batch_edit.dart';
import 'compass_widget.dart';
import 'dialogs.dart';
import 'drawer_panel.dart';
import 'export_center.dart';
import 'map/map_canvas.dart';
import 'route_tools.dart';
import 'settings_menu.dart';
import 'tools_menu.dart';
import 'design_tokens.dart';

/// 移动端外壳（竖屏 + Drawer + 浮层）。
///
/// 地图部分由共享核心 [MapCanvas] 承载；本壳只负责移动端的 Chrome（顶部搜索栏、
/// 罗盘、右侧工具栏、底部模式条、收藏夹抽屉）与移动端专属状态（搜索临时标记、
/// 航向）。桌面端走 `ui/desktop/workspace_page.dart` 的另一套壳。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final MapController _mc = MapController();
  final TextEditingController _searchCtl = TextEditingController();

  CacheTileProvider? _baseProvider;
  CacheTileProvider? _overlayProvider;
  String? _baseProviderFor;
  String? _overlayProviderFor;

  double _heading = 0;
  bool _hasHeading = false;
  bool _mapReady = false;
  /// 最近一次相机快照（由 [MapCanvas] 的 onCameraChanged 回传）。
  ///
  /// 切勿改用 `_mc.camera`：该 getter 在 FlutterMap 首次渲染前会抛异常，
  /// 且会让 release AOT 误判可达性，把整棵主 UI 子树裁掉（libapp.so 减半、关键串消失）。
  MapCamera? _cam;
  Timer? _recordTicker;
  int _recordElapsed = 0;
  bool _searching = false;

  /// R4：搜索结果的临时标记（页面态持有，不进草稿、不持久化；
  /// 一次只一个，新的替换旧的；点标记弹信息面板可加收藏/清除）。
  SearchResult? _searchMark;

  @override
  void initState() {
    super.initState();
    final st = context.read<AppState>();
    _setupLocation(st);
  }

  void _setupLocation(AppState st) {
    LocService.instance.onPosition = (pos) {
      st.curLat = pos.latitude;
      st.curLon = pos.longitude;
      st.curAcc = pos.accuracy;
      st.hasFix = true;
      st.feedRecordPoint(pos.latitude, pos.longitude);
      if (st.followUser) {
        final d = st.toDisplay(pos.latitude, pos.longitude);
        // 相机取自可空快照 _cam：地图未就绪时不读会抛异常的 _mc.camera。
        final double curZoom = _cam?.zoom ?? 17.0;
        final z = curZoom < 16 ? 17.0 : curZoom;
        _mc.moveAndRotate(LatLng(d[0], d[1]), z, _cam?.rotation ?? 0);
      }
      if (mounted) setState(() {});
    };
    LocService.instance.onHeading = (h) {
      // 箭头跟随手机方向；地图保持用户自己的朝向，不随手机旋转
      _heading = h;
      _hasHeading = true;
      if (mounted) setState(() {});
    };
    LocService.instance.ensureGranted().then((granted) {
      if (granted) LocService.instance.start();
    });
  }

  @override
  void dispose() {
    LocService.instance.stop();
    _recordTicker?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  // ================= 右侧功能 =================

  /// 点击/长按罗盘：可靠回正北朝上。
  /// 立即把相机旋转角清零（罗盘红针马上回正）。
  void _resetNorth() {
    _mc.moveAndRotate(_mc.camera.center, _mc.camera.zoom, 0);
    if (mounted) setState(() {});
    toast(context, '已回正北朝上');
  }

  void _locateMe() {
    final st = context.read<AppState>();
    LocService.instance.ensureGranted().then((granted) {
      if (!granted) {
        if (mounted) toast(context, '定位权限未开启');
        return;
      }
      LocService.instance.start();
      if (st.curLat != null && st.curLon != null) {
        final d = st.toDisplay(st.curLat!, st.curLon!);
        _mc.moveAndRotate(LatLng(d[0], d[1]),
            _mc.camera.zoom < 16 ? 17.5 : _mc.camera.zoom, _mc.camera.rotation);
        st.setFollow(true);
        if (mounted) toast(context, '已跟随当前位置');
      } else {
        LocService.instance.lastKnown().then((p) {
          if (p != null) {
            final d = st.toDisplay(p.latitude, p.longitude);
            _mc.moveAndRotate(LatLng(d[0], d[1]), 16.5, _mc.camera.rotation);
            st.setFollow(true);
          } else if (mounted) {
            toast(context, '正在搜索 GPS 信号…');
          }
        });
      }
    });
  }

  Future<void> _doSearch(String q) async {
    if (q.trim().isEmpty) return;
    final st = context.read<AppState>();
    final coord = GeoUtil.parseCoordInput(q);
    if (coord != null) {
      final d = st.toDisplay(coord[0], coord[1]);
      _mc.moveAndRotate(LatLng(d[0], d[1]), 17, _mc.camera.rotation);
      toast(context, '已跳转到输入坐标');
      return;
    }
    setState(() => _searching = true);
    // R3：以当前地图中心（WGS84）为基准点，结果按距离升序（离用户最近的排最前）
    final cam0 = _mc.camera;
    final near = st.toWgs(cam0.center.latitude, cam0.center.longitude);
    List<SearchResult> results;
    try {
      results = await SearchService.search(q,
          // 高德优先（内置 key 开箱即用，用户自配则覆盖），失败回落天地图 → 境外源
          amapKey: st.amapKey,
          tdtKey: st.tiandituKey, nearLat: near[0], nearLon: near[1],
          // 高德/天地图检索 POI 实测为 GCJ-02；按用户设置决定是否纠偏（默认开）
          convertGcj: st.tdtConvertGcj);
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
      toast(context, (st.amapKey.isEmpty && st.tiandituKey.isEmpty)
          ? '未配置高德/天地图 Key，仅能走境外慢源（可能搜不到）。'
              '请在「设置 → 高德 Key 设置 / 天地图 Key 设置」里填 key 后搜索更快更准；'
              '也可直接输入经纬度，支持度分秒：32°07\'48"N 114°05\'24"E'
          : '搜索失败，可直接输入经纬度（支持度分秒）');
      return;
    }
    if (!mounted) return;
    setState(() => _searching = false);
    if (results.isEmpty) {
      toast(context, '未找到结果');
      return;
    }
    showDarkDialog(context, title: '搜索结果（按距离排序）', content: SizedBox(
      width: double.maxFinite,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final r in results)
          InkWell(
            onTap: () {
              Navigator.pop(context);
              final d = st.toDisplay(r.lat, r.lon);
              _mc.moveAndRotate(LatLng(d[0], d[1]), 16.5, _mc.camera.rotation);
              // R4：跳转后放临时标记（替换上一个；不进草稿、不持久化）
              setState(() => _searchMark = r);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.place, color: kAccent, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            r.name.length > 40
                                ? '${r.name.substring(0, 40)}…'
                                : r.name,
                            style: const TextStyle(
                                color: kTextMain, fontSize: 13.5)),
                        if (r.address.isNotEmpty)
                          Text(
                              r.address.length > 56
                                  ? '${r.address.substring(0, 56)}…'
                                  : r.address,
                              style: const TextStyle(
                                  color: kTextSub, fontSize: 11)),
                      ],
                    ),
                  ),
                  // R3：显示与地图中心的距离
                  Text(
                    _fmtNearDist(GeoUtil.haversine(near[0], near[1],
                        r.lat, r.lon)),
                    style: const TextStyle(color: kTextSub, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
      ]),
    ), actions: [
      darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub)
    ]);
  }

  /// R3：距离显示（<1000m 显示米，≥1000m 显示公里）。
  String _fmtNearDist(double m) => m < 1000
      ? '≈${m.toStringAsFixed(0)} m'
      : '≈${(m / 1000).toStringAsFixed(1)} km';

  /// R4：临时标记信息面板：名称/地址/坐标 + 「加入收藏」「清除标记」。
  void _showSearchMarkPanel(AppState st) {
    final r = _searchMark;
    if (r == null) return;
    final d = st.toDisplay(r.lat, r.lon);
    showDarkDialog(
      context,
      title: '搜索位置',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('📍 ${r.name}',
              style: const TextStyle(color: kTextMain, fontSize: 14)),
          if (r.address.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(r.address,
                style: const TextStyle(color: kTextSub, fontSize: 12)),
          ],
          const SizedBox(height: 8),
          Text('坐标：${GeoUtil.formatCoord(d[0], d[1], st.coordFmt)}',
              style: const TextStyle(color: kTextSub, fontSize: 12)),
          Text('（${GeoUtil.fmtName(st.coordFmt)} · 当前显示坐标系）',
              style: const TextStyle(color: kTextSub, fontSize: 10)),
        ],
      ),
      actions: [
        darkTextBtn('清除标记', () {
          setState(() => _searchMark = null);
          Navigator.pop(context);
        }, color: kTextSub),
        darkTextBtn('加入收藏', () async {
          Navigator.pop(context);
          try {
            // 新建独立收藏工程：不污染当前草稿；保存后自动在地图显示（AppState 内处理）
            await st.savePointAsCollection(r.name, r.lat, r.lon, note: r.address);
            if (!mounted) return;
            setState(() => _searchMark = null);
            toast(context, '已收藏「${r.name}」，已在地图显示');
          } catch (e) {
            if (mounted) toast(context, '收藏失败：$e');
          }
        }, color: kGreen),
      ],
    );
  }

  // ================= 业务符号层（注入 MapCanvas） =================
  // 逻辑复用共享核心的 buildBusinessMarkers，本壳只镜像 mapReady。
  //
  // 注意：相机取自 [_cam]（onCameraChanged 回传），**不可**用 `_mc.camera` ——
  // 后者在首帧前会抛异常，且会在 release AOT 中触发整棵 UI 子树被裁。
  List<Marker> _buildMarkers(AppState st) => _cam == null
      ? const <Marker>[]
      : buildBusinessMarkers(st, _cam!, mapReady: _mapReady);

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    if (!st.inited) {
      return const Scaffold(
        backgroundColor: TokC.panelSolid,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: kAccent),
              SizedBox(height: 14),
              Text('滑洲云图 启动中…',
                  style: TextStyle(color: kTextSub, fontSize: 13)),
            ],
          ),
        ),
      );
    }

    // 图源变化时重建 provider
    if (_baseProviderFor != st.curSource.id || _baseProvider == null) {
      _baseProvider = CacheTileProvider(
          sourceId: st.curSource.id,
          urlTemplate: st.curSource.normalizedUrl);
      _baseProviderFor = st.curSource.id;
    }
    final ovl = st.currentOverlay();
    if (ovl != null && _overlayProviderFor != ovl.id) {
      _overlayProvider = CacheTileProvider(
          sourceId: ovl.id, urlTemplate: ovl.normalizedUrl);
      _overlayProviderFor = ovl.id;
    } else if (ovl == null) {
      _overlayProvider = null;
      _overlayProviderFor = null;
    }

    return Scaffold(
      backgroundColor: TokC.panelSolid,
      drawer: FavoritesDrawer(st: st),
      body: Stack(
        children: [
          // ---- 地图（共享核心） ----
          MapCanvas(
            st: st,
            controller: _mc,
            baseProvider: _baseProvider!,
            overlayProvider: _overlayProvider,
            heading: _heading,
            hasHeading: _hasHeading,
            onMapReady: () {
              _mapReady = true;
            },
            onCameraChanged: (cam) {
              _cam = cam;
              if (mounted) setState(() {});
            },
            extraLayers: [
              MarkerLayer(markers: _buildMarkers(st)),
              // R4 搜索临时标记：醒目洋红定位针，与业务符号明显区分；
              // 仅页面态，不进草稿、不持久化；点击弹信息面板。
              if (_searchMark != null)
                MarkerLayer(markers: [
                  Marker(
                    point: LatLng(
                        st.toDisplay(_searchMark!.lat, _searchMark!.lon)[0],
                        st.toDisplay(_searchMark!.lat, _searchMark!.lon)[1]),
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    child: GestureDetector(
                      onTap: () => _showSearchMarkPanel(st),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: const Color(0xFFE91E63), width: 2.5),
                          boxShadow: const [
                            BoxShadow(
                                color: Color(0x66000000),
                                blurRadius: 6,
                                spreadRadius: 2),
                          ],
                        ),
                        child: const Center(
                          child: Icon(Icons.search,
                              color: Color(0xFFE91E63), size: 22),
                        ),
                      ),
                    ),
                  ),
                ]),
            ],
          ),

          // ---- 顶部搜索栏 ----
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xCC151A1F),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Row(
                    children: [
                      Builder(
                        builder: (ctx) => _iconBtn(Icons.menu,
                            tooltip: '收藏夹',
                            onTap: () => Scaffold.of(ctx).openDrawer()),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _searchCtl,
                          style: const TextStyle(
                              color: kTextMain, fontSize: 13),
                          decoration: const InputDecoration(
                            hintText: '搜索地点 / 输入经纬度',
                            hintStyle: TextStyle(
                                color: Color(0xFF78828E), fontSize: 13),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                          ),
                          onSubmitted: _doSearch,
                        ),
                      ),
                      _searching
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: kAccent))
                          : _iconBtn(Icons.search, onTap: () {
                              FocusScope.of(context).unfocus();
                              _doSearch(_searchCtl.text);
                            }),
                      _iconBtn(Icons.layers_outlined,
                          tooltip: '图层/图源',
                          onTap: () => showSourceDialog(context, st)),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ---- 右上角罗盘（桌面无罗盘能力时不渲染） ----
          if (PlatformCaps.hasCompass)
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 58, right: 10),
                  child: CompassWidget(
                    // 可空快照：首帧地图未就绪时不得直接读 _mc.camera（会抛异常）。
                    mapRotation: _cam?.rotation ?? 0,
                    heading: _heading,
                    hasHeading: _hasHeading,
                    compassMode: st.compassMode,
                    onTap: _resetNorth,
                    onLongPress: _resetNorth,
                  ),
                ),
              ),
            ),

          // ---- 右侧工具栏（含缩放）----
          SafeArea(
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xB3151A1F),
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _railBtn('＋', () {
                        final c = _mc.camera;
                        _mc.moveAndRotate(
                            c.center, c.zoom + 1, _mc.camera.rotation);
                      }),
                      _railBtn('－', () {
                        final c = _mc.camera;
                        _mc.moveAndRotate(
                            c.center, c.zoom - 1, _mc.camera.rotation);
                      }),
                      _divider(),
                      _railBtn('✚', () {
                        st.setMode(st.mode == AppMode.edit
                            ? AppMode.view
                            : AppMode.edit);
                      }, active: st.mode == AppMode.edit, label: '标记'),
                      _railBtn('⌖', () => _measureMenu(st), label: '测量'),
                      _railBtn('∿', () => _trackMenu(st), label: '轨迹'),
                      _railBtn('◎', _locateMe,
                          active: st.followUser, label: '定位'),
                      _railBtn('⋯', () => _showToolsMenu(st), label: '工具'),
                      _railBtn('⚙', () => _showSettingsMenu(st), label: '设置'),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ---- 比例尺（左下，信息栏上方） ----
          SafeArea(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: EdgeInsets.only(
                    left: 12, bottom: _bottomAreaHeight(st) + 8),
                child: _mapReady
                    ? ScaleBar(camera: _mc.camera)
                    : const SizedBox.shrink(),
              ),
            ),
          ),

          // ---- 底部区域（模式工具条 + 信息栏） ----
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (st.recording) _recordBar(st),
                  if (st.mode == AppMode.edit) _editBar(st),
                  if (st.mode == AppMode.measureDist ||
                      st.mode == AppMode.measureArea)
                    _measureBar(st),
                  if (st.mode == AppMode.boxSelect) _boxSelectBar(st),
                  if (st.mode == AppMode.topoLink) _topoBar(st),
                  // 普通模式无信息可显（不录轨迹时），信息栏整个隐藏
                  if (st.mode != AppMode.view || st.recording)
                    _bottomInfoBar(st),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  double _bottomAreaHeight(AppState st) {
    // 信息栏：普通模式（不录轨迹）整个隐藏，不占高度
    var h = (st.mode != AppMode.view || st.recording) ? 46.0 : 0.0;
    if (st.recording) h += 44;
    switch (st.mode) {
      case AppMode.edit:
        h += 176; // 模式行 + 符号行 + 操作行 + 批量/布杆行
        break;
      case AppMode.measureDist:
      case AppMode.measureArea:
      case AppMode.topoLink:
      case AppMode.boxSelect:
        h += 48;
        break;
      case AppMode.view:
        break;
    }
    return h;
  }

  // ================= 底部条 =================

  Widget _bottomInfoBar(AppState st) {
    String modeTag;
    switch (st.mode) {
      case AppMode.edit:
        // 待定编辑状态优先提示（拖动点位）
        if (st.draggingLabelId != null) {
          modeTag = '【拖动点位中·点地图放置】';
          break;
        }
        // 采集中实时显示已连线总长（设计/竣工都最关心这个数）
        var total = 0.0;
        var segCount = 0;
        for (final chain in buildLabelChains(st.labels)) {
          for (var i = 1; i < chain.length; i++) {
            total += chain[i].distanceM ??
                GeoUtil.haversine(chain[i - 1].lat, chain[i - 1].lon,
                    chain[i].lat, chain[i].lon);
            segCount++;
          }
        }
        modeTag = '【采集中·${st.curType.name}】'
            '${segCount > 0 ? ' 已连${_fmtChainLen(total)}/$segCount段' : ''}';
        break;
      case AppMode.topoLink:
        modeTag = '【拓扑连线】';
        break;
      case AppMode.measureDist:
        modeTag = '【测距】';
        break;
      case AppMode.measureArea:
        modeTag = '【测面积】';
        break;
      case AppMode.boxSelect:
        modeTag = '【框选】地图上拖出矩形选择点';
        break;
      case AppMode.view:
        modeTag = st.recording
            ? '【轨迹中】'
            : '【普通·点杆子/箱子可直接编辑】';
        break;
    }
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xE6101418),
        border: Border(top: BorderSide(color: TokC.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              modeTag,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(color: Color(0xFFD6DEE6), fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _editBar(AppState st) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: kBarBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 模式行
          Row(
            children: [
              Expanded(
                child: _modeChip('设计模式',
                    active: st.editModeName == 'design',
                    onTap: () => st.chooseEditMode('design')),
              ),
              Expanded(
                child: _modeChip('竣工模式',
                    active: st.editModeName == 'completion',
                    color: TokC.warn,
                    onTap: () => st.chooseEditMode('completion')),
              ),
              _modeChip('撤销', onTap: st.undoDraft),
              _modeChip('清空', onTap: () {
                if (st.labels.isEmpty) return;
                final editing = st.activeCollectionId.isNotEmpty;
                showDarkDialog(context,
                    title: editing ? '清空收藏内容' : '清空草稿',
                    content: Text(
                        editing
                            ? '「${st.projectName}」的 ${st.labels.length} 个点将被清空，'
                                '并同步写回收藏（误清可撤销）。'
                            : '确定删除当前 ${st.labels.length} 个未保存的点？',
                        style:
                            const TextStyle(color: kTextMain, fontSize: 13)),
                    actions: [
                      darkTextBtn('取消', () => Navigator.pop(context),
                          color: kTextSub),
                      darkTextBtn('清空', () {
                        st.clearDraft();
                        Navigator.pop(context);
                      }, color: TokC.danger),
                    ]);
              }),
            ],
          ),
          const SizedBox(height: 4),
          // 符号行
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              children: [
                for (final t in LabelType.all)
                  GestureDetector(
                    onTap: () => st.setType(t),
                    child: Container(
                      width: 62,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: st.curType.id == t.id
                            ? t.color.withValues(alpha: 0.85)
                            : TokC.field,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: st.curType.id == t.id
                                ? kAccent
                                : Colors.transparent),
                      ),
                      child: Text(t.name,
                          maxLines: 1,
                          style: const TextStyle(
                              color: kTextMain, fontSize: 10.5)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // 操作行
          Row(
            children: [
              Expanded(child: _modeChip('我在这', onTap: () {
                st.markHere();
                toast(context, '已在当前位置添加 ${st.curType.name}');
              })),
              Expanded(child: _modeChip('属性', onTap: () {
                if (st.labels.isEmpty) {
                  toast(context, '请先添加标签');
                  return;
                }
                showLabelProperties(context, st, st.labels.last);
              })),
              Expanded(
                child: _modeChip('保存收藏',
                    color: kGreen, onTap: () => showFinishDialog(context, st)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 批量 / 布杆行（P0-2 / P0-5）
          Row(
            children: [
              Expanded(
                child: _modeChip('批量编辑',
                    color: kAccent, onTap: () => _batchMenu(st)),
              ),
              Expanded(
                child: _modeChip('自动布杆',
                    color: kGreen, onTap: () => showAutoPoleDialog(context, st)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _measureBar(AppState st) {
    final isArea = st.mode == AppMode.measureArea;
    final n = st.measurePts.length;
    String hud = '点按地图添加测量点';
    if (isArea && n >= 3) {
      final lats = st.measurePts.map((e) => e.lat).toList();
      final lons = st.measurePts.map((e) => e.lon).toList();
      hud = '面积：${GeoUtil.fmtArea(GeoUtil.polygonArea(lats, lons, n))}';
    } else if (n >= 2) {
      hud = '总长：${GeoUtil.fmtDist(st.measureTotal())} · $n 个点';
    }
    return _stripBar(
      hud: hud,
      hudColor: const Color(0xFFFFCC80),
      actions: [
        _modeChip('撤销', onTap: st.undoMeasure),
        _modeChip('保存', onTap: () async {
          if (st.measurePts.length < 2) {
            toast(context, '至少需要 2 个点');
            return;
          }
          await st.saveMeasureAsCollection();
          if (mounted) toast(context, '已保存到收藏');
        }),
        _modeChip('完成', onTap: () => st.setMode(AppMode.view)),
      ],
    );
  }

  Widget _boxSelectBar(AppState st) {
    return _stripBar(
      hud: '框选：地图上拖出矩形 · 已选 ${st.selectedIds.length} 点',
      hudColor: const Color(0xFF80D8FF),
      actions: [
        _modeChip('设置属性', onTap: () {
          if (st.selectedIds.isEmpty) {
            toast(context, '未选到点，请重新框选');
            return;
          }
          showBatchEditDialog(context, st);
        }),
        _modeChip('清空', onTap: st.clearSelection),
        _modeChip('完成', onTap: () {
          st.clearSelection();
          st.setMode(AppMode.edit);
        }),
      ],
    );
  }

  Widget _topoBar(AppState st) {
    return _stripBar(
      hud: '拓扑连线：点起点箱体 → 点终点箱体',
      hudColor: const Color(0xFFFFCC80),
      actions: [
        _modeChip('撤销连线', onTap: st.undoTopoLink),
        _modeChip('导出', onTap: () => openExportCenter(context, st)),
        _modeChip('?', onTap: () => showTopoGuide(context)),
        _modeChip('完成', onTap: st.endTopoLink),
      ],
    );
  }

  Widget _recordBar(AppState st) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xE63B1620),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Text(st.recordPaused ? '⏸' : '●',
              style: TextStyle(
                  color: st.recordPaused
                      ? const Color(0xFFFFD54F)
                      : TokC.danger,
                  fontSize: 14)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                '${GeoUtil.fmtDist(st.recordDistance)} · ${_fmtElapsed(_recordElapsed)}'
                '${st.recordPaused ? '（已暂停）' : ''}',
                style: const TextStyle(color: kTextMain, fontSize: 12)),
          ),
          _modeChip(st.recordPaused ? '继续' : '暂停',
              onTap: st.toggleRecordPause),
          _modeChip('结束', onTap: () async {
            final cid = await st.stopRecordAndSave();
            if (mounted) {
              toast(context,
                  cid == null ? '轨迹点太少，未保存' : '轨迹已保存到收藏');
            }
          }),
        ],
      ),
    );
  }

  Widget _stripBar(
      {required String hud,
      required Color hudColor,
      required List<Widget> actions}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: kBarBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(hud,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: hudColor, fontSize: 12)),
          ),
          ...actions,
        ],
      ),
    );
  }

  // ================= 小组件 =================

  Widget _iconBtn(IconData icon,
          {required VoidCallback onTap, String? tooltip}) =>
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        onPressed: onTap,
        icon: Icon(icon, color: kTextMain, size: 21),
      );

  Widget _railBtn(String glyph, VoidCallback onTap,
      {bool active = false, String? label}) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(glyph,
                style: TextStyle(
                    color: active ? kAccent : kTextMain,
                    fontSize: 19,
                    fontWeight: FontWeight.bold)),
            if (label != null)
              Text(label,
                  style: TextStyle(
                      color: active ? kAccent : kTextSub, fontSize: 8)),
          ],
        ),
      ),
    );
  }

  Widget _divider() => Container(
      width: 26,
      height: 1,
      color: TokC.divider,
      margin: const EdgeInsets.symmetric(vertical: 3));

  Widget _modeChip(String text,
      {VoidCallback? onTap, bool active = false, Color? color}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? (color ?? kAccent).withValues(alpha: 0.9)
                : TokC.field,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(text,
              maxLines: 1,
              style: TextStyle(
                  color: active ? Colors.black : (color ?? kTextMain),
                  fontSize: 11.5,
                  fontWeight: active ? FontWeight.bold : FontWeight.normal)),
        ),
      ),
    );
  }

  // ================= 菜单 =================

  void _measureMenu(AppState st) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kPanelBg,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.straighten, color: kAccent),
            title: const Text('测距',
                style: TextStyle(color: kTextMain)),
            onTap: () {
              Navigator.pop(ctx);
              st.setMode(AppMode.measureDist);
            },
          ),
          ListTile(
            leading: const Icon(Icons.crop_square, color: kAccent),
            title: const Text('测面积',
                style: TextStyle(color: kTextMain)),
            onTap: () {
              Navigator.pop(ctx);
              st.setMode(AppMode.measureArea);
            },
          ),
        ]),
      ),
    );
  }

  void _trackMenu(AppState st) {
    if (st.recording) {
      st.toggleRecordPause();
      return;
    }
    LocService.instance.ensureGranted().then((granted) {
      if (!granted) {
        if (mounted) toast(context, '需要定位权限才能记录轨迹');
        return;
      }
      LocService.instance.start();
      st.startRecord();
      _recordTicker?.cancel();
      _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!st.recording) {
          _recordTicker?.cancel();
          return;
        }
        if (!st.recordPaused) {
          _recordElapsed = (DateTime.now().millisecondsSinceEpoch -
                  st.recordStartMs) ~/
              1000;
          if (mounted) setState(() {});
        }
      });
      _recordElapsed = 0;
      if (mounted) toast(context, '轨迹记录中，点「轨迹」暂停/继续');
    });
  }

  /// ⋯工具面板（成果与资料 + 专业工具）。
  void _showToolsMenu(AppState st) {
    showToolsMenu(
      context,
      st,
      onPoleTable: () => _showPoleTable(st),
      onTrackCheck: () => _showTrackCheck(st),
    );
  }

  /// ⚙设置面板（地图/存储/采集/高级/关于）。
  void _showSettingsMenu(AppState st) {
    showSettingsMenu(
      context,
      st,
      onOffline: () => showOfflineDialog(context, st, _mc, _baseProvider!),
      onStorageCleanup: () => _storageCleanup(st),
    );
  }

  /// 存储清理（合一入口）：清图源缓存 + 清未引用照片。
  Future<void> _storageCleanup(AppState st) async {
    final n = await _baseProvider?.clearDiskCache() ?? 0;
    _baseProviderFor = null; // 强制重建 provider
    if (mounted) setState(() {});
    final refs = <String>{};
    void eat(List<MapLabel> ls) {
      for (final e in ls) {
        refs.addAll(e.photoPaths);
      }
    }

    eat(st.labels);
    for (final m in st.collections) {
      eat(await st.store.loadCollection(m.id));
    }
    final p = await PhotoService.purgeOrphans([refs]);
    if (mounted) {
      toast(context,
          '存储清理完成：图源缓存${n > 0 ? '已清' : '无'} · 未引用照片${p > 0 ? '已清 $p 个' : '无'}');
    }
  }

  /// 批量编辑：选整条线组 / 进入框选 / 直接设置属性。
  void _batchMenu(AppState st) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kPanelBg,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.link, color: kAccent),
            title: const Text('选整条线组', style: TextStyle(color: kTextMain)),
            subtitle: const Text('一次选中一整段杆路',
                style: TextStyle(color: kTextSub, fontSize: 11)),
            onTap: () {
              Navigator.pop(ctx);
              _showChainPicker(st);
            },
          ),
          ListTile(
            leading: const Icon(Icons.crop_free, color: kAccent),
            title: const Text('进入框选', style: TextStyle(color: kTextMain)),
            subtitle: const Text('在地图上拖出矩形选择点',
                style: TextStyle(color: kTextSub, fontSize: 11)),
            onTap: () {
              Navigator.pop(ctx);
              st.clearSelection();
              st.setMode(AppMode.boxSelect);
              toast(context, '框选：拖出矩形选择要批量修改的点');
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_note, color: kAccent),
            title:
                const Text('批量设置属性', style: TextStyle(color: kTextMain)),
            subtitle: Text('当前已选 ${st.selectedIds.length} 点',
                style: const TextStyle(color: kTextSub, fontSize: 11)),
            onTap: () {
              Navigator.pop(ctx);
              if (st.selectedIds.isEmpty) {
                toast(context, '请先「选整条线组」或「进入框选」');
                return;
              }
              showBatchEditDialog(context, st);
            },
          ),
        ]),
      ),
    );
  }

  /// 线组选择器：列出各链，点一条即选中整组并进入批量设置。
  void _showChainPicker(AppState st) {
    final chains = buildLabelChains(st.labels);
    if (chains.isEmpty) {
      toast(context, '当前草稿没有可选的线组');
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: kPanelBg,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('选择一条线组（点即选中整组）',
                  style: TextStyle(color: kTextSub, fontSize: 12)),
            ),
            for (var i = 0; i < chains.length; i++)
              ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 12,
                  backgroundColor: kAccent,
                  child: Text('${i + 1}',
                      style: const TextStyle(
                          color: Colors.black, fontSize: 11)),
                ),
                title: Text('线组 ${i + 1} · ${chains[i].length} 点',
                    style: const TextStyle(
                        color: kTextMain, fontSize: 13.5)),
                subtitle: Text(
                    '起点「${_labelName(chains[i].first)}」 → 终点「${_labelName(chains[i].last)}」',
                    style: const TextStyle(color: kTextSub, fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  st.selectChain(chains[i].first.lineGroupId);
                  toast(context, '已选中 ${st.selectedIds.length} 点');
                  showBatchEditDialog(context, st);
                },
              ),
          ],
        ),
      ),
    );
  }

  String _labelName(MapLabel l) =>
      l.name.trim().isNotEmpty ? l.name.trim() : l.type.name;

  /// 杆路点表：按链分组列出当前项目所有参与连线的点，
  /// 点击定位到该点并打开属性——现场核对、竣工检查的高频操作。
  Future<void> _showPoleTable(AppState st) async {
    if (st.labels.isEmpty) {
      if (mounted) toast(context, '当前项目没有点');
      return;
    }
    final chains = buildLabelChains(st.labels);
    await showModalBottomSheet(
      context: context,
      backgroundColor: kPanelBg,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('杆路点表（点条目定位并编辑属性）',
                  style: TextStyle(color: kTextSub, fontSize: 12)),
            ),
            for (var ci = 0; ci < chains.length; ci++) ...[
              Builder(builder: (ctx) {
                var len = 0.0;
                for (var i = 1; i < chains[ci].length; i++) {
                  len += chains[ci][i].distanceM ??
                      GeoUtil.haversine(chains[ci][i - 1].lat,
                          chains[ci][i - 1].lon, chains[ci][i].lat, chains[ci][i].lon);
                }
                return Container(
                  color: TokC.field,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 6),
                  child: Text(
                      '链 ${ci + 1} · ${chains[ci].length} 点 · 全长 ${_fmtChainLen(len)}',
                      style: const TextStyle(
                          color: kAccent, fontSize: 12.5)),
                );
              }),
              for (final l in chains[ci])
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 11,
                    backgroundColor: l.type.color,
                    child: Text(
                        l.name.trim().isNotEmpty
                            ? l.name.trim().substring(0, 1)
                            : (l.type.symbol.isEmpty
                                ? l.type.name.substring(0, 1)
                                : l.type.symbol),
                        style: const TextStyle(
                            color: Colors.white, fontSize: 11)),
                  ),
                  title: Text(
                      l.name.trim().isNotEmpty
                          ? l.name.trim()
                          : l.type.name,
                      style: const TextStyle(
                          color: kTextMain, fontSize: 13.5)),
                  subtitle: Text(
                    _poleTableSub(l, chains[ci]),
                    style: const TextStyle(color: kTextSub, fontSize: 11),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    final d = st.toDisplay(l.lat, l.lon);
                    _mc.move(LatLng(d[0], d[1]), _mc.camera.zoom);
                    showLabelProperties(context, st, l);
                  },
                ),
            ],
            if (chains.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('没有参与连线的点（箱体请从地图上直接点选）',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kTextSub, fontSize: 13)),
              ),
          ],
        ),
      ),
    );
  }

  String _poleTableSub(MapLabel l, List<MapLabel> chain) {
    final parts = <String>[];
    final i = chain.indexOf(l);
    if (i > 0) {
      final d = l.distanceM ??
          GeoUtil.haversine(
              chain[i - 1].lat, chain[i - 1].lon, l.lat, l.lon);
      parts.add('距上点 ${GeoUtil.fmtDist(d)}');
    }
    if (l.slackM > 0) parts.add('盘留${_fmtSlack(l.slackM)}m');
    if (l.segCable.trim().isNotEmpty) parts.add(l.segCable.trim());
    if (l.photoPaths.isNotEmpty) parts.add('${l.photoPaths.length}图');
    if (l.note.trim().isNotEmpty) parts.add(l.note.trim());
    return parts.isEmpty ? l.type.name : parts.join(' · ');
  }

  // ---- 杆路轨迹核查（轨迹 vs 杆路偏移检测） ----

  Future<void> _showTrackCheck(AppState st) async {
    final tracks = st.collections.where((m) => m.kind == 'track').toList();
    if (tracks.isEmpty) {
      if (mounted) {
        toast(context, '没有轨迹：先沿线走查一遍并记录轨迹，再来核查');
      }
      return;
    }
    final poles = [
      for (final chain in buildLabelChains(st.labels)) ...chain,
    ];
    if (poles.isEmpty) {
      if (mounted) toast(context, '当前项目没有杆路点，无法核查');
      return;
    }
    await showModalBottomSheet(
      context: context,
      backgroundColor: kPanelBg,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('选择一条轨迹（现场沿线走查时记录）',
                style: TextStyle(color: kTextSub, fontSize: 12)),
          ),
          for (final m in tracks)
            ListTile(
              dense: true,
              title: Text(m.name.isEmpty ? '未命名轨迹' : m.name,
                  style: const TextStyle(color: kTextMain, fontSize: 13.5)),
              subtitle: Text('${m.count} 点 · '
                  '${DateTime.fromMillisecondsSinceEpoch(m.createdAt).toIso8601String().substring(0, 10)}',
                  style: const TextStyle(color: kTextSub, fontSize: 11)),
              onTap: () async {
                Navigator.pop(ctx);
                final trackPts = await st.store.loadCollection(m.id);
                final r = TrackChecker.check(trackPts, poles);
                if (!mounted) return;
                _showTrackCheckReport(st, m.name, r);
              },
            ),
        ]),
      ),
    );
  }

  void _showTrackCheckReport(
      AppState st, String trackName, TrackCheckResult r) {
    final outlierLines = <Widget>[];
    for (final (pole, off) in r.outliers.take(10)) {
      final nm =
          pole.name.trim().isNotEmpty ? pole.name.trim() : pole.type.name;
      outlierLines.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text('· $nm：偏移 ${off.toStringAsFixed(0)} 米',
            style: const TextStyle(
                color: TokC.warn, fontSize: 12.5)),
      ));
    }
    showDarkDialog(
      context,
      title: '轨迹核查报告',
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('轨迹：$trackName',
                style: const TextStyle(color: kTextSub, fontSize: 12)),
            const SizedBox(height: 6),
            Text(
                '杆数 ${r.poleCount} · 轨迹全长 ${_fmtChainLen(r.trackLen)}\n'
                '平均偏移 ${r.avgOffset.toStringAsFixed(0)} 米（阈值 ${r.threshold.toStringAsFixed(0)} 米）',
                style: const TextStyle(color: kTextMain, fontSize: 13)),
            const SizedBox(height: 10),
            Text(
                r.outliers.isEmpty
                    ? '✓ 全部杆位偏移在阈值内，没有漏杆/错位迹象'
                    : '⚠ ${r.outliers.length} 根杆偏移超阈值（疑似漏走/错位），按偏移从大到小：',
                style: TextStyle(
                    color: r.outliers.isEmpty
                        ? TokC.ok
                        : TokC.warn,
                    fontSize: 13)),
            ...outlierLines,
            if (r.outliers.length > 10)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('…其余 ${r.outliers.length - 10} 根从略',
                    style: const TextStyle(color: kTextSub, fontSize: 11.5)),
              ),
            const SizedBox(height: 6),
            const Text('提示：阈值 30 米 ≈ GPS 民用误差 + 合理走路偏离；'
                    '杆位打偏请用属性里的「拖动点位」修正。',
                style: TextStyle(color: kTextSub, fontSize: 11)),
          ],
        ),
      ),
      actions: [
        darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
      ],
    );
  }

  String _fmtElapsed(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  /// 链长显示：<1000m 显示米，≥1000m 显示公里。
  String _fmtChainLen(double m) =>
      m < 1000 ? '${m.toStringAsFixed(0)}m' : '${(m / 1000).toStringAsFixed(2)}km';

  /// 盘留数字显示：整数不带小数点，否则保留 1 位。
  String _fmtSlack(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}
