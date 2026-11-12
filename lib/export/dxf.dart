import 'dart:io';
import 'dart:math' as math;

import 'package:gbk_codec/gbk_codec.dart';

import '../geo/geo_util.dart';
import '../models/label_type.dart';
import '../models/map_label.dart';
import '../services/store.dart';
import 'basemap.dart';
import 'dxf_layers.dart';
import 'dxf_validate.dart';
import 'dxf_version.dart';
import 'local_basemap.dart';
import 'topo.dart';

/// DXF 导出结果：文件 + 非致命警告 + 底图抓取三态报告。
class DxfExportResult {
  final File file;
  final List<String> warnings;
  final BasemapFetchReport? report;
  DxfExportResult(this.file, this.warnings, [this.report]);
}

/// 可累加的包围盒（底图渲染时同步扩展图框范围）。
class _Ext {
  double minX;
  double minY;
  double maxX;
  double maxY;
  _Ext(this.minX, this.minY, this.maxX, this.maxY);
  void add(double x, double y) {
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
}

/// DXF 句柄分配器（仅 R2000 使用）。句柄为十六进制字符串、全局唯一、递增。
/// 起始值 `0x30`（48）；模块空间块固定占 `1F`（31，小于起始值，不冲突）。
class _H {
  int _v;
  _H([int start = 0x30]) : _v = start;
  String next() {
    final r = _v;
    _v++;
    return r.toRadixString(16).toUpperCase();
  }

  /// 下一个（尚未使用的）句柄值；用于 `$HANDSEED`（必须大于所有已用句柄）。
  int get nextValue => _v;
}

/// 实体写出上下文：把「输出缓冲 + 版本 + 句柄分配器」绑在一起，
/// 使 R12（无句柄/无子类标记）与 R2000（句柄 + `100 AcDb*` 子类标记）**共用同一套
/// 绘制函数**，仅在 [ent] 处按版本分叉，避免两套渲染逻辑漂移。
///
/// **句柄分配器在所有缓冲间共享**（主实体段与底图文字缓冲用同一个 [_H]），
/// 否则会出现重复句柄（非法文件）。
class _Ctx {
  final StringBuffer sb;
  final DxfVersion v;
  final _H h;
  _Ctx(this.sb, this.v, this.h);

  bool get r2000 => v == DxfVersion.r2000;

  /// 实体起始：写类型名 + 图层；R2000 追加句柄 `5`、属主 `330`、子类标记 `100`。
  void ent(String type, String layer, String sub) {
    sb.write('0\n$type\n');
    if (r2000) {
      sb.write('5\n${h.next()}\n330\n1F\n100\nAcDbEntity\n8\n$layer\n100\n$sub\n');
    } else {
      sb.write('8\n$layer\n');
    }
  }
}

/// DXF 导出（默认 **R12/AC1009**，可选 **R2000/AC1015**——两者均**结构合法**，
/// 以真实解析器 ezdxf 严格打开为准）。
/// 坐标采用本地平面投影（以第一个点为原点，米为单位，等距圆柱近似，小范围足够）。
///
/// - **版本分支**收敛到 3 处：①图层表（R2000 写 `370`/`420`，R12 只写 `62`/`6`）；
///   ②多段线（R2000=`LWPOLYLINE`，R12=经典 `POLYLINE/VERTEX/SEQEND`）；
///   ③建筑填充（R2000=`HATCH`，R12=`SOLID` 三角近似）。**其余绘制逻辑完全共用**。
/// - **R2000 合法结构**：完整 HEADER（`$ACADVER/$HANDSEED/$EXTMIN/$EXTMAX/...`）+
///   CLASSES 段 + TABLES/BLOCKS 记录句柄 + 每个实体句柄(5) + `100 AcDb*` 子类标记 +
///   OBJECTS 段。**导出前后由 [DxfStructureValidator] 强校验**，校验不过即抛错，
///   绝不产出「打不开」的文件。
/// - **底图线宽/字号**一律按 `纸面毫米 ÷ 1000 × 出图比例` 换算为图纸米数，
///   不再 1:1 使用真实路宽（否则"路太粗/建筑塌陷"原样复发）。
/// - 业务层（杆路/管廊/桩号/距离/标签/配线图/图框）**行为保持不变**。
class DxfExporter {
  DxfExporter._();

  static String _fmt(double v) => v.toStringAsFixed(3);

  /// CLASSES 段（R2000）：仅声明 HATCH（实体填充）类，供读取器识别。
  static const String _classesSection =
      '0\nSECTION\n2\nCLASSES\n'
      '0\nCLASS\n1\nHATCH\n2\nAcDbHatch\n3\nObjectDBX Classes\n'
      '90\n0\n280\n0\n281\n0\n'
      '0\nENDSEC\n';

  static Future<DxfExportResult> export({
    required String name,
    required List<MapLabel> labels,
    bool includeLabelSymbols = true,
    double corridorWidth = 0, // 0=单线，>0=管廊双线宽度（米）
    bool includeSurroundings = false,
    bool showStakes = true, // 杆路里程桩号（K0+000）
    bool showLegend = true, // 图例栏自动生成
    bool completionRed = false, // 竣工图红色描边
    bool straightenedWiring = false, // 附加拉直沿线配线图（长杆路）
    // —— 本次新增（均带默认值，旧调用点无需修改）——
    DxfVersion version = DxfVersion.r12, // 默认 R12（已用 ezdxf 严格打开验证）
    double rangeM = 50, // 底图范围（米）：默认沿线 50（UI 传值优先）
    bool layerRoads = true,
    bool layerBuildingOutline = true,
    bool buildingFill = false, // 建筑填充（默认关；true 时 R2000=HATCH / R12=SOLID）
    bool showMinorRoadNames = false, // service/other 也标路名（默认只标主干道以上）
    bool layerPlaces = true,
    bool placesTdtFallback = true, // 地名兜底（高德优先，回落天地图）
    String tdtKey = '',
    String amapKey = '', // 高德 Web 服务 key（有则优先用于地名兜底）
    String overpassEndpoints = '', // 自定义 Overpass 端点（优先于内置；空=用内置）
    bool convertGcj = true, // 高德/天地图检索 POI 为 GCJ-02，默认纠偏为 WGS84
    bool refreshBasemap = false, // 刷新底图（忽略缓存重新抓取）
    BasemapData? basemap, // 已取好的底图（测试注入 / 复用）
    BasemapData? localBasemap, // 导入的本地开源矢量底图（离线优先）
    int localBasemapFeatureCap =
        GeoJsonImporter.defaultFeatureCap, // 本地底图要素数上限（防御性兜底）
    String segPrefix = '', // 段标前缀（如 埋／架）：空串=仅数字；透传自 AppState.segPrefix
  }) async {
    final warnings = <String>[];
    final dir = await LabelStore.instance.exportDir();
    final f = File('${dir.path}/${sanitizeName(name)}.dxf');

    if (labels.isEmpty) throw Exception('杆路为空');

    final sb = StringBuffer();
    final h = _H();
    final c = _Ctx(sb, version, h);

    // DXF 头：声明 GBK 代码页（两版本一致），AutoCAD 中文版按此读取文字不乱码。
    // R2000 需完整 HEADER+`$HANDSEED`+范围变量；`$HANDSEED` 与图幅范围用占位符，
    // 待实体写完后回填（句柄分配器此刻才知道最终值）。
    if (version == DxfVersion.r2000) {
      sb.write('0\nSECTION\n2\nHEADER\n');
      sb.write('9\n\$ACADVER\n1\nAC1015\n');
      sb.write('9\n\$DWGCODEPAGE\n3\nANSI_936\n');
      sb.write('9\n\$INSBASE\n10\n0.000\n20\n0.000\n30\n0.000\n');
      sb.write('9\n\$LIMMIN\n10\n0.000\n20\n0.000\n');
      sb.write('9\n\$LIMMAX\n10\n420.000\n20\n297.000\n');
      sb.write('9\n\$EXTMIN\n10\n@@EXTMINX@@\n20\n@@EXTMINY@@\n30\n0.000\n');
      sb.write('9\n\$EXTMAX\n10\n@@EXTMAXX@@\n20\n@@EXTMAXY@@\n30\n0.000\n');
      sb.write('9\n\$HANDSEED\n5\n@@HANDSEED@@\n');
      sb.write('0\nENDSEC\n');
      sb.write(_classesSection);
    } else {
      sb.write('0\nSECTION\n2\nHEADER\n');
      sb.write('9\n\$DWGCODEPAGE\n3\nANSI_936\n');
      sb.write('9\n\$ACADVER\n1\nAC1009\n');
      sb.write('0\nENDSEC\n');
    }

    // 表（图层 + 文字样式）：R2000 写记录句柄与子类标记，R12 维持原样。
    _appendTables(c, version, completionRed);

    // 符号块定义：INSERT 引用，CAD 中可整体移动/复制/编辑（对齐图例）。
    _appendBlocksSection(c, version);

    // 实体段
    sb.write('0\nSECTION\n2\nENTITIES\n');

    // 本地投影基准点（第一个点）
    final baseLon = labels.first.lon;
    final baseLat = labels.first.lat;
    final scaleX = 111320.0 * math.cos(baseLat * math.pi / 180);
    const scaleY = 110540.0;

    // 实体包围盒（米，本地坐标）：用于图签/指北针定位，随周边矢量扩展
    var extMinX = 0.0, extMinY = 0.0, extMaxX = 0.0, extMaxY = 0.0;
    for (final l in labels) {
      final x = (l.lon - baseLon) * scaleX;
      final y = (l.lat - baseLat) * scaleY;
      if (x < extMinX) extMinX = x;
      if (x > extMaxX) extMaxX = x;
      if (y < extMinY) extMinY = y;
      if (y > extMaxY) extMaxY = y;
    }

    // 沿线总长度（图签用）
    var routeTotalLen = 0.0;
    // 桩号跨线组连续累计：续画链/分支链不再从 K0+000 重新归零，
    // 全线桩号沿链输出顺序一杆接一杆递增（与竣工里程口径一致）。
    var globalCum = 0.0;

    // 图幅比例：**只按线路范围估算**（不被过大的底图外扩拖大），
    // 用于所有底图线宽/字号的「纸面毫米 → 图纸米」换算，图签亦报此比例（N5 修正）。
    final routeScale = _pickScale(extMinX, extMinY, extMaxX, extMaxY);
    // 字高按**纸面毫米**换算（v3.9.5）：此前直接写 2.5/3 被当作 2.5 米，
    // 图上极其巨大。用户要求：距离 2.5mm（宋体），其余与它和谐匹配。
    final segFontM = _mmOf(2.5, routeScale);
    final subFontM = _mmOf(1.6, routeScale);
    final labelFontM = _mmOf(2.0, routeScale);
    final noteFontM = _mmOf(1.5, routeScale);

    // 周边矢量（底图）：**必须先于业务实体写出**。
    // DXF 中「后画者在上层」（见 _appendBasemap 内注释），故底图（含建筑填充 HATCH/SOLID）
    // 必须先画，业务层（杆路/配线/桩号/标签）后画，才能保证业务层最终置顶、
    // 不被底图填充盖住（设计 §P0-5 业务层置顶；A6 绘制顺序）。
    // 数据来源优先级：导入的本地开源矢量（离线）> 注入/缓存/网络抓取。
    BasemapFetchReport? report;
    if (includeSurroundings) {
      final BasemapData bm;
      if (localBasemap != null) {
        // 本地底图也尊重「范围档位」：裁到线路外扩 bbox，做到「只导出范围内」。
        // **裁剪结果为空时必须就用空底图**（`bm = cropped`）——**绝不回退全量**。
        // 旧实现「裁剪为空则回退全量」是用户每次导出 ≈50MB 的根因：线路一旦落在
        // 底图数据空白处（如罗山/光山/新县农村），裁剪为空 → 回退 → 整个信阳
        // 4.4 万要素全写进 DXF。此处改为「空就是空 + 明确中文提示」，绝不兜底全量。
        final bbox = BasemapFetcher.boundsOf(labels, rangeM);
        var cropped = GeoJsonImporter.cropTo(
          localBasemap,
          bbox,
          toleranceM: rangeM * 0.1, // 框边界适度外扩，避免路口被切断得太碎
        );
        // R3 防御性上限：进入渲染前兜底截断，防病态巨型文件（详见 capFeatures 文档）。
        cropped = GeoJsonImporter.capFeatures(
          cropped,
          routePts: [
            for (final l in labels) [l.lat, l.lon]
          ],
          cap: localBasemapFeatureCap,
          warnings: warnings,
        );
        final empty = cropped.roads.isEmpty &&
            cropped.buildings.isEmpty &&
            cropped.places.isEmpty;
        if (empty) {
          warnings.add(
              '本地底图：线路外扩 ${rangeM.round()} 米范围内无底图数据，本次未使用底图'
              '（可增大范围档位，或检查该区域底图数据覆盖）');
        }
        bm = cropped;
      } else if (basemap != null) {
        bm = basemap;
      } else {
        bm = await BasemapFetcher.fetchFor(
          labels,
          rangeM: rangeM,
          tdtKey: tdtKey,
          amapKey: amapKey,
          overpassEndpoints: overpassEndpoints,
          useTdt: placesTdtFallback,
          convertGcj: convertGcj,
          refresh: refreshBasemap,
        );
      }
      report = bm.report;
      warnings.addAll(bm.report.toWarnings());
      // 本地底图的文字缓冲与主实体共用同一句柄分配器（见 _Ctx 文档）。
      final ext = _appendBasemap(
        c,
        bm,
        version,
        routeScale,
        baseLon: baseLon,
        baseLat: baseLat,
        scaleX: scaleX,
        scaleY: scaleY,
        layerRoads: layerRoads,
        layerBuildingOutline: layerBuildingOutline,
        buildingFill: buildingFill,
        showMinorRoadNames: showMinorRoadNames,
        layerPlaces: layerPlaces,
      );
      if (ext != null) {
        if (ext[0] < extMinX) extMinX = ext[0];
        if (ext[1] < extMinY) extMinY = ext[1];
        if (ext[2] > extMaxX) extMaxX = ext[2];
        if (ext[3] > extMaxY) extMaxY = ext[3];
      }
    }

    // 杆路输出（统一链口径）：箱体/文字插在两杆之间不再剪断杆路；
    // 管廊模式 = 整链一条闭合偏移多段线（转角自然对接，不再逐段封口出头）；
    // 同时累计里程输出桩号（ZhuangHao 层，K0+000 格式），段上标注盘留与光缆型号。
    for (final chain in buildLabelChains(labels)) {
      if (chain.length < 2) continue;
      final cart = [
        for (final l in chain)
          [(l.lon - baseLon) * scaleX, (l.lat - baseLat) * scaleY]
      ];
      if (corridorWidth > 0) _appendCorridor(c, cart, corridorWidth, version);

      var chainCum = globalCum;
      for (var i = 1; i < chain.length; i++) {
        final a = chain[i - 1];
        final b = chain[i];
        _appendLine(c, 'GanLu', cart[i - 1][0], cart[i - 1][1],
            cart[i][0], cart[i][1]);

        final mx = (cart[i - 1][0] + cart[i][0]) / 2;
        final my = (cart[i - 1][1] + cart[i][1]) / 2;
        var angle = math.atan2(cart[i][1] - cart[i - 1][1],
                cart[i][0] - cart[i - 1][0]) *
            180 /
            math.pi;
        if (angle > 90 || angle < -90) angle += 180;
        final segmentDistance =
            b.distanceM ?? _haversine(a.lat, a.lon, b.lat, b.lon);
        routeTotalLen += segmentDistance;
        chainCum += segmentDistance;
        final segText = GeoUtil.segTextFor(b, _formatDistNoUnit(segmentDistance),
            prefix: segPrefix);
        // 宋体（STYLE 表里注册的是 SimSun）；字高 2.5 —— 用户指定。
        _text(c, 'JuLi', mx, my + 1.2, segFontM, segText,
            angle: angle, style: true);
        // 盘留标注（段下方第一行）
        var extraY = my - 3.4;
        if (b.slackM > 0) {
          _text(c, 'JuLi', mx, extraY, subFontM, '盘留${_formatSlack(b.slackM)}m',
              angle: angle, style: true);
          extraY -= 2.6;
        }
        // 本段光缆型号（再下一行）
        if (b.segCable.trim().isNotEmpty) {
          _text(c, 'JuLi', mx, extraY, subFontM, b.segCable.trim(),
              angle: angle, style: true);
        }
        // 桩号：每杆位置标 K+里程（跨链连续；段距优先用人工确认值）
        if (showStakes) {
          if (i == 1) _appendStake(c, cart[0][0], cart[0][1], globalCum);
          _appendStake(c, cart[i][0], cart[i][1], chainCum);
        }
      }
      globalCum = chainCum;
    }

    // 拓扑存在性提前判定：有拓扑时箱体文字改由地理式配线（标签牌）输出，避免重复
    var hasTopo = false;
    for (final l in labels) {
      if (l.topoParentId.isNotEmpty) {
        hasTopo = true;
        break;
      }
    }

    // 标签符号按图例转成 CAD 符号块（INSERT 引用，可在 CAD 中整体编辑）。
    // 轨迹/无标签点不输出符号。
    if (includeLabelSymbols) {
      // 符号与文字同一坐标体系（对照通信工程图纸）：块基准 = 1:1000 纸面 mm，
      // 插入缩放 = routeScale/1000；文字偏移一律**纸面毫米**，不再用米。
      final symScale = routeScale / 1000.0;
      final offUpM = _mmOf(3.0, routeScale); // 名称在符号上方 3mm
      final offDownM = _mmOf(4.0, routeScale); // 孔数/附加在下方 4mm
      final offNoteM = _mmOf(6.0, routeScale); // 备注 6mm
      final offPhotoM = _mmOf(8.0, routeScale); // 照片数 8mm
      final holeDotsUpM = _mmOf(5.5, routeScale); // 芯线占用点 5.5mm
      for (final l in labels) {
        if (l.typeId == 'track' || l.typeId == 'none') continue;
        final x = (l.lon - baseLon) * scaleX;
        final y = (l.lat - baseLat) * scaleY;
        final lt = l.type;
        final disp = l.name.trim().isNotEmpty ? l.name.trim() : lt.symbol;
        if (l.typeId == 'text') {
          if (disp.isNotEmpty) {
            _text(c, 'BiaoQian', x, y, labelFontM, disp, style: true);
          }
          continue;
        }
        String block;
        if (lt.isOval) {
          block = 'HZ_OVAL';
        } else if (lt.isBox) {
          block = 'HZ_BOX';
        } else if (lt.isTri) {
          block = 'HZ_TRI';
        } else {
          block = 'HZ_POLE';
        }
        // 箱体/人孔（box/oval）：**矩形框随文字自适应、文字在框内**——
        // 对照真实通信图纸（分纤盒/接头盒画法）：框宽=文字宽+2mm 边距，
        // 框高=字高+1.6mm 边距；交接箱额外画对角线 X（行业符号）。
        if (lt.isBox || lt.isOval) {
          if (disp.isNotEmpty) {
            var wChars = 0.0;
            for (final ch in disp.runes) {
              wChars += ch < 128 ? 0.55 : 1.0;
            }
            final textW = wChars * labelFontM;
            final boxW = textW + _mmOf(2.0, routeScale);
            final boxH = labelFontM + _mmOf(1.6, routeScale);
            _appendRect(c, 'BiaoQian', x - boxW / 2, y - boxH / 2,
                x + boxW / 2, y + boxH / 2);
            if (lt.id == 'crossbox') {
              // 交接箱 = 矩形 + 对角线 X（通信行业符号）
              _appendLine(c, 'BiaoQian', x - boxW / 2, y - boxH / 2,
                  x + boxW / 2, y + boxH / 2);
              _appendLine(c, 'BiaoQian', x - boxW / 2, y + boxH / 2,
                  x + boxW / 2, y - boxH / 2);
            }
            _appendTextCentered(c, 'BiaoQian', x, y, labelFontM, disp);
          } else {
            _appendInsert(c, 'BiaoQian', block, x, y, sx: symScale, sy: symScale);
          }
        } else {
          _appendInsert(c, 'BiaoQian', block, x, y, sx: symScale, sy: symScale);
        }
        // 有拓扑时箱体（光交/分光箱/分纤盒/ONU/机房/基站）的文字
        // 由地理式配线统一输出标签牌，这里只画符号，避免文字重叠
        final topoBox = hasTopo && (lt.role >= 1 && lt.role <= 4 || lt.role == 7);
        if (topoBox) {
          _appendHoleDots(c, x, y + 5.5, l); // 芯线/管孔占用可视化
          continue;
        }
        // 箱体/人孔文字已在框内（上方入框画法）；杆/引上文字在符号上方。
        if (!lt.isBox && !lt.isOval && disp.isNotEmpty) {
          _text(c, 'BiaoQian', x, y + offUpM, labelFontM, disp, style: true);
        }
        if (l.holes > 0) {
          _appendHoleDots(c, x, y + holeDotsUpM, l);
          _text(c, 'BiaoQian', x, y - offDownM, noteFontM,
              '${l.holes}孔${l.usedHoles > 0 ? '用${l.usedHoles}' : ''}',
              style: true);
        }
        if (l.note.trim().isNotEmpty) {
          _text(c, 'BiaoQian', x, y - offNoteM, noteFontM, l.note.trim(),
              style: true);
        }
        // 现场取证照片数（竣工溯源：CAD 图上知道该点有 N 张现场照片）
        if (l.photoPaths.isNotEmpty) {
          _text(c, 'BiaoQian', x, y - offPhotoM, noteFontM,
              '[${l.photoPaths.length}图]', style: true);
        }
      }
    }

    // 配线（地理式，对齐手绘样图）：拓扑父子箱体在路由图真实位置上用粗黑线连接，
    // 沿线标注箱体间距离与光缆型号，箱体上方挂标签牌（名称/分光比/备注）。
    if (hasTopo) {
      try {
        _appendTopoGeo(c, labels, baseLon, baseLat, scaleX, scaleY, version);
      } catch (e) {
        // 拓扑异常不阻塞路由图导出（如节点数据不全）
      }
    }

    // 拉直沿线配线图（可选附加，长杆路出图）：放路由图右侧，按 500m 分图幅。
    if (hasTopo && straightenedWiring) {
      try {
        var minLatW = 90.0, maxLatW = -90.0, maxLonW = -180.0;
        for (final l in labels) {
          if (l.lat < minLatW) minLatW = l.lat;
          if (l.lat > maxLatW) maxLatW = l.lat;
          if (l.lon > maxLonW) maxLonW = l.lon;
        }
        final routeW = (maxLonW - labels.first.lon) * scaleX;
        final ox = routeW + 60; // 配线图原点 X（路由图右侧留白）
        final oyTop = (maxLatW - baseLat) * scaleY; // 顶部对齐路由图顶部
        final wiringExtent = _appendWiringDiagram(c, labels, ox, oyTop,
            baseLon, baseLat, scaleX, scaleY, version);
        if (wiringExtent[0] > extMaxX) extMaxX = wiringExtent[0];
        if (wiringExtent[1] < extMinY) extMinY = wiringExtent[1];
        if (wiringExtent[2] > extMaxY) extMaxY = wiringExtent[2];
      } catch (e) {
        // 拉直配线异常不阻塞主图导出
      }
    }

    // 图框（A3 幅面自动比例）+ 图例栏 + 指北针 + 图签（对齐设计院图纸习惯）
    _appendFrame(c, extMinX, extMinY, extMaxX, extMaxY);
    if (showLegend) {
      _appendLegend(c, labels, extMinX, extMinY);
    }
    _appendNorthArrow(c, extMaxX, extMaxY);
    _appendTitleBlock(c, extMinX, extMinY, extMaxX, extMaxY,
        name: name,
        totalPoints: labels.length,
        totalLength: routeTotalLen,
        scale: routeScale);

    sb.write('0\nENDSEC\n');

    // OBJECTS 段（R2000 必需）：根命名对象字典 + ACAD_GROUP。
    if (version == DxfVersion.r2000) {
      _appendObjectsSection(c);
    }

    sb.write('0\nEOF\n');

    // 回填 R2000 HEADER 占位符（句柄种子 / 图幅范围）
    var text = sb.toString();
    if (version == DxfVersion.r2000) {
      text = text
          .replaceFirst('@@HANDSEED@@', h.nextValue.toRadixString(16).toUpperCase())
          .replaceFirst('@@EXTMINX@@', _fmt(extMinX))
          .replaceFirst('@@EXTMINY@@', _fmt(extMinY))
          .replaceFirst('@@EXTMAXX@@', _fmt(extMaxX))
          .replaceFirst('@@EXTMAXY@@', _fmt(extMaxY));
    }

    // 【防复发闸门】产出前用「严格结构校验器」自检：结构不合法立即抛错，
    //  绝不再把「打不开的文件」写盘（上批正是被字符串断言骗过去才出的事故）。
    final problems = DxfStructureValidator.validate(text, version: version);
    if (problems.isNotEmpty) {
      throw StateError('DXF 结构校验未通过，已阻止写出非法文件：\n- ${problems.join('\n- ')}');
    }

    // 两版本均用 GBK 字节写盘（中文 CAD 默认 ANSI_936 代码页），避免乱码
    await robustWriteBytes(f, _gbkEncode(text));
    return DxfExportResult(f, warnings, report);
  }

  /// GBK 编码（带一次幂等重试）。
  ///
  /// `gbk_codec` 的全局 codec `gbk_bytes` 是**惰性初始化**的顶层变量，其构造会
  /// 构建约两万余项的码表字面量；在极端并行负载（如 `flutter test` 全量并发）
  /// 下首次初始化偶发瞬时失败（报
  /// `type 'List<dynamic>' is not a subtype of type 'String'`；
  /// Dart 惰性初始化抛出后，下次访问会重新执行初始化）。
  /// 此处重试一次：**输出字节完全不变**，不改 DXF/GBK 任何语义。
  static List<int> _gbkEncode(String text) {
    try {
      return gbk_bytes.encode(text);
    } catch (_) {
      return gbk_bytes.encode(text); // 二次访问重新执行惰性初始化
    }
  }

  // ---- 实体输出辅助 ----

  /// 通用单行文字。R12/R2000 共用。
  /// - [style] 时写 `7 SimSun`（既有业务文字，保持不变）；
  /// - [styleName] 指定具体文字样式名（如路名的 `SongTi`），优先于 [style]；
  /// - [angle] 非空时写旋转 `50`。
  static void _text(_Ctx c, String layer, double x, double y, double h,
      String text, {double? angle, bool style = false, String? styleName}) {
    final t = text.replaceAll('\r', ' ').replaceAll('\n', ' ');
    final sn = styleName ?? (style ? 'SimSun' : null);
    c.ent('TEXT', layer, 'AcDbText');
    if (sn != null) c.sb.write('7\n$sn\n');
    c.sb.write('10\n${_fmt(x)}\n20\n${_fmt(y)}\n30\n0\n40\n${_fmt(h)}\n');
    if (angle != null) c.sb.write('50\n${angle.toStringAsFixed(1)}\n');
    c.sb.write('1\n$t\n');
    if (c.r2000) c.sb.write('100\nAcDbText\n');
  }

  static void _appendLine(_Ctx c, String layer,
      double x1, double y1, double x2, double y2) {
    c.ent('LINE', layer, 'AcDbLine');
    c.sb.write('10\n${_fmt(x1)}\n20\n${_fmt(y1)}\n30\n0\n11\n'
        '${_fmt(x2)}\n21\n${_fmt(y2)}\n31\n0\n');
  }

  /// 多段线（**版本分支**）：
  /// - R2000 → `LWPOLYLINE`（`90` 点数 / `70` 闭合位 / `43` 常宽）；
  /// - R12   → 经典 `POLYLINE/VERTEX/SEQEND`（`40`/`41` 常宽）。
  ///
  /// [closed] 为 true 时闭合（如建筑轮廓）；[width] > 0 写常宽。
  static void _appendPolyline(_Ctx c, String layer,
      List<List<double>> pts,
      {bool closed = false,
      double width = 0,
      DxfVersion version = DxfVersion.r12}) {
    if (pts.length < 2) return;
    if (version == DxfVersion.r2000) {
      c.ent('LWPOLYLINE', layer, 'AcDbPolyline');
      c.sb.write('90\n${pts.length}\n70\n${closed ? 1 : 0}\n');
      if (width > 0) c.sb.write('43\n${_fmt(width)}\n');
      for (final p in pts) {
        c.sb.write('10\n${_fmt(p[0])}\n20\n${_fmt(p[1])}\n');
      }
    } else {
      c.sb.write('0\nPOLYLINE\n8\n$layer\n66\n1\n70\n${closed ? 1 : 0}\n');
      if (width > 0) {
        c.sb.write('40\n${_fmt(width)}\n41\n${_fmt(width)}\n');
      }
      for (final p in pts) {
        c.sb.write('0\nVERTEX\n8\n$layer\n'
            '10\n${_fmt(p[0])}\n20\n${_fmt(p[1])}\n30\n0\n');
      }
      c.sb.write('0\nSEQEND\n8\n$layer\n');
    }
  }

  /// 管廊双线：整链一条闭合偏移多段线（转角用平均法向自然对接，
  /// 不再逐段独立封口导致转角出头）。
  static void _appendCorridor(_Ctx c, List<List<double>> pts, double w,
      DxfVersion version) {
    if (pts.length < 2 || w <= 0) return;
    final n = pts.length;
    final nrm = _avgNormals(pts);
    final w2 = w / 2.0;
    final outline = <List<double>>[
      for (var i = 0; i < n; i++)
        [pts[i][0] + nrm[i][0] * w2, pts[i][1] + nrm[i][1] * w2],
      for (var i = n - 1; i >= 0; i--)
        [pts[i][0] - nrm[i][0] * w2, pts[i][1] - nrm[i][1] * w2],
    ];
    _appendPolyline(c, 'GuanLang', outline, closed: true, version: version);
  }

  /// 折线各顶点平均法向（转角两侧线段法向均值归一化；端点用自身线段法向）。
  /// 管廊双线与道路双线描边共用此算法（转角自然对接，不出头）。
  static List<List<double>> _avgNormals(List<List<double>> pts) {
    final n = pts.length;
    final nrm = <List<double>>[];
    for (var i = 0; i < n; i++) {
      List<double> dPrev, dNext;
      if (i == 0) {
        dPrev = dNext = _dir(pts[0], pts[1]);
      } else if (i == n - 1) {
        dPrev = dNext = _dir(pts[n - 2], pts[n - 1]);
      } else {
        dPrev = _dir(pts[i - 1], pts[i]);
        dNext = _dir(pts[i], pts[i + 1]);
      }
      var nx = -(dPrev[1] + dNext[1]) / 2;
      var ny = (dPrev[0] + dNext[0]) / 2;
      final len = math.sqrt(nx * nx + ny * ny);
      if (len < 1e-9) {
        nx = -dPrev[1];
        ny = dPrev[0];
      } else {
        nx /= len;
        ny /= len;
      }
      nrm.add([nx, ny]);
    }
    return nrm;
  }

  /// 沿折线法向整体偏移 [off] 米（正=左法向，负=右法向），返回偏移后折线（不闭合）。
  static List<List<double>> _offsetPolyline(List<List<double>> pts, double off) {
    final n = pts.length;
    if (n < 2) return const [];
    final nrm = _avgNormals(pts);
    return [
      for (var i = 0; i < n; i++)
        [pts[i][0] + nrm[i][0] * off, pts[i][1] + nrm[i][1] * off]
    ];
  }

  static List<double> _dir(List<double> a, List<double> b) {
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-9) return [1.0, 0.0];
    return [dx / len, dy / len];
  }

  /// 指北针：图框内右上角，圆 + N 字 + 指针三角。
  static void _appendNorthArrow(_Ctx c, double maxX, double maxY) {
    final cx = maxX - 14;
    final cy = maxY - 12;
    const r = 6.0;
    // 外圆（R12 直接输出 CIRCLE）
    c.ent('CIRCLE', 'BeiFangZhen', 'AcDbCircle');
    c.sb.write('10\n${_fmt(cx)}\n20\n${_fmt(cy)}\n30\n0\n40\n${_fmt(r)}\n');
    // 指针三角：尖朝上
    _appendTri(c, 'BeiFangZhen', cx, cy - 0.8, 2.4);
    // N 字
    _appendTextCentered(c, 'BeiFangZhen', cx, cy + r + 1.5, 3.5, 'N');
  }

  /// A3 图框：内容包围盒外加 10m 边距画边框。
  static void _appendFrame(_Ctx c, double minX,
      double minY, double maxX, double maxY) {
    const m = 10.0;
    final x0 = minX - m, y0 = minY - m;
    final x1 = maxX + m, y1 = maxY + m;
    _appendRect(c, 'TuQian', x0, y0, x1, y1);
  }

  /// 按 A3 幅面估算比例：**仅按线路包围盒** 较长边(米) ÷ 可打印宽(约 0.40m)，
  /// 向上对齐标准比例系列（1:100 … 1:10000）。
  /// 只用于"线路范围"（不被过大的底图外扩拖大），供底图线宽/字号换算与图签报告。
  ///
  /// **取 max(跨度X, 跨度Y) 作为内容尺寸**：南北向线路跨度 X≈0，若只看 X 会把比例
  /// 估到最小档，线宽/字号随之异常（O4 修正）；用较长边对横/纵两种走向都稳健。
  static int _pickScale(double minX, double minY, double maxX, double maxY) {
    const m = 10.0;
    final spanX = (maxX - minX).abs();
    final spanY = (maxY - minY).abs();
    final contentW = (math.max(spanX, spanY) + 2 * m).clamp(1.0, 1e9);
    final raw = contentW / 0.40;
    const std = [100, 200, 250, 500, 1000, 2000, 2500, 5000, 10000];
    for (final s in std) {
      if (raw <= s) return s;
    }
    return (raw / 1000).ceil() * 1000;
  }

  /// 图例栏：图框内左下角，纵向排列本次用到的符号 + 类型名。
  static void _appendLegend(_Ctx c, List<MapLabel> labels,
      double minX, double minY) {
    final used = <String>{};
    for (final l in labels) {
      if (l.typeId == 'track' || l.typeId == 'none' || l.typeId == 'text') {
        continue;
      }
      used.add(l.typeId);
    }
    if (used.isEmpty) return;
    // 按 LabelType.all 的顺序输出，保持图例口径一致
    final ordered = LabelType.all.where((t) => used.contains(t.id)).toList();
    const m = 10.0;
    var y = minY - m + 4;
    final lx = minX - m + 4;
    _text(c, 'TuQian', lx, y + 6, 3, '图  例');
    for (final t in ordered) {
      String block;
      if (t.isOval) {
        block = 'HZ_OVAL';
      } else if (t.isBox) {
        block = 'HZ_BOX';
      } else if (t.isTri) {
        block = 'HZ_TRI';
      } else {
        block = 'HZ_POLE';
      }
      _appendInsert(c, 'TuQian', block, lx + 2, y);
      _text(c, 'TuQian', lx + 5, y - 1, 2.5, t.name);
      y -= 6;
    }
  }

  /// 桩号文字：K0+000 格式（千米 + 米，米保留 1 位小数）。
  static void _appendStake(_Ctx c, double x, double y, double cum) {
    final km = cum ~/ 1000;
    final m = cum - km * 1000;
    final mStr = m.toStringAsFixed(1).padLeft(5, '0');
    _text(c, 'ZhuangHao', x + 1.5, y + 3, 2, 'K$km+$mStr');
  }

  /// 盘留数字格式：整数或 1 位小数。
  static String _formatSlack(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  /// 芯线/管孔占用可视化：一排小圆，已占用 = 圆内打叉，空闲 = 空心。
  /// 最多画 24 孔，避免一行拉太长。
  static void _appendHoleDots(_Ctx c, double cx, double cy, MapLabel l) {
    final n = l.holes;
    if (n <= 0 || n > 24) return;
    const r = 0.7, gap = 2.0;
    final x0 = cx - (n - 1) * gap / 2;
    final used = l.usedHoles.clamp(0, n);
    for (var i = 0; i < n; i++) {
      final x = x0 + i * gap;
      c.ent('CIRCLE', 'BiaoQian', 'AcDbCircle');
      c.sb.write('10\n${_fmt(x)}\n20\n${_fmt(cy)}\n30\n0\n40\n${_fmt(r)}\n');
      if (i < used) {
        // 占用孔：圆内打叉
        _appendLine(c, 'BiaoQian', x - r, cy - r, x + r, cy + r);
        _appendLine(c, 'BiaoQian', x - r, cy + r, x + r, cy - r);
      }
    }
  }

  /// 地理式配线（对齐手绘样图）：拓扑父子箱体在真实位置连粗黑线（宽 0.6），
  /// 沿线旋转标注箱体间距离与光缆型号；箱体上方挂标签牌（小矩形 + 名称），
  /// 牌下依次为分光比/孔数与备注。
  static void _appendTopoGeo(_Ctx c, List<MapLabel> labels,
      double baseLon, double baseLat, double scaleX, double scaleY,
      DxfVersion version) {
    final roots = Topology.buildTree(labels);
    Topology.assignTitles(roots);
    final nodes = Topology.flatten(roots);
    final pos = <String, List<double>>{};
    for (final n in nodes) {
      pos[n.src.id] = [
        (n.src.lon - baseLon) * scaleX,
        (n.src.lat - baseLat) * scaleY,
      ];
    }

    // 父子连线 + 段标注
    for (final n in nodes) {
      final p = n.parent;
      if (p == null) continue;
      final p1 = pos[p.src.id]!, p2 = pos[n.src.id]!;
      // 粗黑折线（R2000=LWPOLYLINE / R12 经典 POLYLINE 常宽 0.6）
      _appendPolyline(c, 'PeiXianTu', [p1, p2],
          width: 0.6, version: version);
      final dx = p2[0] - p1[0], dy = p2[1] - p1[1];
      final len = math.sqrt(dx * dx + dy * dy);
      var angle = len > 1e-6 ? math.atan2(dy, dx) * 180 / math.pi : 0.0;
      if (angle > 90 || angle < -90) angle += 180;
      final dist = _haversine(p.src.lat, p.src.lon, n.src.lat, n.src.lon);
      final mx = (p1[0] + p2[0]) / 2, my = (p1[1] + p2[1]) / 2;
      // 距离放线上方，光缆型号放线下方
      _text(c, 'PeiXianTu', mx, my + 1.2, 2.5, dist.toStringAsFixed(1),
          angle: angle, style: true);
      if (n.cable.isNotEmpty) {
        _text(c, 'PeiXianTu', mx, my - 2.6, 2, n.cable,
            angle: angle, style: true);
      }
    }

    // 箱体标签牌（对齐手绘图上"2槽位箱"式小牌）：牌内为名称，
    // 牌下依次为分光比/孔数、备注
    for (final n in nodes) {
      final xy = pos[n.src.id]!;
      final x = xy[0], y = xy[1];
      final title = n.title;
      final tagW = title.length * 2.6 + 3.0;
      _appendRect(c, 'PeiXianTu', x - tagW / 2, y + 3.5, x + tagW / 2, y + 7);
      _appendTextCentered(c, 'PeiXianTu', x, y + 4.2, 2.2, title);
      if (n.sub.isNotEmpty) {
        _appendTextCentered(c, 'PeiXianTu', x, y - 4.2, 2.2, n.sub);
      }
      final note = n.src.note.trim();
      if (note.isNotEmpty) {
        _appendTextCentered(c, 'PeiXianTu', x, y - 6.8, 2.2, note);
      }
    }
  }

  /// 图签：右下角矩形分格（约 120m × 30m），设计院图纸角标习惯。
  /// 内容：工程名 / 滑洲云图导出 / 导出日期 / 总点数·总长度 / A3 自动比例。
  static void _appendTitleBlock(
      _Ctx c, double minX, double minY, double maxX, double maxY,
      {required String name,
      required int totalPoints,
      required double totalLength,
      required int scale}) {
    const w = 120.0, h = 30.0;
    final x0 = maxX - w, y0 = minY;
    final x1 = maxX, y1 = minY + h;
    const rowH = h / 5; // 5 行分格
    _appendRect(c, 'TuQian', x0, y0, x1, y1);
    for (var i = 1; i < 5; i++) {
      _appendLine(c, 'TuQian', x0, y0 + rowH * i, x1, y0 + rowH * i);
    }
    final date = DateTime.now();
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final rows = <String>[
      (name.isEmpty ? '未命名项目' : name),
      '滑洲云图导出',
      dateStr,
      '总点数 $totalPoints · 总长度 ${_formatDistNoUnit(totalLength)}m',
      '比例 1:$scale（A3 幅面）',
    ];
    for (var i = 0; i < rows.length; i++) {
      _text(c, 'TuQian', x0 + 2, y0 + rowH * (i + 1) - rowH / 2 - 1.2,
          3.2, rows[i]);
    }
  }

  /// 椭圆符号：R12 无椭圆实体，用 N 段折线闭合近似。
  static void _appendOval(_Ctx c, String layer,
      double cx, double cy, double ra, double rb) {
    const n = 16;
    var px = cx + ra, py = cy;
    for (var i = 1; i <= n; i++) {
      final th = 2 * math.pi * i / n;
      final qx = cx + ra * math.cos(th);
      final qy = cy + rb * math.sin(th);
      _appendLine(c, layer, px, py, qx, qy);
      px = qx;
      py = qy;
    }
  }

  static void _appendRect(_Ctx c, String layer,
      double x0, double y0, double x1, double y1) {
    _appendLine(c, layer, x0, y0, x1, y0);
    _appendLine(c, layer, x1, y0, x1, y1);
    _appendLine(c, layer, x1, y1, x0, y1);
    _appendLine(c, layer, x0, y1, x0, y0);
  }

  static void _appendTri(_Ctx c, String layer, double cx, double cy, double s) {
    final ax = cx, ay = cy + s;
    final bx = cx - s * 0.87, by = cy - s * 0.5;
    final px = cx + s * 0.87, py = cy - s * 0.5;
    _appendLine(c, layer, ax, ay, bx, by);
    _appendLine(c, layer, bx, by, px, py);
    _appendLine(c, layer, px, py, ax, ay);
  }

  /// 符号块定义段：人孔椭圆 / 箱体 / 引上三角 / 杆路圆叉。
  static void _appendBlocksSection(_Ctx c, DxfVersion version) {
    c.sb.write('0\nSECTION\n2\nBLOCKS\n');
    // R2000 需 *Model_Space 块（实体属主 330=1F 指向它，句柄固定为 1F）。
    if (version == DxfVersion.r2000) {
      c.sb.write('0\nBLOCK\n5\n1F\n330\n0\n100\nAcDbEntity\n8\n0\n'
          '100\nAcDbBlockBegin\n2\n*Model_Space\n70\n0\n'
          '10\n0.000\n20\n0.000\n30\n0.000\n3\n*Model_Space\n1\n\n');
      c.sb.write('0\nENDBLK\n5\n${c.h.next()}\n330\n0\n100\nAcDbEntity\n8\n0\n'
          '100\nAcDbBlockEnd\n');
    }
    var b = StringBuffer();
    var bc = _Ctx(b, version, c.h);
    // 符号块基准尺寸 = **1:1000 出图比例下的纸面毫米值**（人孔 6×3.5mm、
    // 箱体 5×3mm、引上边 3mm、杆圆 r=1.2mm——通信工程制图惯例，符号远小
    // 于文字块、与字号协调）。插入时按 routeScale/1000 缩放（见符号循环）。
    _appendOval(bc, '0', 0, 0, 3.0, 1.75);
    _appendBlock(c, version, 'HZ_OVAL', b.toString());
    b = StringBuffer();
    bc = _Ctx(b, version, c.h);
    _appendRect(bc, '0', -2.5, -1.5, 2.5, 1.5);
    _appendBlock(c, version, 'HZ_BOX', b.toString());
    b = StringBuffer();
    bc = _Ctx(b, version, c.h);
    _appendTri(bc, '0', 0, 0, 1.5);
    _appendBlock(c, version, 'HZ_TRI', b.toString());
    b = StringBuffer();
    bc = _Ctx(b, version, c.h);
    bc.ent('CIRCLE', '0', 'AcDbCircle');
    bc.sb.write('10\n0\n20\n0\n30\n0\n40\n1.2\n');
    _appendLine(bc, '0', -1.2, 0, 1.2, 0);
    _appendLine(bc, '0', 0, -1.2, 0, 1.2);
    _appendBlock(c, version, 'HZ_POLE', b.toString());
    c.sb.write('0\nENDSEC\n');
  }

  static void _appendBlock(
      _Ctx c, DxfVersion version, String name, String body) {
    if (version == DxfVersion.r2000) {
      c.sb.write('0\nBLOCK\n5\n${c.h.next()}\n330\n0\n100\nAcDbEntity\n8\n0\n'
          '100\nAcDbBlockBegin\n2\n$name\n70\n0\n'
          '10\n0.000\n20\n0.000\n30\n0.000\n3\n$name\n1\n\n');
    } else {
      c.sb.write('0\nBLOCK\n8\n0\n2\n$name\n70\n0\n10\n0\n20\n0\n30\n0\n3\n$name\n');
    }
    c.sb.write(body);
    if (version == DxfVersion.r2000) {
      c.sb.write('0\nENDBLK\n5\n${c.h.next()}\n330\n0\n100\nAcDbEntity\n8\n0\n'
          '100\nAcDbBlockEnd\n');
    } else {
      c.sb.write('0\nENDBLK\n8\n0\n');
    }
  }

  static void _appendInsert(
      _Ctx c, String layer, String name, double x, double y,
      {double sx = 1, double sy = 1}) {
    c.ent('INSERT', layer, 'AcDbBlockReference');
    c.sb.write('2\n$name\n'
        '10\n${_fmt(x)}\n20\n${_fmt(y)}\n30\n0\n'
        '41\n${_fmt(sx)}\n42\n${_fmt(sy)}\n50\n0\n');
  }

  // ================= 配线图（DXF 内自动生成） =================

  /// 配线图（设计院沿线画法，可选附加）：把杆路主干拉直成水平主线（里程轴），
  /// 箱体按其在主干上的投影里程挂在主线上方，分支深度决定纵向层级。
  /// 超过 500m 自动分图幅（每幅一条主线，纵向堆叠），返回绘图范围
  /// [maxX, minY, maxY]（本地坐标，供整体包围盒扩展）。
  static List<double> _appendWiringDiagram(
      _Ctx c,
      List<MapLabel> labels,
      double ox,
      double oyTop,
      double baseLon,
      double baseLat,
      double scaleX,
      double scaleY,
      DxfVersion version) {
    final roots = Topology.buildTree(labels);
    Topology.assignTitles(roots);
    final nodes = Topology.flatten(roots);

    // ---- 1. 主链提取：按 lineGroupId 建索引，取累计长度最长的一条链作主干 ----
    final groups = <String, List<MapLabel>>{};
    for (final l in labels) {
      if (l.lineGroupId.isEmpty) continue;
      groups.putIfAbsent(l.lineGroupId, () => []).add(l);
    }
    var trunk = <MapLabel>[];
    var trunkLen = 0.0;
    for (final g in groups.values) {
      if (g.length < 2) continue;
      if (g.every(_isTrackPoint)) continue; // 轨迹链不当杆路主干
      var len = 0.0;
      for (var i = 1; i < g.length; i++) {
        len += _segDistance(g[i - 1], g[i]);
      }
      if (len > trunkLen) {
        trunkLen = len;
        trunk = g;
      }
    }
    if (trunk.length < 2) trunk = labels; // 兜底：无连线时全部点当主干

    // ---- 2. 主干里程：沿主链累计每杆里程（段距优先 distLabel，否则 haversine）----
    final cumMile = <double>[0.0];
    final trunkCart = <List<double>>[];
    for (var i = 0; i < trunk.length; i++) {
      final l = trunk[i];
      trunkCart.add([
        (l.lon - baseLon) * scaleX,
        (l.lat - baseLat) * scaleY,
      ]);
      if (i > 0) {
        cumMile.add(cumMile[i - 1] + _segDistance(trunk[i - 1], trunk[i]));
      }
    }

    // ---- 3. 箱体节点投影到主干：里程 → 横坐标 X，分支深度 → 纵向层级 ----
    for (final n in nodes) {
      var d = 0;
      for (var p = n.parent; p != null; p = p.parent) {
        d++;
      }
      n.y = d.toDouble();
      final p0 = [
        (n.src.lon - baseLon) * scaleX,
        (n.src.lat - baseLat) * scaleY,
      ];
      final proj = _projectOnChain(p0, trunkCart, cumMile);
      if (proj[1] <= 200) {
        n.x = proj[0];
      } else {
        n.x = n.parent?.x ?? 0;
      }
    }

    // ---- 4. 分图幅：每幅 500m，纵向堆叠间距 45m ----
    const bandW = 500.0;
    final totalMile = cumMile.isEmpty ? 0.0 : cumMile.last;
    final bandCount = math.max(1, (totalMile / bandW).ceil());
    var extMaxX = ox + bandW, extMinY = oyTop - 30, extMaxY = oyTop;

    for (var band = 0; band < bandCount; band++) {
      final xs = band * bandW;
      final xe = math.min(totalMile, xs + bandW);
      final mainY = oyTop - 25 - band * 45;
      // 主干粗线（按幅裁剪，宽 0.6）
      final clipped = _clipChainByMile(trunkCart, cumMile, xs, xe);
      if (clipped.length >= 2) {
        final pts = [
          for (final p in clipped) [ox + p[0] - xs, mainY]
        ];
        _appendPolyline(c, 'PeiXianTu', pts, width: 0.6, version: version);
      }
      // 沿线每杆位置画小刻度短线
      for (var i = 0; i < trunkCart.length; i++) {
        final mi = cumMile[i];
        if (mi < xs || mi > xe) continue;
        final x = ox + mi - xs;
        _appendLine(c, 'PeiXianTu', x, mainY - 2, x, mainY + 2);
      }
      // 图幅分幅线与标注
      if (bandCount > 1) {
        _text(c, 'PeiXianTu', ox, mainY + 8, 3,
            '第 ${band + 1}/$bandCount 幅（K${(xs / 1000).toStringAsFixed(1)}-K${(xe / 1000).toStringAsFixed(1)}）');
      }

      // 本幅内的箱体
      final inBand = nodes.where((n) => n.x >= xs && n.x <= xe).toList();
      // 防重叠：同深度按 X 排序，相邻间距 ≥ 20m；父 X ≤ 子 X - 10
      final byDepth = <int, List<TopoNode>>{};
      for (final n in inBand) {
        byDepth.putIfAbsent(n.y.toInt(), () => []).add(n);
      }
      for (final d in byDepth.keys) {
        final list = byDepth[d]!..sort((a, b) => a.x.compareTo(b.x));
        for (final n in list) {
          final p = n.parent;
          if (p != null && n.x < p.x + 10) n.x = p.x + 10;
        }
        for (var i = 1; i < list.length; i++) {
          if (list[i].x < list[i - 1].x + 20) list[i].x = list[i - 1].x + 20;
        }
      }

      // 箱体：挂接虚线 + 符号 + 名称/分光比
      for (final n in inBand) {
        final x = ox + n.x - xs;
        final y = mainY + 15 * n.y;
        if (n.y >= 1) {
          _appendDashedVLine(c, 'PeiXianTu', x, mainY + 1, y - 2.2);
        }
        _appendInsert(c, 'PeiXianTu', 'HZ_BOX', x, y);
        _appendTextCentered(c, 'PeiXianTu', x, y + 2.6, 2.8, n.title);
        if (n.sub.isNotEmpty) {
          _appendTextCentered(c, 'PeiXianTu', x, y - 3.6, 2.4, n.sub);
        }
        final note = n.src.note.trim();
        if (note.isNotEmpty) {
          _appendTextCentered(c, 'PeiXianTu', x, y - 6.4, 2.4, note);
        }
      }

      // 父子连线（同幅内才画）：竖-横-竖直角线，段上标注距离与光缆型号
      for (final n in inBand) {
        final p = n.parent;
        if (p == null) continue;
        if (p.x < xs || p.x > xe) continue; // 父在邻幅：跳过（避免跨幅乱线）
        final px = ox + p.x - xs, pyTop = mainY + 15 * p.y - 2.2;
        final cx = ox + n.x - xs, cyTop = mainY + 15 * n.y + 2.2;
        final midY = (pyTop + cyTop) / 2;
        if ((cx - px).abs() < 0.01) {
          _appendLine(c, 'PeiXianTu', px, pyTop, cx, cyTop);
        } else {
          _appendLine(c, 'PeiXianTu', px, pyTop, px, midY);
          _appendLine(c, 'PeiXianTu', px, midY, cx, midY);
          _appendLine(c, 'PeiXianTu', cx, midY, cx, cyTop);
        }
        final dist = _haversine(p.src.lat, p.src.lon, n.src.lat, n.src.lon);
        _text(c, 'PeiXianTu', cx + 2, midY + 1.2, 2.5, dist.toStringAsFixed(1),
            style: true);
        if (n.cable.isNotEmpty) {
          _text(c, 'PeiXianTu', cx + 2, midY - 2.2, 2.5, n.cable, style: true);
        }
      }

      if (ox + bandW > extMaxX) extMaxX = ox + bandW;
      final bandBottom = mainY - 15;
      if (bandBottom < extMinY) extMinY = bandBottom;
    }

    return [extMaxX, extMinY, extMaxY];
  }

  /// 把折线链按里程区间 [xs, xe] 裁剪，端点处线性插值。
  /// 返回 [起始里程, 途经里程…, 结束里程] 对应的链上点序列。
  static List<List<double>> _clipChainByMile(List<List<double>> chainPts,
      List<double> cumMile, double xs, double xe) {
    if (chainPts.isEmpty) return [];
    List<double> lerp(double mile) {
      for (var i = 1; i < chainPts.length; i++) {
        if (cumMile[i] >= mile) {
          final span = cumMile[i] - cumMile[i - 1];
          final t = span > 1e-9 ? (mile - cumMile[i - 1]) / span : 0.0;
          return [
            chainPts[i - 1][0] + t * (chainPts[i][0] - chainPts[i - 1][0]),
            chainPts[i - 1][1] + t * (chainPts[i][1] - chainPts[i - 1][1]),
          ];
        }
      }
      return chainPts.last;
    }

    final out = <List<double>>[];
    if (cumMile.last < xs || cumMile.first > xe) return out;
    out.add(lerp(xs));
    for (var i = 0; i < chainPts.length; i++) {
      if (cumMile[i] > xs && cumMile[i] < xe) out.add(chainPts[i]);
    }
    out.add(lerp(xe));
    return out;
  }

  /// 段距（标注优先口径）——唯一实现见 [GeoUtil.segLenLabelFirst]。
  /// 原先本文件自带一份拷贝，与 csv / archive_book 的同名私有方法逐字相同却各自演化。
  static double _segDistance(MapLabel a, MapLabel b) =>
      GeoUtil.segLenLabelFirst(a, b);

  /// 点到折线链的最近投影：返回 [投影里程, 垂距(米)]。
  /// chainPts 为笛卡尔坐标，cumMile 为每点累计里程。
  static List<double> _projectOnChain(List<double> p,
      List<List<double>> chainPts, List<double> cumMile) {
    var bestDist = double.infinity, bestMile = 0.0;
    for (var i = 1; i < chainPts.length; i++) {
      final s = chainPts[i - 1], e = chainPts[i];
      final dx = e[0] - s[0], dy = e[1] - s[1];
      final len2 = dx * dx + dy * dy;
      var t = 0.0;
      if (len2 > 1e-9) {
        t = ((p[0] - s[0]) * dx + (p[1] - s[1]) * dy) / len2;
        t = t.clamp(0.0, 1.0);
      }
      final qx = s[0] + t * dx, qy = s[1] + t * dy;
      final dist =
          math.sqrt((p[0] - qx) * (p[0] - qx) + (p[1] - qy) * (p[1] - qy));
      if (dist < bestDist) {
        bestDist = dist;
        bestMile = cumMile[i - 1] + t * (cumMile[i] - cumMile[i - 1]);
      }
    }
    return [bestMile, bestDist];
  }

  /// 竖直细虚线（短线段手工断开模拟）：x 固定，从 y1 到 y2（y2 > y1）。
  static void _appendDashedVLine(_Ctx c, String layer,
      double x, double y1, double y2) {
    if (y2 <= y1) return;
    const dash = 2.0, gap = 1.2;
    var y = y1;
    while (y < y2) {
      final ye = math.min(y + dash, y2);
      _appendLine(c, layer, x, y, x, ye);
      y = ye + gap;
    }
  }

  /// 近似居中 TEXT：汉字按全宽、字母数字按半宽估宽。
  static void _appendTextCentered(_Ctx c, String layer,
      double cx, double cy, double h, String text) {
    if (text.isEmpty) return;
    var w = 0.0;
    for (final r in text.runes) {
      w += r > 0x2E7F ? h : h * 0.55;
    }
    _text(c, layer, cx - w / 2, cy - h * 0.35, h, text);
  }

  // ---- 通用 ----

  static bool _isTrackPoint(MapLabel label) =>
      label.typeId == 'track' || label.typeId == 'none';

  static double _haversine(double la1, double lo1, double la2, double lo2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(la2 - la1);
    final dLon = rad(lo2 - lo1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(la1)) * math.cos(rad(la2)) *
            math.sin(dLon / 2) * math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// DXF 段标注的距离数字：**不带单位**（图纸单位由图层设定，即米）。
  ///
  /// 直接委托 [GeoUtil.segDistText] —— 屏上段标与图纸段标必须是同一个字符串。
  /// 这里曾经自己写 `toStringAsFixed(1)`，于是 ≥1km 的长杆档在屏幕上写「埋1.05km」、
  /// 在图上写「埋1050.0」；随后又改成"自己调 stripDotZero 但保留 km 分支"，仍会分叉。
  /// 现在规则只剩一处，再想分叉也没有地方写了。
  static String _formatDistNoUnit(double m) => GeoUtil.segDistText(m);

  static double _pointToLineDistance(List<double> point, List<double> lineStart, List<double> lineEnd) {
    final double dx = lineEnd[0] - lineStart[0];
    final double dy = lineEnd[1] - lineStart[1];
    if (dx == 0 && dy == 0) {
      // lineStart and lineEnd are the same point
      return math.sqrt((point[0] - lineStart[0]) * (point[0] - lineStart[0]) +
          (point[1] - lineStart[1]) * (point[1] - lineStart[1]));
    }
    final double t = ((point[0] - lineStart[0]) * dx + (point[1] - lineStart[1]) * dy) /
        (dx * dx + dy * dy);
    final double projectionX = lineStart[0] + t * dx;
    final double projectionY = lineStart[1] + t * dy;
    final double dxProj = point[0] - projectionX;
    final double dyProj = point[1] - projectionY;
    return math.sqrt(dxProj * dxProj + dyProj * dyProj);
  }

  static List<List<double>> _simplifyPath(List<List<double>> points, double tolerance) {
    if (points.length < 3) {
      return List.from(points);
    }
    final List<bool> markers = List.filled(points.length, false);
    markers[0] = true;
    markers[points.length - 1] = true;

    _simplifyPathRecursive(points, markers, 0, points.length - 1, tolerance);

    final List<List<double>> result = <List<double>>[];
    for (int i = 0; i < points.length; i++) {
      if (markers[i]) {
        result.add(points[i]);
      }
    }
    return result;
  }

  static void _simplifyPathRecursive(
      List<List<double>> points,
      List<bool> markers,
      int startIndex,
      int endIndex,
      double tolerance) {
    double maxDistance = 0.0;
    int index = 0;
    final List<double> startPoint = points[startIndex];
    final List<double> endPoint = points[endIndex];
    for (int i = startIndex + 1; i < endIndex; i++) {
      final double distance = _pointToLineDistance(points[i], startPoint, endPoint);
      if (distance > maxDistance) {
        maxDistance = distance;
        index = i;
      }
    }
    if (maxDistance > tolerance) {
      markers[index] = true;
      _simplifyPathRecursive(points, markers, startIndex, index, tolerance);
      _simplifyPathRecursive(points, markers, index, endIndex, tolerance);
    }
  }

  // ==================== 表段 / 对象段（版本 gate） ====================

  /// 写 TABLES 段：图层表 + 文字样式表。
  /// - R2000：表头/记录均写句柄 `5` + 属主 `330` + 子类标记 `100 AcDb*`；
  ///   图层追加 `370`（线宽 1/100mm）与 `420`（真彩）。
  /// - R12：维持原样（仅 `62`/`6`，无句柄/子类标记）。
  /// 竣工红（completionRed）时杆路/管廊 ACI 改 1。
  static void _appendTables(
      _Ctx c, DxfVersion version, bool completionRed) {
    final specs = DxfLayers.resolve(completionRed: completionRed);
    c.sb.write('0\nSECTION\n2\nTABLES\n');
    if (version == DxfVersion.r2000) {
      final layerTableH = c.h.next();
      c.sb.write('0\nTABLE\n2\nLAYER\n5\n$layerTableH\n330\n0\n'
          '100\nAcDbSymbolTable\n70\n${specs.length}\n');
      for (final s in specs) {
        c.sb.write('0\nLAYER\n5\n${c.h.next()}\n330\n$layerTableH\n'
            '100\nAcDbSymbolTableRecord\n100\nAcDbLayerTableRecord\n'
            '2\n${s.name}\n70\n0\n62\n${s.aci}\n6\n${s.lineType}\n');
        c.sb.write('370\n${s.lineWeight}\n');
        if (s.trueColor != null) c.sb.write('420\n${s.trueColor}\n');
      }
      c.sb.write('0\nENDTAB\n');
      final styleTableH = c.h.next();
      c.sb.write('0\nTABLE\n2\nSTYLE\n5\n$styleTableH\n330\n0\n'
          '100\nAcDbSymbolTable\n70\n2\n');
      c.sb.write('0\nSTYLE\n5\n${c.h.next()}\n330\n$styleTableH\n'
          '100\nAcDbSymbolTableRecord\n100\nAcDbTextStyleTableRecord\n'
          '2\nSimSun\n70\n0\n40\n0\n41\n1\n50\n0\n71\n0\n42\n3\n'
          '3\nSimSun.ttf\n4\n\n');
      // 路名专用宋体样式（ASCII 样式名避免编码问题；fontFile=宋体 simsun.ttc）。
      // 仅 DaoLu 层路名 TEXT 引用，其他文字样式保持不变。
      c.sb.write('0\nSTYLE\n5\n${c.h.next()}\n330\n$styleTableH\n'
          '100\nAcDbSymbolTableRecord\n100\nAcDbTextStyleTableRecord\n'
          '2\nSongTi\n70\n0\n40\n0\n41\n1\n50\n0\n71\n0\n42\n3\n'
          '3\nsimsun.ttc\n4\n\n');
      c.sb.write('0\nENDTAB\n0\nENDSEC\n');
    } else {
      c.sb.write('0\nTABLE\n2\nLAYER\n70\n${specs.length}\n');
      for (final s in specs) {
        c.sb.write('0\nLAYER\n2\n${s.name}\n70\n0\n62\n${s.aci}\n6\n${s.lineType}\n');
      }
      c.sb.write('0\nENDTAB\n');
      c.sb.write('0\nTABLE\n2\nSTYLE\n70\n2\n');
      c.sb.write('0\nSTYLE\n2\nSimSun\n70\n0\n40\n0\n41\n1\n50\n0\n71\n0\n42\n3\n3\nSimSun.ttf\n4\n\n');
      c.sb.write('0\nSTYLE\n2\nSongTi\n70\n0\n40\n0\n41\n1\n50\n0\n71\n0\n42\n3\n3\nsimsun.ttc\n4\n\n');
      c.sb.write('0\nENDTAB\n0\nENDSEC\n');
    }
  }

  /// OBJECTS 段（R2000 必需）：根命名对象字典 + ACAD_GROUP 子字典。
  static void _appendObjectsSection(_Ctx c) {
    final root = c.h.next();
    final group = c.h.next();
    c.sb.write('0\nSECTION\n2\nOBJECTS\n');
    c.sb.write('0\nDICTIONARY\n5\n$root\n330\n0\n100\nAcDbDictionary\n281\n1\n'
        '3\nACAD_GROUP\n350\n$group\n');
    c.sb.write('0\nDICTIONARY\n5\n$group\n330\n$root\n100\nAcDbDictionary\n281\n1\n');
    c.sb.write('0\nENDSEC\n');
  }

  // ==================== 底图渲染（T3） ====================

  /// 渲染底图（建筑填充(可选)→建筑轮廓→道路双线描边→路名→地名），文字统一后置输出。
  /// 返回底图几何的整体包围盒 `[minX, minY, maxX, maxY]`（供图框/图签扩展）。
  ///
  /// **所有线宽/字号均由「纸面毫米 ÷ 1000 × 出图比例 [scale]」换算为图纸米数。**
  static List<double>? _appendBasemap(
    _Ctx c,
    BasemapData bm,
    DxfVersion version,
    int scale, {
    required double baseLon,
    required double baseLat,
    required double scaleX,
    required double scaleY,
    required bool layerRoads,
    required bool layerBuildingOutline,
    required bool buildingFill,
    required bool showMinorRoadNames,
    required bool layerPlaces,
  }) {
    final acc = _Ext(double.infinity, double.infinity, -double.infinity,
        -double.infinity);
    // 文字后置：使底图注记压在底图几何之上（CAD 中后画者在上层）。
    // 注意：整段底图（含其文字）都先于业务层写出，故业务层仍整体置顶（P0-5）。
    // 底图文字缓冲与主体共用句柄分配器（c.h），避免重复句柄。
    final labelBuf = StringBuffer();
    final lc = _Ctx(labelBuf, version, c.h);

    // —— 建筑（先填充成块、再轮廓；文字后置）——
    if (buildingFill || layerBuildingOutline) {
      final ringsPerBld = <List<List<List<double>>>>[];
      for (final b in bm.buildings) {
        final rings = _toCartRings(b, baseLon, baseLat, scaleX, scaleY);
        ringsPerBld.add(rings);
        for (final ring in rings) {
          for (final p in ring) {
            acc.add(p[0], p[1]);
          }
        }
      }
      if (buildingFill) {
        for (final rings in ringsPerBld) {
          if (rings.isEmpty) continue;
          _appendBuildingFill(c, rings, version);
        }
      }
      if (layerBuildingOutline) {
        for (var i = 0; i < ringsPerBld.length; i++) {
          final rings = ringsPerBld[i];
          for (final ring in rings) {
            if (ring.length >= 3) {
              _appendPolyline(c, 'JianZhu', ring,
                  closed: true, version: version);
            }
          }
          final b = bm.buildings[i];
          if (b.name.isNotEmpty && rings.isNotEmpty) {
            final o = rings.first;
            var cx = 0.0, cy = 0.0;
            for (final p in o) {
              cx += p[0];
              cy += p[1];
            }
            cx /= o.length;
            cy /= o.length;
            final h = _mmOf(1.6, scale); // 建筑名 1.6mm
            _appendTextCentered(lc, 'JianZhu', cx, cy, h, b.name);
          }
        }
      }
    }

    // —— 道路（双线描边，按等级分级；路名居中标注可按等级过滤）——
    if (layerRoads) {
      for (final r in bm.roads) {
        _appendRoadDualAndCenter(c, lc, r, baseLon, baseLat, scaleX,
            scaleY, scale, version, acc, showMinorRoadNames);
      }
    }

    // —— 周边要素：电力线（DianLi，橙）/ 水系沟渠（ShuiXi，蓝）——
    // 通信线路设计必须与电力杆线的交越/平行关系一起看，过河过沟也要有参照。
    if (bm.extras.isNotEmpty) {
      for (final e in bm.extras) {
        final layer = e.kind == 'power' ? 'DianLi' : 'ShuiXi';
        final pts = <List<double>>[];
        for (final pt in e.pts) {
          pts.add([(pt[1] - baseLon) * scaleX, (pt[0] - baseLat) * scaleY]);
        }
        if (pts.length >= 2) {
          _appendPolyline(c, layer, pts, version: version);
          for (final q in pts) {
            acc.add(q[0], q[1]);
          }
        }
      }
    }

    // —— 地名（DiMing 层，字号按级别）——
    if (layerPlaces) {
      for (final p in bm.places) {
        final x = (p.lon - baseLon) * scaleX;
        final y = (p.lat - baseLat) * scaleY;
        _appendTextCentered(lc, 'DiMing', x, y,
            _mmOf(_placeFontMm(p.level), scale), p.name);
        acc.add(x, y);
      }
    }

    // 底图内部文字统一后置输出（底图几何之上；整体仍先于业务层写出）
    c.sb.write(labelBuf.toString());

    if (acc.minX > acc.maxX || acc.minY > acc.maxY) return null;
    return [acc.minX, acc.minY, acc.maxX, acc.maxY];
  }

  /// 道路双线描边分级画法（**不再 1:1 用真实路宽**；中心线已按新规格删除）。
  /// 路名默认只标 trunk/primary/secondary/tertiary/residential；
  /// [showMinorRoadNames] 为 true 时 service/other 也标。
  static void _appendRoadDualAndCenter(
    _Ctx c,
    _Ctx lc,
    RoadPoly rp,
    double baseLon,
    double baseLat,
    double scaleX,
    double scaleY,
    int scale,
    DxfVersion version,
    _Ext acc,
    bool showMinorRoadNames,
  ) {
    final cart = <List<double>>[
      for (final p in rp.pts) [(p[1] - baseLon) * scaleX, (p[0] - baseLat) * scaleY]
    ];
    // 按等级分档简化（主干细容差保留形态，小路大容差瘦身，N4）
    final simp = _simplifyPath(cart, _roadTolM(rp.grade));
    if (simp.length < 2) return;

    // 双线描边（casing）：半宽 = 纸面半宽 ÷ 1000 × 比例
    final halfW = _roadHalfWidthM(rp.grade, scale);
    if (halfW > 1e-6) {
      final left = _offsetPolyline(simp, halfW);
      final right = _offsetPolyline(simp, -halfW);
      if (left.length >= 2) {
        _appendPolyline(c, 'DaoLuBian', left, version: version);
      }
      if (right.length >= 2) {
        _appendPolyline(c, 'DaoLuBian', right, version: version);
      }
    }

    for (final p in simp) {
      acc.add(p[0], p[1]);
    }

    // 路名等级过滤：只过滤注记，**几何（DaoLuBian）一律保留**。
    final isMajor = switch (rp.grade) {
      RoadGrade.trunk ||
      RoadGrade.primary ||
      RoadGrade.secondary ||
      RoadGrade.tertiary ||
      RoadGrade.residential => true,
      RoadGrade.service || RoadGrade.other => false,
    };
    if (rp.name.isNotEmpty && (isMajor || showMinorRoadNames)) {
      _appendRoadName(lc, rp.name, simp, rp.grade, scale, halfW);
    }
  }

  /// 路名注记：**置于道路中心线上（即双线描边之间）**，字号 clamp 进双线间隙，
  /// 沿弧长每约 200 米一处（均匀分布），宋体（SongTi 样式），旋转不倒立。
  static void _appendRoadName(_Ctx lc, String name,
      List<List<double>> pts, RoadGrade grade, int scale, double halfW) {
    // 字号 clamp：必须放得进双线之间（0.6 系数留上下空隙）
    final h = math.min(_roadLabelM(grade, scale), 2 * halfW * 0.6);
    // clamp 后纸面高度下限：低于最小可读高度则该路不标注（塞不下，硬塞会糊）。
    // 注：现行分级半宽表下双线间隙最大 0.9mm（trunk），clamp 后字高最大 0.54mm，
    // 若按字面 1mm 阈值会把全部路名吞掉（与"尽量多保留路名"冲突），
    // 故取可读下限 0.10mm 纸面高度——仅病态窄路/未来表变更时兜底。
    if (h < _mmOf(0.10, scale)) return;
    var totalLen = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final dx = pts[i][0] - pts[i - 1][0];
      final dy = pts[i][1] - pts[i - 1][1];
      totalLen += math.sqrt(dx * dx + dy * dy);
    }
    if (totalLen < 1e-6) return;
    // 每约 200 米一处：n 处均匀分布，第 i 处（i=1..n）在弧长 totalLen*(2i-1)/(2n)
    //（n=1 时正好中点）
    final n = math.max(1, (totalLen / 200).round());
    var walked = 0.0; // 已走过弧长
    var idx = 1;
    for (var i = 1; i < pts.length && idx <= n; i++) {
      final s = pts[i - 1];
      final e = pts[i];
      final dx = e[0] - s[0], dy = e[1] - s[1];
      final segLen = math.sqrt(dx * dx + dy * dy);
      while (idx <= n) {
        final target = totalLen * (2 * idx - 1) / (2 * n);
        if (target > walked + segLen) break;
        final t = segLen > 1e-9 ? (target - walked) / segLen : 0.0;
        final px = s[0] + dx * t;
        final py = s[1] + dy * t;
        // 旋转不倒立：>90 或 <-90 时 +180（沿用既有逻辑）
        var angle = math.atan2(dy, dx) * 180 / math.pi;
        if (angle > 90 || angle < -90) angle += 180;
        _text(lc, 'DaoLu', px, py, h, name, angle: angle, styleName: 'SongTi');
        idx++;
      }
      walked += segLen;
    }
  }

  /// 建筑环 → 笛卡尔坐标环（丢弃 <3 点的环）。
  static List<List<List<double>>> _toCartRings(BuildingPoly b, double baseLon,
      double baseLat, double scaleX, double scaleY) {
    final out = <List<List<double>>>[];
    for (final ring in b.rings) {
      if (ring.length < 3) continue;
      out.add([
        for (final p in ring) [(p[1] - baseLon) * scaleX, (p[0] - baseLat) * scaleY]
      ]);
    }
    return out;
  }

  /// 建筑填充：R2000=`HATCH`（SOLID 图案，外环+孔）；R12=`SOLID` 三角近似（忽略孔）。
  static void _appendBuildingFill(_Ctx c,
      List<List<List<double>>> rings, DxfVersion version) {
    if (rings.isEmpty) return;
    final outer = rings.first;
    if (outer.length < 3) return;
    if (version == DxfVersion.r2000) {
      _appendHatch(c, 'JianZhuFill', rings);
    } else {
      _appendSolidFill(c, outer);
    }
  }

  /// R2000 HATCH（SOLID 图案）：以各环为多段线边界路径写入 `JianZhuFill`。
  static void _appendHatch(
      _Ctx c, String layer, List<List<List<double>>> rings) {
    final paths = <List<List<double>>>[
      for (final r in rings)
        if (r.length >= 3) r
    ];
    if (paths.isEmpty) return;
    c.ent('HATCH', layer, 'AcDbHatch');
    c.sb.write('62\n252\n2\nSOLID\n'
        '70\n1\n71\n0\n91\n${paths.length}\n');
    for (final path in paths) {
      // 92=7（External|Polyline|Derived），72=无凸度，73=闭合，93=顶点数
      c.sb.write('92\n7\n72\n0\n73\n1\n93\n${path.length}\n');
      for (final p in path) {
        c.sb.write('10\n${_fmt(p[0])}\n20\n${_fmt(p[1])}\n');
      }
      c.sb.write('97\n0\n');
    }
    c.sb.write('75\n0\n76\n1\n');
  }

  /// R12 SOLID 三角近似填充（耳切三角化，逐三角形写 SOLID 四顶点实体）。
  static void _appendSolidFill(_Ctx c, List<List<double>> ring) {
    for (final t in _triangulate(ring)) {
      if (t.length < 3) continue;
      _appendSolidTri(c, 'JianZhuFill', t[0], t[1], t[2]);
    }
  }

  /// 单个三角形 → SOLID（10/11/12 为三顶点，13 取第 3 点成退化四边形）。
  static void _appendSolidTri(_Ctx c, String layer,
      List<double> a, List<double> b, List<double> d) {
    c.ent('SOLID', layer, 'AcDbTrace');
    c.sb.write('10\n${_fmt(a[0])}\n20\n${_fmt(a[1])}\n30\n0\n'
        '11\n${_fmt(b[0])}\n21\n${_fmt(b[1])}\n31\n0\n'
        '12\n${_fmt(d[0])}\n22\n${_fmt(d[1])}\n32\n0\n'
        '13\n${_fmt(d[0])}\n23\n${_fmt(d[1])}\n33\n0\n');
  }

  /// 多边形耳切三角化（自研纯 Dart）：先归一到逆时针，再逐耳裁出三角形。
  static List<List<List<double>>> _triangulate(List<List<double>> poly) {
    final pts = <List<double>>[];
    for (final p in poly) {
      if (pts.isEmpty || _dist2(pts.last, p) > 1e-12) pts.add(p);
    }
    if (pts.length >= 2 && _dist2(pts.first, pts.last) < 1e-12) {
      pts.removeLast();
    }
    final n = pts.length;
    if (n < 3) return const [];
    // 有向面积 → 统一为逆时针（凸顶点 cross > 0）
    var area2 = 0.0;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      area2 += pts[i][0] * pts[j][1] - pts[j][0] * pts[i][1];
    }
    final p2 = area2 < 0 ? pts.reversed.toList() : pts;
    final idx = List<int>.generate(n, (i) => i);
    final out = <List<List<double>>>[];
    var guard = 0;
    while (idx.length > 3 && guard < n * n) {
      guard++;
      var earFound = false;
      for (var i = 0; i < idx.length; i++) {
        final im = idx[(i - 1 + idx.length) % idx.length];
        final ic = idx[i];
        final ip = idx[(i + 1) % idx.length];
        final a = p2[im], b = p2[ic], cb = p2[ip];
        if (_cross(a, b, cb) <= 0) continue; // 凹顶点，跳过
        var contains = false;
        for (final k in idx) {
          if (k == im || k == ic || k == ip) continue;
          if (_inTri(p2[k], a, b, cb)) {
            contains = true;
            break;
          }
        }
        if (contains) continue;
        out.add([a, b, cb]);
        idx.removeAt(i);
        earFound = true;
        break;
      }
      if (!earFound) break; // 病态多边形：终止，保留已裁结果
    }
    if (idx.length == 3) {
      out.add([p2[idx[0]], p2[idx[1]], p2[idx[2]]]);
    }
    return out;
  }

  static double _cross(List<double> a, List<double> b, List<double> c) =>
      (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);

  static bool _inTri(List<double> p, List<double> a, List<double> b,
      List<double> c) {
    final d1 = _cross(a, b, p);
    final d2 = _cross(b, c, p);
    final d3 = _cross(c, a, p);
    final hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
    final hasPos = d1 > 0 || d2 > 0 || d3 > 0;
    return !(hasNeg && hasPos);
  }

  static double _dist2(List<double> a, List<double> b) {
    final dx = a[0] - b[0], dy = a[1] - b[1];
    return dx * dx + dy * dy;
  }

  // ---- 纸面毫米 → 图纸米（唯一换算入口）----

  static double _mmOf(double mm, int scale) => mm / 1000.0 * scale;

  static double _roadHalfWidthM(RoadGrade g, int scale) =>
      _mmOf(_roadHalfWidthMm(g), scale);
  static double _roadLabelM(RoadGrade g, int scale) =>
      _mmOf(_roadLabelMm(g), scale);

  /// 等级 → 半宽（纸面毫米）。
  /// 路宽（纸面毫米，v3.9.5 起整体**放大一倍**——用户反馈"路有点窄"）。
  static double _roadHalfWidthMm(RoadGrade g) => switch (g) {
        RoadGrade.trunk => 0.90,
        RoadGrade.primary => 0.76,
        RoadGrade.secondary => 0.60,
        RoadGrade.tertiary => 0.50,
        RoadGrade.residential => 0.36,
        RoadGrade.service => 0.24,
        RoadGrade.other => 0.20,
      };

  /// 等级 → 路名字号（纸面毫米）。
  static double _roadLabelMm(RoadGrade g) => switch (g) {
        RoadGrade.trunk => 2.0,
        RoadGrade.primary => 1.9,
        RoadGrade.secondary => 1.7,
        RoadGrade.tertiary => 1.5,
        RoadGrade.residential => 1.3,
        RoadGrade.service => 1.0,
        RoadGrade.other => 1.0,
      };

  /// 等级 → 简化容差（米，N4：主干细、小路粗）。
  static double _roadTolM(RoadGrade g) => switch (g) {
        RoadGrade.trunk => 0.5,
        RoadGrade.primary => 0.6,
        RoadGrade.secondary => 0.8,
        RoadGrade.tertiary => 1.0,
        RoadGrade.residential => 1.5,
        RoadGrade.service => 2.0,
        RoadGrade.other => 2.0,
      };

  /// 地名级别 → 字号（纸面毫米）。
  static double _placeFontMm(PlaceLevel l) => switch (l) {
        PlaceLevel.city => 2.8,
        PlaceLevel.suburb => 2.5,
        PlaceLevel.neighbourhood => 2.2,
        PlaceLevel.residential => 2.2,
        PlaceLevel.town => 2.2,
        PlaceLevel.village => 2.2,
        PlaceLevel.hamlet => 1.8,
      };
}
