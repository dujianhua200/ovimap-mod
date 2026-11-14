import 'dart:io';
import 'dart:math' as math;

import 'package:gbk_codec/gbk_codec.dart';

import '../geo/geo_util.dart';
import '../models/label_type.dart';
import '../models/map_label.dart';
import '../services/store.dart';
import '../symbols/dxf_block_parser.dart';
import 'basemap.dart';
import 'dxf_layers.dart';
import 'dxf_validate.dart';
import 'dxf_version.dart';
import 'frame_template.dart';
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
    // —— 出图口径（用户指定）——
    /// 固定出图比例（1:3000 即传 3000）；null = 按范围自动估算（旧行为）。
    ///
    /// 现场口径：勘察图统一 1:3000，所有字高/符号/线宽都按这个比例换算成
    /// 图纸米数。自动估算会随线路长度变化（同一段路画两次比例不同），
    /// 交付时对不上，所以默认改为**固定**。
    int? fixedScale,
    /// 杆路多段线的全局宽度（纸面毫米）。用户指定 0.5mm。
    double rodLineWidthMm = 0.5,
    /// 是否在符号上方写「名称」。
    ///
    /// 关掉后只留图块本体（图例块内已含代号字，如 gl004 里的「木」），
    /// 不再额外压一行名称 —— 用户口径："块中间没有连线，没有原字"。
    bool showLabelNames = true,

    /// 图框模板（用户 DXF）。为 null 时用旧的矩形框。
    ///
    /// 由调用方通过 `FrameLibrary.load()` 取到并传入；单元测试可直接构造。
    FrameTemplate? frame,

    /// 图层颜色覆盖：key = 图层名，value = 0xRRGGBB（0 或缺省 = 用默认色）。
    ///
    /// 用户口径："标签的颜色实现可选，现在只有黑色，我希望有好几种颜色可选"。
    /// 常用键：`BiaoQian`（符号）、`JuLi`（距离数字）、`GanLu`（杆路线）、
    /// `ZhuangHao`（桩号）、`DiMing`（地名）等，与 `DxfLayers.all` 的图层名一致。
    Map<String, int> colorOverrides = const {},

    /// 距离标注字高（纸面毫米）。默认 2.5 —— 用户可自行修改。
    double distFontMm = 2.5,

    /// 符号（图块）缩放倍率。默认 1.0 —— 用户可放大缩小符号。
    ///
    /// **只影响图块本身**；杆路断开的间隙会跟着符号尺寸自动调整，
    /// 所以无论缩放到多少，线与符号始终相接（不脱开、不留大缝）。
    double symbolScale = 1.0,

    /// 是否画**指北针**（圆 + 正三角形）。默认 true。
    ///
    /// 用户口径："导出的时候方框和中间是正三角形的符号不要" ——
    /// 那个"方框套三角"就是旧的指北针符号，属于装饰件，不需要时可关。
    bool showNorthArrow = true,

    /// 是否画**图签栏**（左下那个 5 行统计框）。默认 true。
    bool showTitleBlock = true,

    /// 对**注入的底图**（[basemap] 参数）是否也按沿线路缓冲裁剪。
    ///
    /// 默认 false：注入即代表调用方已决定范围（测试、预览都靠这个语义）。
    /// 从 UI 导出时传 true，让"底图范围"档位真实生效。
    /// 本地底图（[localBasemap]）与联网抓取始终按范围裁剪，不受此开关影响。
    bool clipInjectedBasemap = false,
  }) async {
    final warnings = <String>[];
    final dir = await LabelStore.instance.exportDir();
    final f = File('${dir.path}/${sanitizeName(name)}.dxf');

    if (labels.isEmpty) throw Exception('杆路为空');

    final sb = StringBuffer();
    final h = _H();
    final c = _Ctx(sb, version, h);

    // 本次导出要用到的图例库块。
    //
    // ⚠️ 必须在写 BLOCKS 段**之前**算好：DXF 的段序是
    // HEADER→TABLES→BLOCKS→ENTITIES，而块定义只能写在 BLOCKS 里，
    // 所以不能"边写 INSERT 边登记"。这里从 labels 的类型直接推
    // （符号循环与图例栏都只由 labels 决定，口径一致）。
    final usedCatalogBlocks = <String>{
      for (final l in labels)
        if (l.type.isBlock &&
            l.typeId != 'track' &&
            l.typeId != 'none' &&
            l.typeId != 'text')
          l.typeId,
    };

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
    _appendTables(c, version, completionRed,
        colorOverrides: colorOverrides);

    // 符号块定义：INSERT 引用，CAD 中可整体移动/复制/编辑（对齐图例）。
    _appendBlocksSection(c, version, usedCatalogBlocks);

    // 实体段
    sb.write('0\nSECTION\n2\nENTITIES\n');

    // 本地投影基准点（第一个点）
    final baseLon = labels.first.lon;
    final baseLat = labels.first.lat;
    // 经纬度 → **真实米** 的投影系数。
    final metersPerDegX = 111320.0 * math.cos(baseLat * math.pi / 180);
    const metersPerDegY = 110540.0;

    // 实体包围盒（**真实米**，本地坐标）：先算出范围，再据此定比例。
    var rawMinX = 0.0, rawMinY = 0.0, rawMaxX = 0.0, rawMaxY = 0.0;
    for (final l in labels) {
      final x = (l.lon - baseLon) * metersPerDegX;
      final y = (l.lat - baseLat) * metersPerDegY;
      if (x < rawMinX) rawMinX = x;
      if (x > rawMaxX) rawMaxX = x;
      if (y < rawMinY) rawMinY = y;
      if (y > rawMaxY) rawMaxY = y;
    }

    // 出图比例：用户可固定（现场统一 1:3000），否则按线路范围自动估算。
    final routeScale = fixedScale != null && fixedScale > 0
        ? fixedScale
        : _pickScale(rawMinX, rawMinY, rawMaxX, rawMaxY);

    // ---------------------------------------------------------------
    // **图纸单位换算（v3.13 关键修正）**
    //
    // 用户插件在 1:3000 下，图面 1 单位 = 实地 3 米
    // （3000 毫米 = 3 米），即 `1 单位 = 比例/1000 米`。
    //
    // 实测依据（66.dxf 里插件画的杆路）：
    //   · 中位档距 15.7 图面单位 → 实地约 47 米（15.7 × 3）
    //   · 我们原按 1 单位 = 1 米 → 同一段画成 47 单位，图面大 3 倍
    //
    // 所以：所有几何坐标都要 **除以 (比例/1000)**。
    // 注意：**距离数值（段距文字）不受影响** —— 那是真实米数，
    // 由 haversine 单独算，与图面单位无关。
    // ---------------------------------------------------------------
    final unitsPerMeter = routeScale / 1000.0; // 1:3000 → 3.0
    final scaleX = metersPerDegX / unitsPerMeter;
    final scaleY = metersPerDegY / unitsPerMeter;

    // 实体包围盒（图纸单位）
    var extMinX = 0.0, extMinY = 0.0, extMaxX = 0.0, extMaxY = 0.0;
    for (final l in labels) {
      final x = (l.lon - baseLon) * scaleX;
      final y = (l.lat - baseLat) * scaleY;
      if (x < extMinX) extMinX = x;
      if (x > extMaxX) extMaxX = x;
      if (y < extMinY) extMinY = y;
      if (y > extMaxY) extMaxY = y;
    }

    // **线路自身的范围**（图纸单位）：分幅只按它算，不含底图。
    // extMinX 等后续会被底图扩展，所以必须在这里另存一份。
    final routeMinX = extMinX, routeMinY = extMinY;
    final routeMaxX = extMaxX, routeMaxY = extMaxY;

    // 沿线总长度（图签用）
    var routeTotalLen = 0.0;
    // 桩号跨线组连续累计：续画链/分支链不再从 K0+000 重新归零，
    // 全线桩号沿链输出顺序一杆接一杆递增（与竣工里程口径一致）。
    var globalCum = 0.0;

    // 图幅比例已在上面（坐标换算前）算好：routeScale。
    // 字高按**纸面毫米**（v3.13 口径：1 纸面毫米 = 1 图纸单位）。
    // 用户插件实测：字高 2.5、线宽 0.5、块按 1:1 插入。
    final segFontM = _mmOf(distFontMm, routeScale);
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
      var bm = const BasemapData(
        roads: [], buildings: [], places: [],
        report: BasemapFetchReport(
          roads: DatasetReport(FetchState.ok, source: ''),
          buildings: DatasetReport(FetchState.ok, source: ''),
          places: DatasetReport(FetchState.ok, source: ''),
          extras: DatasetReport(FetchState.ok, source: ''),
        ),
      );
      if (localBasemap != null) {
        // 本地底图也尊重「范围档位」：裁到线路外扩 bbox，做到「只导出范围内」。
        // **裁剪结果为空时必须就用空底图**（`bm = cropped`）——**绝不回退全量**。
        // 旧实现「裁剪为空则回退全量」是用户每次导出 ≈50MB 的根因：线路一旦落在
        // 底图数据空白处（如罗山/光山/新县农村），裁剪为空 → 回退 → 整个信阳
        // 4.4 万要素全写进 DXF。此处改为「空就是空 + 明确中文提示」，绝不兜底全量。
        final bbox = BasemapFetcher.boundsOf(labels, rangeM);
        // **严格按范围裁剪**（v3.20 修：用户设 50m 却导出 ~105m 宽）。
        //
        // 原 `toleranceM: rangeM * 0.1` 是"向外放 10%"的容差，本意是避免
        // 路口被切碎。但它叠加在两处放大上：
        //   ① 建筑"任一点在框内即保留整栋" —— 大建筑可多探出几十米；
        //   ② 道路裁剪也用同一个容差外扩。
        // 结果 50m 的设置实际画出 ~105m，用户感觉"设置没什么用"。
        //
        // 改为 toleranceM: 0（严格按框）。路口被切的碎一点可以接受，
        // 但**范围必须说了算** —— 用户调档位要能看见效果。
        var cropped = GeoJsonImporter.cropTo(
          localBasemap,
          bbox,
          toleranceM: 0,
        );
        // **再按"沿线路缓冲"裁一次**（v3.20，用户："设 50 米但导出的太广"）。
        //
        // 第一刀是按**外包矩形**裁的。线路是折线、横跨几百米时，
        // 外包矩形会把两个远端之间的整片空地也框进来 —— 50 米的设置
        // 在矩形内处处成立，但图面上看就是"范围大得多"。
        //
        // 这里改成逐要素判定"到线路的最近距离 ≤ rangeM"：
        // 只有贴着杆路两侧 50m 内才保留，远端连线之间的空白不再进图。
        cropped = _cropByRouteBuffer(cropped, labels, rangeM);
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
        // 注入的底图（测试 / 预览 / 调用方自备数据）**默认原样使用**。
        //
        // 语义上"注入"就代表调用方已经决定好要什么范围了，我们不该再裁。
        // 需要按范围收紧时，调用方显式传 `clipInjectedBasemap: true`，
        // 或自己先裁好再传进来。
        bm = clipInjectedBasemap
            ? _cropByRouteBuffer(basemap, labels, rangeM)
            : basemap;
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
        // 网络抓取走的是外包矩形；再按沿线路缓冲收一次，
        // 保证"范围档位"在三条数据来源上口径一致。
        bm = _cropByRouteBuffer(bm, labels, rangeM);
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

      // 杆路 = **多段线**（不是逐段 LINE），且**在每个符号处断开**。
      //
      // 用户口径："线是多段线，宽度 0.5 毫米；块中间没有连线"。
      // 断开的必要性：符号（图块）本身有尺寸（杆 3.1mm、井 4.1mm、拉线 10mm），
      // 若整条线从符号中心穿过，在 CAD 里放大看就是"一根棍子捅穿符号" ——
      // 现场叫"块中间有连线"。所以按符号**实际半宽**把该段两端各缩进，
      // 线只画到符号边缘为止。
      final lineWidthM = _mmOf(rodLineWidthMm, routeScale);
      // 断开半径 = 符号真实半宽 × 用户缩放倍率 × **0.88 收缩系数**。
      //
      // 用户反馈："线与图块的间隙也大"。原实现用符号包络的半宽（外接圆），
      // 而实际符号多为矩形，对角线方向留出太多空白。
      // 取 0.88 让线稍微**探进**符号边缘一点，视觉上"线与符号相接"，
      // 不再是一大截空白。倍率变化时间隙同步缩放 —— 无论标签放大到几倍，
      // 线始终贴着符号（用户的明确要求）。
      _appendRodPolyline(c, chain, cart, routeScale, lineWidthM, version,
          symbolScale: symbolScale);

      var chainCum = globalCum;
      for (var i = 1; i < chain.length; i++) {
        final a = chain[i - 1];
        final b = chain[i];

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
        // 水平居中在线段中点，**垂直方向浮在线条上方**：
        // 汉字压在线上会和杆路线叠在一起，看着"怪"（用户原话）。
        _text(c, 'JuLi', mx, my, segFontM, segText,
            angle: angle, style: true, centered: true, liftAboveLine: true);
        // 盘留标注（段下方第一行）
        var extraY = my - 3.4;
        if (b.slackM > 0) {
          _text(c, 'JuLi', mx, extraY, subFontM, '盘留${_formatSlack(b.slackM)}m',
              angle: angle, style: true, centered: true);
          extraY -= 2.6;
        }
        // 本段光缆型号（再下一行）
        if (b.segCable.trim().isNotEmpty) {
          _text(c, 'JuLi', mx, extraY, subFontM, b.segCable.trim(),
              angle: angle, style: true, centered: true);
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
      // **每个点处的线路方向角（度）**：符号与标注随线路方向旋转。
      //
      // 现场图纸惯例：井/箱盖是矩形，顺着杆路摆放才看得顺。
      // 原来 INSERT 的 50 组码固定 0，所有井朝向一致（用户反馈：
      // "井为什么方向一直是一个，可不可以随线的方向"）。
      //
      // 算法：取该点相邻两杆的方向均值（转角处自然过渡）；
      // 只有一条链时用链内相邻点；孤立点则 0°。
      final dirAt = _directionDegAt(labels, baseLon, baseLat, scaleX, scaleY);

      // 符号插入缩放：**1.0**（图块按原尺寸插入）。
      //
      // 依据用户插件实测：`gl003` 块定义 3.0 单位、插入 xscale=1.0，
      // 与"字高 2.5 / 线宽 0.5"同一坐标体系。旧代码用 routeScale/1000
      // （1:3000 → 3.0），符号被放大 3 倍，与插件画的差整整 3 倍。
      //
      // 图例库图块本身就是"纸面毫米"单位，1:1 插入即所见即所得的图例尺寸。
      final symScale = symbolScale; // 用户可调倍率（默认 1.0）
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
        // 图例库符号（lispblock.dxf 里的真图块）：直接 INSERT 同名块，
        // 几何与用户 CAD 图例一致，不再用"椭圆/矩形/三角"近似。
        // 块定义在 _appendBlocksSection 里按需写出（只写用到的，不塞整份图例）。
        if (lt.isBlock) {
          final b = lt.block!;
          usedCatalogBlocks.add(lt.id);
          // **符号随线路方向旋转**（用户口径："井的方向能不能随线的方向"）。
          //
          // 但**不是所有符号都该转**：杆、拉线、警示牌这类正立画更好认；
          // 井、箱盖、人手孔这类矩形/椭圆符号顺着杆路摆放才符合现场习惯。
          // 判据用图例分组（`LabelType.group`）：
          //   井 / 箱体 / 人手孔 / 管道  → 随线旋转
          //   杆 / 拉线 / 其它设施      → 保持正立（0°）
          final rot = _shouldFollowRoute(lt) ? (dirAt[l.id] ?? 0.0) : 0.0;
          _appendInsert(c, 'BiaoQian', lt.id, x, y,
              sx: symScale, sy: symScale, rotDeg: rot,
              // 每个图标的独立颜色（用户口径：可以一个点一个色）
              colorRgb: l.iconColor);
          // 名称（可关）：图块本体只含图例里那一个代号字（如 gl004 里的「木」）。
          // 用户口径「块中间没有连线，没有原字」→ showLabelNames=false 时
          // 不再额外压一行名称，只留图块本身。
          if (showLabelNames && disp.isNotEmpty) {
            final top = (b.maxY - _blockBaseY(b)) * symScale;
            _text(c, 'BiaoQian', x, y + top + _mmOf(1.2, routeScale),
                labelFontM, disp, style: true);
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
          continue;
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

    // 图框：优先用**用户提供的图框**（assets/frames/frame_a3.dxf，尺寸不变）；
    // 装不下就分多张（每张一套完整图框）。没有图框资源时退回旧的矩形框。
    //
    // 传两套范围：
    //   · ext* = 含底图的总包围盒（决定图框最终摆哪、要不要居中）
    //   · route* = 只有杆路的范围（决定**分几幅**）
    //
    // 先把图框里写死的示例工程名换成用户的工程名（v3.20）。
    final frame2 = frame?.replaceProjectName(name);
    // 图框绘制偏移（用于把图签文字画到正确位置）
    final frameOrigin = <double>[0, 0];
    final frameUsed = _appendUserFrameOrFallback(c, frame2,
        extMinX, extMinY, extMaxX, extMaxY, routeMinX, routeMinY,
        routeMaxX, routeMaxY,
        originOut: frameOrigin);
    if (!frameUsed) {
      _appendFrame(c, extMinX, extMinY, extMaxX, extMaxY);
    }
    if (showLegend) {
      _appendLegend(c, labels, extMinX, extMinY);
    }
    if (showNorthArrow) _appendNorthArrow(c, extMaxX, extMaxY);
    if (showTitleBlock) {
      if (frameUsed) {
        // **有用户图框时，往图框自带的图签格子里填字**，不再另画一个（v3.20）。
        //
        // 用户图框（新块.dxf）自带完整图签：5 行格线 y=0.70~30.18、
        // 且"中国通信建设第一工程局有限公司""图号 01"等已经排好版。
        // 我们再画一个 120×30 的图签，就会两个框叠加、文字互相错位 ——
        // 这就是用户反复说"下方的字还是错行"的真正原因。
        _fillFrameTitleCells(c, frame2!, name: name,
            totalPoints: labels.length,
            totalLength: routeTotalLen,
            scale: routeScale,
            // 图框实际绘制偏移：文字必须跟着平移，否则画到框外
            originDx: frameOrigin[0],
            originDy: frameOrigin[1]);
      } else {
        _appendTitleBlock(c, extMinX, extMinY, extMaxX, extMaxY,
            name: name,
            totalPoints: labels.length,
            totalLength: routeTotalLen,
            scale: routeScale);
      }
    }

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
      String text,
      {double? angle,
      bool style = true,
      String? styleName,
      bool centered = false,
      bool liftAboveLine = false,
      bool vCenterExact = false}) {
    // **DXF 文字净化（关键防线）**
    //
    // 组码 1 是单行文本值：里面出现裸的 `\`、`{`、`}` 会让 CAD 解析失败，
    // 打开时报「无效或不完整的 DXF 输入，图形被放弃」。
    // 图框里的 MTEXT 富文本码正是这么带进来的 —— 在 frame_template 已清理，
    // 这里再加一道：任何来源的文字都保证只含安全字符。
    final t = _sanitizeDxfText(text);
    // **默认就写中文样式**（v3.18）。
    //
    // 用户反馈"里面的字体都是乱码"，根因是大量 TEXT 没写组码 7（样式），
    // 于是落回默认 `Standard` —— 而 Standard 是 `txt.shx`，
    // 纯西文 SHX 字体，中文一律显示成 ??? 或方块。
    //
    // 逐个调用点补 `style: true` 太容易漏（图例、桩号、图签、地名…
    // 十几处，且有的在换行后才写参数）。所以把默认值直接改成 true：
    // 想用西文样式的调用方显式传 `style: false` 即可。
    final sn = styleName ?? (style ? 'SimSun' : null);

    // **文字居中：基线原点 + 手工位移**（v3.17）
    //
    // ## 为什么不再用 72/73 对齐码
    // 用户实测："距离不是在线的中间，是在线的上方"。
    // 我们确实写了 `72=1`（水平居中）、`73=2`（垂直居中）+ 对齐点 11/21，
    // 数据完全合规。但 `73=2` 依赖 CAD **自己去量字形包围盒**：
    //   · 中文字形的上下留白不对称，按包围盒居中必然偏上；
    //   · 不少国产 CAD / 看图软件对 R12 的 73 支持不完整，直接忽略，
    //     于是退回"基线在给定点" —— 文字整体抬到线上方。
    //
    // ## 现在的做法（v3.17 第二次修正）
    // 用户反馈"距离数字在线条上方，不在中间" —— 排查发现坐标本身就在线段
    // 中点（偏差 0.00），真正的问题是 **`73=2` 垂直居中被忽略**，
    // 导致文字退回"基线在给定点"，字身整体抬到线以上。
    //
    // 改为：**不写 73**，垂直位置由我们自己按字高算死。
    //   · 水平：72=1（水平居中，所有 CAD 都支持）；
    //   · 垂直：把插入点下移 0.35×字高，让字身**压在线上**（视觉居中）；
    //   · 另给 0.55×字高 的上移量选项（`liftAboveLine`），
    //     让标注**明显浮在线条上方**，避免与线重叠、看着乱。
    //
    // 0.35 的来历：宋体汉字字身约占 em 的 0.86，基线到字身中心 ≈0.35em。
    //
    // [vCenterExact]：**表格式精确居中**（v3.21）。
    // 图签要落在格子的几何正中，不能再叠 0.35h 的基线补偿 ——
    // 那个补偿是给"压在线条上"的标注用的。图签用它会整体下沉
    // 1.0~1.6 个单位，正是用户说的"字老错行，没在表格内"。
    final yAdj = (centered && !vCenterExact)
        ? y - h * 0.35 + h * (liftAboveLine ? 0.95 : 0)
        : y;

    c.ent('TEXT', layer, 'AcDbText');
    if (sn != null) c.sb.write('7\n$sn\n');
    c.sb.write(
        '10\n${_fmt(x)}\n20\n${_fmt(yAdj)}\n30\n0\n40\n${_fmt(h)}\n');
    if (angle != null) c.sb.write('50\n${angle.toStringAsFixed(1)}\n');

    // **文本值必须先写**（v3.21 修）。
    //
    // 原来顺序是 `72\n1\n` → `11\n<对齐点x>` → `1\n<文本>`。
    // 这样组码 `72` 的值 `1` 与下一个组码 `11` 紧邻，实际字节是：
    //     72\n1\n11\n28.963\n...
    // 部分解析器（含我们自己的测试正则）会把 `1\n1` 连读成组码 `11`，
    // 于是文本被解析成 "11" —— 用户看到的就是图签里全是 `11`。
    //
    // DXF 组码本来就无序要求，把 `1\n<文本>` 提到前面即可消除歧义。
    c.sb.write('1\n$t\n');
    if (centered) {
      // 只给水平居中（72=1），对齐点与插入点一致。
      // 不写 73：避免各 CAD 对"垂直居中"理解不一致导致偏移。
      c.sb.write('72\n1\n');
      c.sb.write('11\n${_fmt(x)}\n21\n${_fmt(yAdj)}\n31\n0\n');
    }
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

  /// 杆路多段线：按符号实际尺寸**在符号处断开**。
  ///
  /// ## 为什么要断开
  /// 用户口径："块中间没有连线"。图块是有尺寸的（杆 3.1mm、井 4.1mm、
  /// 拉线 10mm、警示牌 15mm），整条线从符号中心穿过去，在 CAD 里就是
  /// "一根棍子捅穿符号"。所以每段线两端各缩进一个**符号半宽**，
  /// 线只画到符号边缘。
  ///
  /// ## 为什么仍是一条多段线
  /// 断开后如果逐段写 LINE，CAD 里选中就是一堆碎线（用户明确要"多段线"）。
  /// 这里把断开后的若干**子折线**各自写成一条 POLYLINE —— 每条都是真多段线，
  /// 且都带全局线宽。
  ///
  /// ## 尺寸口径
  /// 符号是"纸面毫米"，地面米数 = mm / 1000 × 出图比例，
  /// 与 `simScale`/字高完全同口径，保证任何比例下断开量与符号一致。
  static void _appendRodPolyline(
    _Ctx c,
    List<MapLabel> chain,
    List<List<double>> cart,
    int routeScale,
    double widthM,
    DxfVersion version, {
    double symbolScale = 1.0,
  }) {
    // 每个点的"断开半径"（图纸单位）：符号半宽 × 用户缩放 × 收缩系数。
    //
    // 0.88 的收缩：符号包络是外接尺寸（矩形取 maxSide/2），
    // 线走到包络边会留一大截空白。略微探进去，视觉上才"相接"。
    const shrink = 0.88;
    final radius = <double>[];
    for (final l in chain) {
      final halfMm = _symbolHalfSpanMm(l);
      final eff = (halfMm <= 0 ? 0.4 : halfMm) * symbolScale * shrink;
      radius.add(_mmOf(eff, routeScale));
    }

    // 逐段生成"可见子段"（两端各缩进），再把首尾相接的子段合并成折线。
    final runs = <List<List<double>>>[];
    List<List<double>>? cur;
    var swallowed = 0; // 被符号完全覆盖（不画线）的段数
    for (var i = 0; i < cart.length - 1; i++) {
      final p0 = cart[i], p1 = cart[i + 1];
      final dx = p1[0] - p0[0], dy = p1[1] - p0[1];
      final len = math.sqrt(dx * dx + dy * dy);
      if (len <= 1e-9) continue;
      final ux = dx / len, uy = dy / len;
      var t0 = radius[i]; // 起点缩进
      var t1 = len - radius[i + 1]; // 终点缩进
      if (t1 <= t0) {
        // 两符号几乎重合：这一段完全被符号盖住 → 不画。
        // 仍要收尾当前 run，避免把不相邻的段连成一条。
        swallowed++;
        if (cur != null && cur.length >= 2) runs.add(cur);
        cur = null;
        continue;
      }
      final a = [p0[0] + ux * t0, p0[1] + uy * t0];
      final b = [p0[0] + ux * t1, p0[1] + uy * t1];
      if (cur == null) {
        cur = [a, b];
      } else {
        // 与上一子段首尾相接（中间只隔着一个符号）→ 继续同一条折线。
        final last = cur.last;
        if ((last[0] - a[0]).abs() < 1e-6 && (last[1] - a[1]).abs() < 1e-6) {
          cur.add(b);
        } else {
          if (cur.length >= 2) runs.add(cur);
          cur = [a, b];
        }
      }
    }
    if (cur != null && cur.length >= 2) runs.add(cur);

    // 兜底：整条链全被符号覆盖，但**各点确实分开**（不是重合）时才补一条
    // 符号中心之间的连线。
    //
    // 为什么要区分"重合"与"符号覆盖"：
    // · 多点重合（现场误点两次）→ 净跨度为 0，图上一根线都没有才正确，
    //   强行画一条零长线反而制造垃圾实体；
    // · 点确实分开、只是符号尺寸把它们之间的空隙吃掉了（比例小/符号大）→
    //   杆路存在这件事必须看得见，否则用户以为"点没连上"。
    if (runs.isEmpty && swallowed > 0) {
      final distinct = <List<double>>[];
      for (final p in cart) {
        final dup = distinct.any((q) =>
            (q[0] - p[0]).abs() < 1e-9 && (q[1] - p[1]).abs() < 1e-9);
        if (!dup) distinct.add(p);
      }
      if (distinct.length >= 2) {
        _appendPolyline(c, 'GanLu', distinct,
            width: widthM, version: version);
      }
    }

    for (final run in runs) {
      _appendPolyline(c, 'GanLu', run, width: widthM, version: version);
    }
  }

  /// 符号在纸面上的**半宽**（毫米）：用于杆路在符号处断开的缩进量。
  ///
  /// 取值优先用图块真实包络（`DxfBlock` 的 width/height），预置符号按
  /// 各形状的固定尺寸给（与 `_appendBlocksSection` 里定义的块尺寸一致）。
  /// 返回 0 表示"该点不画符号"（轨迹/无标签/文字），调用方退化为 0.4mm 空隙。
  static double _symbolHalfSpanMm(MapLabel l) {
    final lt = l.type;
    if (lt.id == 'track' || lt.id == 'none' || lt.id == 'text') return 0;
    final b = lt.block;
    if (b != null && !b.isEmpty) {
      // 图块单位即纸面毫米 → 半宽 = max(宽,高)/2
      return b.maxSide / 2;
    }
    // 预置符号：与块定义尺寸对齐（人孔 6×3.5 / 箱体 5×3 / 引上 3 / 杆 r=1.2）
    if (lt.isOval) return 3.0; // HZ_OVAL 半宽
    if (lt.isBox) return 2.5; // HZ_BOX 半宽
    if (lt.isTri) return 1.5; // HZ_TRI 半宽
    return 1.2; // HZ_POLE 半径
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

  /// RGB → 最接近的 AutoCAD ACI 索引色。
  ///
  /// 为什么需要：R12（AC1009）**不支持真彩色**（组码 420 是 R2000+ 才有），
  /// 只有 ACI 索引色。用户选了自定义颜色后：
  ///   · R2000 → 直接写 420 真彩色（精确）；
  ///   · R12   → 退到最接近的 ACI，保证"至少是个像样的颜色"，不是全黑。
  ///
  /// 对照表取 AutoCAD 标准 1~9 与常用 2xx 灰阶，覆盖现场用得到的色域。
  static int _aciForRgb(int rgb) {
    final r = (rgb >> 16) & 0xFF;
    final g = (rgb >> 8) & 0xFF;
    final b = rgb & 0xFF;
    // 纯黑 / 纯白直接命中
    if (r < 30 && g < 30 && b < 30) return 7; // 白（CAD 黑底上显示为白）
    if (r > 230 && g > 230 && b > 230) return 7;

    const table = <int, (int, int, int)>{
      1: (255, 0, 0), // 红
      2: (255, 255, 0), // 黄
      3: (0, 255, 0), // 绿
      4: (0, 255, 255), // 青
      5: (0, 0, 255), // 蓝
      6: (255, 0, 255), // 品红
      8: (128, 128, 128), // 灰
      9: (192, 192, 192), // 浅灰
      30: (255, 127, 0), // 橙
      140: (0, 63, 255), // 深蓝
      170: (63, 0, 255), // 紫
      250: (51, 51, 51), // 近黑
      252: (153, 153, 153), // 中灰
    };

    var best = 7;
    var bestD = 1 << 30;
    for (final e in table.entries) {
      final (tr, tg, tb) = e.value;
      final d = (r - tr) * (r - tr) + (g - tg) * (g - tg) + (b - tb) * (b - tb);
      if (d < bestD) {
        bestD = d;
        best = e.key;
      }
    }
    return best;
  }


  static void _appendFrame(_Ctx c, double minX,
      double minY, double maxX, double maxY) {
    const m = 10.0;
    final x0 = minX - m, y0 = minY - m;
    final x1 = maxX + m, y1 = maxY + m;
    _appendRect(c, 'TuQian', x0, y0, x1, y1);
  }

  /// 用**用户图框**包住内容：尺寸不变，装不下就分多张。
  ///
  /// 返回 true 表示已用用户图框（调用方不再画旧矩形框）。
  ///
  /// ## 布局口径
  /// · 内容原样保留在现有坐标里（不改动业务实体）；
  /// · 图框按"每张容纳 contentWidth × contentHeight"平铺，
  ///   第一张的左下角与内容包围盒对齐，之后向右/向下排；
  /// · **每张图框都是完整的**（含图签/图例位置的留白），
  ///   施工现场按张打印、按张装订。
  ///
  /// ## 为什么不做整体缩放
  /// 用户明确"大小不要变"。缩放会让图框的线宽、字号、图签比例全部失真，
  /// 打印出来就不合规了。宁可多出几张。
  static bool _appendUserFrameOrFallback(_Ctx c, FrameTemplate? frame,
      double minX, double minY, double maxX, double maxY,
      double routeMinX, double routeMinY, double routeMaxX, double routeMaxY,
      {List<double>? originOut}) {
    if (frame == null || frame.shapes.isEmpty) return false;

    final cw = frame.contentWidth;
    final ch = frame.contentHeight;
    if (cw <= 1e-6 || ch <= 1e-6) return false;

    // 注：不再计算 spanX/spanY（含底图的包围盒跨度）。
    // v3.16 起分幅**只看线路范围**，见下方 routeSpanX/Y。

    // ----------------------------------------------------------------
    // **分幅按"线路范围"算，不按"包围盒"算**
    //
    // 用户反馈："本来给图框能解决的，弄了十几个"。
    // 根因：传入的 minX..maxY 是**含底图**的总包围盒 —— 兜底底图那 394 栋
    // 建筑铺开几百米，导致 spanX/spanY 比线路大得多，于是算出一堆图框。
    //
    // 正确口径：图框该随**杆路线路**走。线路放得下就一张（用户预期），
    // 放不下才按线路长度分幅。底图超出的部分照常画出图框外没关系 ——
    // 现场看的是杆路。
    // ----------------------------------------------------------------
    final routeSpanX = (routeMaxX - routeMinX).abs();
    final routeSpanY = (routeMaxY - routeMinY).abs();
    // **不要回退到含底图的 spanX**（v3.16 修正）。
    //
    // 原写法 `routeSpanX > 1e-6 ? routeSpanX : spanX` 有个陷阱：
    // 纯南北向的线路 X 跨度为 0，于是回退去用底图包围盒（可能上万单位）
    // → 算出几十套图框（用户："弄了十几个"）。
    //
    // 正确语义：线路在某个方向没有延伸，就是**只要 1 列/1 行**。
    final useSpanX = routeSpanX;
    final useSpanY = routeSpanY;

    // 需要几列几行（按线路范围）
    final cols = math.max(1, (useSpanX / cw).ceil());
    final rows = math.max(1, (useSpanY / ch).ceil());


    // 单张时按线路居中；多张时按线路左下角平铺（见下）。
    //
    // 记下**第一张图框的绘制偏移**：填图签文字时必须加上它，
    // 否则文字会按图框内坐标（0~30）画到图框外面去（v3.21 修）。
    double originDx = 0, originDy = 0;

    if (cols == 1 && rows == 1) {
      // 单张：图框**按杆路居中**（不是按含底图的总包围盒）。
      // 底图通常比线路大得多，按总包围盒居中会让线路偏到一边。
      final cxRoute = (routeMinX + routeMaxX) / 2;
      final cyRoute = (routeMinY + routeMaxY) / 2;
      final dx = cxRoute - frame.width / 2;
      final dy = cyRoute - frame.height / 2;
      originDx = dx;
      originDy = dy;
      _emitFrameShapes(c, frame, dx, dy);
    } else {
      // 多张：以**线路**左下角为起点按网格平铺，保证每一段杆路都落在某张图框里。
      final oX = routeMinX - frame.contentInset;
      final oY = routeMinY - frame.contentInset;
      originDx = oX;
      originDy = oY;
      for (var r = 0; r < rows; r++) {
        for (var k = 0; k < cols; k++) {
          final dx = oX + k * cw;
          final dy = oY + r * ch;
          _emitFrameShapes(c, frame, dx, dy);
        }
      }
    }
    // 回传第一张图框的绘制偏移（填图签文字用）
    if (originOut != null && originOut.length >= 2) {
      originOut[0] = originDx;
      originOut[1] = originDy;
    }
    return true;
  }

  /// 把图框图元写到 DXF（平移 dx,dy）。图层统一归到 TuQian，颜色随图框自带。
  static void _emitFrameShapes(
      _Ctx c, FrameTemplate frame, double dx, double dy) {
    for (final s in frame.shapes) {
      switch (s) {
        case FrameLine l:
          _appendLine(c, 'TuQian', l.x1 + dx, l.y1 + dy, l.x2 + dx,
              l.y2 + dy);
        case FramePoly p:
          if (p.pts.length < 2) break;
          _appendPolyline(c, 'TuQian',
              [for (final q in p.pts) [q[0] + dx, q[1] + dy]],
              closed: p.closed, version: c.v);
        case FrameCircle cc:
          _appendCircle(c, 'TuQian', cc.cx + dx, cc.cy + dy, cc.r);
        case FrameText t:
          final txt = t.text.trim();
          if (txt.isEmpty) break;
          _text(c, 'TuQian', t.x + dx, t.y + dy, t.h <= 0 ? 2.5 : t.h,
              txt, angle: t.rot, style: true);
      }
    }
  }

  /// 把任意文字净化成可安全写进 DXF `组码 1` 的形式。
  ///
  /// AutoCAD 对 TEXT 的值相当敏感：裸 `\`、不配对的 `{}`、
  /// 未定义的 `\X` 转义都会导致"无效或不完整的 DXF 输入"。
  /// 图框的 MTEXT 富文本码（`\fSimSun|b0|i0|c134|p2;`）就属于后者。
  ///
  /// 保留：普通字符、中文、AutoCAD 合法控制码 `%%d/%%c/%%p/%%%`。
  static String _sanitizeDxfText(String s) {
    var t = s.replaceAll('\r', ' ').replaceAll('\n', ' ');

    // 1) 去掉未定义的 \X 转义（保留 AutoCAD 合法的 \\ 与 \U+XXXX）
    t = t.replaceAllMapped(RegExp(r'\\([^\\U])'), (m) => '');
    // 2) 去掉花括号分组符
    t = t.replaceAll('{', '').replaceAll('}', '');
    // 3) 去掉控制字符（0x00-0x1F），换行已在上一步换成空格
    t = t.replaceAll(RegExp(r'[\x00-\x1F]'), ' ');
    // 4) 收尾空白（**不合并内部空格**：图纸里"图  例"这种排版空格有含义）
    t = t.replaceAll(RegExp(r'^\s+|\s+$'), '');
    return t;
  }

  /// 圆（图框里的圆、印章位等）。
  static void _appendCircle(
      _Ctx c, String layer, double cx, double cy, double r) {
    if (r <= 0) return;
    c.ent('CIRCLE', layer, 'AcDbCircle');
    c.sb.write('10\n${_fmt(cx)}\n20\n${_fmt(cy)}\n30\n0\n'
        '40\n${_fmt(r)}\n');
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
      // 图例库符号：直接插真图块（与图上符号同一份几何）；预置符号仍用
      // 形状近似块。图例栏是 1:1 纸面毫米，所以这里 sx=sy=1。
      final block = t.isBlock
          ? t.id
          : (t.isOval
              ? 'HZ_OVAL'
              : t.isBox
                  ? 'HZ_BOX'
                  : t.isTri
                      ? 'HZ_TRI'
                      : 'HZ_POLE');
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
  /// 按**沿线路缓冲**再裁一次底图（v3.20）。
  ///
  /// ## 为什么需要第二刀
  /// 第一刀 `GeoJsonImporter.cropTo` 是按**外包矩形**裁的。
  /// 线路是折线（用户这条横跨 688×677 米），外包矩形会把两个远端之间的
  /// 整片区域都框进来 —— 用户设"沿线 50 米"，看到的却是近 1 公里的图面。
  ///
  /// 这里逐要素判断"到线路的最近距离 ≤ [rangeM]"：
  ///  · 道路：折线任一点在缓冲内即保留**整条被裁后的段**；
  ///  · 建筑：外环任一点在缓冲内即保留整栋（封闭面不裁几何）；
  ///  · 地名：点判断。
  static BasemapData _cropByRouteBuffer(
      BasemapData bm, List<MapLabel> labels, double rangeM) {
    if (rangeM <= 0 || labels.isEmpty) return bm;

    bool near(double lat, double lon) =>
        BasemapFetcher.distToRouteM(labels, lat, lon) <= rangeM;

    final roads = <RoadPoly>[];
    for (final r in bm.roads) {
      if (r.pts.any((p) => near(p[0], p[1]))) roads.add(r);
    }
    final buildings = <BuildingPoly>[];
    for (final b in bm.buildings) {
      var hit = false;
      for (final ring in b.rings) {
        for (final p in ring) {
          if (near(p[0], p[1])) {
            hit = true;
            break;
          }
        }
        if (hit) break;
      }
      if (hit) buildings.add(b);
    }
    final places = bm.places.where((p) => near(p.lat, p.lon)).toList();

    return BasemapData(
      roads: roads,
      buildings: buildings,
      places: places,
      report: BasemapFetchReport(
        roads: DatasetReport(FetchState.ok,
            source: 'local+沿线路${rangeM.round()}m', count: roads.length),
        buildings: DatasetReport(FetchState.ok,
            source: 'local+沿线路${rangeM.round()}m', count: buildings.length),
        places: DatasetReport(FetchState.ok,
            source: 'local+沿线路${rangeM.round()}m', count: places.length),
      ),
    );
  }

  /// 往**用户图框自带的图签格子**里填统计信息。
  ///
  /// ## 为什么需要它
  /// 用户图框（`assets/frames/frame_a3.dxf`）自带完整图签：右下角 5 行格线
  /// （块内 y = 0.70 / 6.60 / 12.49 / 18.39 / 24.29 / 30.18，每格高 ≈5.9），
  /// 而且"中国通信建设第一工程局有限公司""图号 01"等文字已经排好。
  ///
  /// 我们再画一个 120×30 的图签 → **两个框叠在一起、文字互不对齐**，
  /// 就是用户反复反馈"下方的字还是错行"的根因。
  ///
  /// ## 做法
  /// 不画框，只往**最左一列的空白格**里写工程名/日期/统计。
  /// 格子的位置直接从图框图元的 bbox 推出来（图签固定贴在右下角）。
  static void _fillFrameTitleCells(_Ctx c, FrameTemplate frame,
      {required String name,
      required int totalPoints,
      required double totalLength,
      required int scale,
      double originDx = 0,
      double originDy = 0}) {
    // **优先用实测格线**（v3.21）：从图框里扫出图签那组等距横线，
    // 按它的真实格高与格中心填字。这修掉了"字掉在格子下沿"的问题 ——
    // 之前按凭空估的 30/46% 算，与真实格线差 1~1.6 个单位。
    final measured = frame.findTitleBlockRows();

    final List<double> rowYs;
    final double x0;
    if (measured != null && measured.ys.length >= 4) {
      rowYs = measured.ys; // 已按 y 降序，格数 = 线数-1
      x0 = measured.x0;
    } else {
      // 回退：按 30 单位高、46% 宽估算（旧行为）
      const tbH = 30.0;
      final tbW = frame.width * 0.46;
      x0 = frame.width - tbW;
      rowYs = [
        for (var i = 0; i <= 5; i++) tbH - tbH / 5 * i,
      ];
    }

    final cells = rowYs.length - 1; // 格数
    final date = DateTime.now();
    final vals = <String>[
      (name.isEmpty ? '未命名项目' : name),
      '滑洲云图 ${date.year}-${date.month.toString().padLeft(2, '0')}'
          '-${date.day.toString().padLeft(2, '0')}',
      '点数 $totalPoints',
      '长度 ${_formatDistNoUnit(totalLength)}m',
      '1:$scale',
    ];

    // 往最左一列的**空白格**里写字（图框右侧已有公司名/图号，不能覆盖）。
    // 从上往下填，最多填 min(格数, 5) 行。
    final n = math.min(cells, vals.length);
    for (var i = 0; i < n; i++) {
      final top = rowYs[i];
      final bot = rowYs[i + 1];
      final cy = (top + bot) / 2; // 该格**真实**垂直中心
      final rowH = top - bot;
      final fontH = math.min(2.6, rowH * 0.52);
      // **加上图框绘制偏移**：measured/cells 都是图框内坐标（0~30），
      // 图框实际画在 dx,dy 处，文字不跟着平移就会落到框外。
      _text(c, 'TuQian', originDx + x0 + 2.0, originDy + cy, fontH, vals[i],
          centered: true, vCenterExact: true);
    }
  }

  /// 图签（无用户图框时的自带版本，120×30 五行）。
  static void _appendTitleBlock(
      _Ctx c, double minX, double minY, double maxX, double maxY,
      {required String name,
      required int totalPoints,
      required double totalLength,
      required int scale}) {
    const w = 120.0, h = 30.0;
    // 图签放在**内容下方之外**（v3.18）。
    const gapBelow = 6.0;
    final x0 = maxX - w, y0 = minY - gapBelow - h;
    final x1 = maxX, y1 = minY - gapBelow;
    const rowsCount = 5;
    final rowH = h / rowsCount; // 每行高 6.0
    _appendRect(c, 'TuQian', x0, y0, x1, y1);
    for (var i = 1; i < rowsCount; i++) {
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
    // **文字必须在格子里居中**（v3.19 修："下方的方框字体老是错行"）。
    //
    // 旧公式 `y0 + rowH*(i+1) - rowH/2 - 1.2`：
    //   · 每行高 6.0，字高 3.2，视觉中心应下移 0.35×3.2≈1.12 ✓ 数值接近；
    //   · 但 `_text` 默认以**基线**为插入点，而这里没告诉它要居中，
    //     再加上 `_text` 内部 centered=false，于是文字落在基线上 ——
    //     行距 6.0、字高 3.2 时，基线位置偏差明显，看着就是"错行"。
    //
    // 改为：用 `centered: true` 让 `_text` 走统一的居中放样，
    // 插入点直接给该格的几何中心，行高与字高的关系由 `_text` 内部处理。
    final fontH = math.min(3.2, rowH * 0.62); // 字高不超格高，避免压线
    for (var i = 0; i < rows.length; i++) {
      final cy = y0 + rowH * i + rowH / 2; // 该行垂直中心
      _text(c, 'TuQian', x0 + 2, cy, fontH, rows[i],
          centered: true, vCenterExact: true);
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

  /// 符号块定义段：人孔椭圆 / 箱体 / 引上三角 / 杆路圆叉 + **图例库块**。
  ///
  /// [catalogBlocks] 是本次导出真正用到的图例块编号（`gl001` …），
  /// 只有它们会被写成 BLOCK——整份图例有 89 个块，全塞进去会让每个 DXF
  /// 平白多出近两万行无用块定义。
  static void _appendBlocksSection(
      _Ctx c, DxfVersion version, Set<String> catalogBlocks) {
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

    // ---- 图例库块（lispblock.dxf）：按需写出，几何直接用归一化结果 ----
    //
    // 块名 = 图块编号（gl001 / gx005_x…），与用户 CAD 图例里的块名一致，
    // 这样图纸拿到 CAD 里 explode / 再插块都还是原来那套符号体系。
    _appendCatalogBlocks(c, version, catalogBlocks);

    c.sb.write('0\nENDSEC\n');
  }

  /// 把用到的图例库块写成 BLOCK 定义。
  ///
  /// 关键点：
  /// 1. **基点 = 块几何中心**（组码 10/20）。图例库的块大多以 0,0 为对称中心，
  ///    但拉线（`lx001` 在 x=0..10）不是；统一按几何中心设基点，INSERT 到地图点
  ///    时符号自然居中，不需要每处再算偏移。
  /// 2. 几何先**平移到基点坐标系**再写：块定义里写 `原坐标 - 中心`。
  /// 3. 只用 R12 也认识的实体（LINE/CIRCLE/ARC/POLYLINE/TEXT）——归一化器
  ///    已经把 LWPOLYLINE/HATCH/SPLINE/ELLIPSE 降维过了。
  static void _appendCatalogBlocks(
      _Ctx c, DxfVersion version, Set<String> ids) {
    if (ids.isEmpty) return;
    final sorted = ids.toList()..sort();
    for (final id in sorted) {
      final lt = LabelType.fromId(id);
      final block = lt.block;
      if (block == null || block.isEmpty) continue;
      final bx = _blockBaseX(block);
      final by = _blockBaseY(block);
      final b = StringBuffer();
      final bc = _Ctx(b, version, c.h);
      for (final s in block.strokes) {
        _appendSymbolStroke(bc, s, bx, by);
      }
      _appendBlockAt(c, version, id, b.toString(), bx, by);
    }
  }

  /// 图例块的基点 X：几何中心。
  static double _blockBaseX(DxfBlock b) => (b.minX + b.maxX) / 2;
  static double _blockBaseY(DxfBlock b) => (b.minY + b.maxY) / 2;

  /// 把一条归一化图元写成 DXF 实体（相对 blockBase 平移）。
  static void _appendSymbolStroke(
      _Ctx c, SymbolStroke s, double bx, double by) {
    switch (s) {
      case SymbolLine():
        _appendLine(c, '0', s.x1 - bx, s.y1 - by, s.x2 - bx, s.y2 - by);
      case SymbolCircle():
        c.ent('CIRCLE', '0', 'AcDbCircle');
        c.sb.write('10\n${_fmt(s.cx - bx)}\n20\n${_fmt(s.cy - by)}\n30\n0\n'
            '40\n${_fmt(s.r)}\n');
      case SymbolArc():
        c.ent('ARC', '0', 'AcDbArc');
        c.sb.write('10\n${_fmt(s.cx - bx)}\n20\n${_fmt(s.cy - by)}\n30\n0\n'
            '40\n${_fmt(s.r)}\n'
            '50\n${s.a0.toStringAsFixed(3)}\n'
            '51\n${s.a1.toStringAsFixed(3)}\n');
      case SymbolPoly():
        if (s.pts.length < 2) return;
        final pts = [
          for (final p in s.pts) [p[0] - bx, p[1] - by]
        ];
        _appendPolyline(c, '0', pts, closed: s.closed);
      case SymbolText():
        _text(c, '0', s.x - bx, s.y - by, s.h, s.text,
            angle: s.angle == 0 ? null : s.angle, style: true);
      default:
        // 其余（含解析器内部的 _InsertRef）在归一化阶段已消费，不会到这里。
        break;
    }
  }

  static void _appendBlock(
      _Ctx c, DxfVersion version, String name, String body) {
    _appendBlockAt(c, version, name, body, 0, 0);
  }

  /// 写 BLOCK…ENDBLK，允许指定基点（图例库块按几何中心设基点）。
  static void _appendBlockAt(_Ctx c, DxfVersion version, String name,
      String body, double baseX, double baseY) {
    final bx = _fmt(baseX), by = _fmt(baseY);
    if (version == DxfVersion.r2000) {
      c.sb.write('0\nBLOCK\n5\n${c.h.next()}\n330\n0\n100\nAcDbEntity\n8\n0\n'
          '100\nAcDbBlockBegin\n2\n$name\n70\n0\n'
          '10\n$bx\n20\n$by\n30\n0.000\n3\n$name\n1\n\n');
    } else {
      c.sb.write('0\nBLOCK\n8\n0\n2\n$name\n70\n0\n'
          '10\n$bx\n20\n$by\n30\n0\n3\n$name\n');
    }
    c.sb.write(body);
    if (version == DxfVersion.r2000) {
      c.sb.write('0\nENDBLK\n5\n${c.h.next()}\n330\n0\n100\nAcDbEntity\n8\n0\n'
          '100\nAcDbBlockEnd\n');
    } else {
      c.sb.write('0\nENDBLK\n8\n0\n');
    }
  }

  /// 写一个 INSERT（预置符号块用）。
  ///
  /// 图例库块不走这里：它们的几何中心未必在 (0,0)（如拉线块整体在 x=0..10
  /// 一侧），对齐靠 **BLOCK 定义里的基点**（组码 10/20），不是靠 INSERT 偏移
  /// ——INSERT 的 11/21 是"属性对齐点"，不是几何平移，用了只会让块跑位。
  /// 该符号是否应**随线路方向旋转**。
  ///
  /// 现场习惯：井盖、人手孔、箱体这类矩形符号顺着杆路摆；
  /// 杆、拉线、警示牌等正立符号转了反而更难认。
  ///
  /// 判据优先用**图例分组**（`LabelType.group`，来自 lispblock.dxf 的图例栏）：
  ///   杆   → 不转（原有水泥杆、新建木杆…）
  ///   井   → 转  （人井、手孔、单/双/三页井…）
  ///   拉线 → 不转
  ///   设施 → 按名称关键词判断（箱/管/盖 转，牌/标 不转）
  static bool _shouldFollowRoute(LabelType lt) {
    // ① 分组说得很清楚的，直接定
    if (lt.group == '杆' || lt.group == '拉线') return false;
    if (lt.group == '井') return true;

    // ② 其余按名称关键词
    final name = lt.name;
    for (final k in const ['杆', '拉线', '拉', '警示', '牌', '标', '砖', '墩']) {
      if (name.contains(k)) return false;
    }
    for (final k in const ['井', '孔', '箱', '管', '篦', '盖']) {
      if (name.contains(k)) return true;
    }
    // ③ 兜底：不转（保守 —— 转了不好认的代价 > 不转）
    return false;
  }

  /// 每个标签点处的**线路方向角**（度，屏幕/CAD 坐标系的逆时针角）。
  ///
  /// 用途：让井/箱这类矩形符号**顺着杆路摆放**（现场图纸惯例），
  /// 而不是所有符号都朝一个方向。
  ///
  /// 取法：
  ///  · 找到该点所在的链（`buildLabelChains`），取它在链中的前/后邻；
  ///  · 有前后邻 → 用两者连线方向（转角处自然过渡）；
  ///  · 只有一侧 → 用那一侧的方向；
  ///  · 孤立点 → 0°。
  static Map<String, double> _directionDegAt(List<MapLabel> labels,
      double baseLon, double baseLat, double scaleX, double scaleY) {
    final out = <String, double>{};
    List<double> xy(MapLabel l) =>
        [(l.lon - baseLon) * scaleX, (l.lat - baseLat) * scaleY];

    for (final chain in buildLabelChains(labels)) {
      if (chain.length < 2) continue;
      for (var i = 0; i < chain.length; i++) {
        final cur = xy(chain[i]);
        List<double>? prev = i > 0 ? xy(chain[i - 1]) : null;
        List<double>? next = i < chain.length - 1 ? xy(chain[i + 1]) : null;
        double dx, dy;
        if (prev != null && next != null) {
          // 转角处：前后邻连线，方向更稳
          dx = next[0] - prev[0];
          dy = next[1] - prev[1];
        } else if (next != null) {
          dx = next[0] - cur[0];
          dy = next[1] - cur[1];
        } else if (prev != null) {
          dx = cur[0] - prev[0];
          dy = cur[1] - prev[1];
        } else {
          continue;
        }
        if (dx.abs() < 1e-9 && dy.abs() < 1e-9) continue;
        out[chain[i].id] = math.atan2(dy, dx) * 180 / math.pi;
      }
    }
    return out;
  }


  ///
  /// [rotDeg]：旋转角（度）。**符号随线路方向**是现场图纸的惯例 ——
  /// 井/箱盖多为矩形，顺着杆路摆放才看得顺；原来固定 50=0，
  /// 结果所有井方向一致（用户反馈："井为什么方向一直是一个"）。
  ///
  /// [colorRgb]：**单个图块**的颜色覆盖（0xRRGGBB，0=跟随图层默认）。
  /// 用户口径："图标颜色不是统一颜色，每个图标点都可以自定义颜色"。
  /// R2000 写 62(ACI) + 420(真彩)；R12 只写 62。
  static void _appendInsert(
      _Ctx c, String layer, String name, double x, double y,
      {double sx = 1, double sy = 1, double rotDeg = 0, int colorRgb = 0}) {
    c.ent('INSERT', layer, 'AcDbBlockReference');
    // 角度归一到 [0,360)，避免 -0.0 之类
    var rot = rotDeg % 360;
    if (rot < 0) rot += 360;
    if (colorRgb != 0) {
      c.sb.write('62\n${_aciForRgb(colorRgb)}\n');
    }
    c.sb.write('2\n$name\n'
        '10\n${_fmt(x)}\n20\n${_fmt(y)}\n30\n0\n'
        '41\n${_fmt(sx)}\n42\n${_fmt(sy)}\n50\n${rot.toStringAsFixed(1)}\n');
    if (colorRgb != 0 && c.r2000) {
      c.sb.write('420\n${colorRgb & 0xFFFFFF}\n');
    }
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
      double cx, double cy, double h, String text, {bool style = true}) {
    if (text.isEmpty) return;
    var w = 0.0;
    for (final r in text.runes) {
      w += r > 0x2E7F ? h : h * 0.55;
    }
    // **必须显式指定样式**：默认 Standard 是 txt.shx（纯西文 SHX），
    // 中文会显示成问号/乱码。用户反馈"里面的字体都是乱码"即此。
    _text(c, layer, cx - w / 2, cy - h * 0.35, h, text, style: style);
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
      _Ctx c, DxfVersion version, bool completionRed,
      {Map<String, int> colorOverrides = const {}}) {
    final specs = DxfLayers.resolve(completionRed: completionRed);
    // 用户可配颜色：key = 图层名，value = 0xRRGGBB（或 0 = 不覆盖）。
    int? rgbOf(String layer) {
      final v = colorOverrides[layer];
      return (v == null || v == 0) ? null : v;
    }

    c.sb.write('0\nSECTION\n2\nTABLES\n');
    if (version == DxfVersion.r2000) {
      final layerTableH = c.h.next();
      c.sb.write('0\nTABLE\n2\nLAYER\n5\n$layerTableH\n330\n0\n'
          '100\nAcDbSymbolTable\n70\n${specs.length}\n');
      for (final s in specs) {
        final ov = rgbOf(s.name);
        final tc = ov ?? s.trueColor;
        // ACI 跟随真彩色的主色（R12 只有 ACI，靠它表现颜色）。
        final aci = ov == null ? s.aci : _aciForRgb(ov);
        c.sb.write('0\nLAYER\n5\n${c.h.next()}\n330\n$layerTableH\n'
            '100\nAcDbSymbolTableRecord\n100\nAcDbLayerTableRecord\n'
            '2\n${s.name}\n70\n0\n62\n$aci\n6\n${s.lineType}\n');
        c.sb.write('370\n${s.lineWeight}\n');
        if (tc != null) c.sb.write('420\n$tc\n');
      }
      c.sb.write('0\nENDTAB\n');
      final styleTableH = c.h.next();
      c.sb.write('0\nTABLE\n2\nSTYLE\n5\n$styleTableH\n330\n0\n'
          '100\nAcDbSymbolTable\n70\n2\n');
      c.sb.write('0\nSTYLE\n5\n${c.h.next()}\n330\n$styleTableH\n'
          '100\nAcDbSymbolTableRecord\n100\nAcDbTextStyleTableRecord\n'
          '2\nSimSun\n70\n0\n40\n0\n41\n1\n50\n0\n71\n0\n42\n3\n'
          '3\nsimsun.ttc\n4\n\n');
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
        final ov = rgbOf(s.name);
        final aci = ov == null ? s.aci : _aciForRgb(ov);
        c.sb.write('0\nLAYER\n2\n${s.name}\n70\n0\n62\n$aci\n6\n${s.lineType}\n');
      }
      c.sb.write('0\nENDTAB\n');
      c.sb.write('0\nTABLE\n2\nSTYLE\n70\n2\n');
      c.sb.write('0\nSTYLE\n2\nSimSun\n70\n0\n40\n0\n41\n1\n50\n0\n71\n0\n42\n3\n3\nsimsun.ttc\n4\n\n');
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
    // 按等级分档简化（主干细容差保留形态，小路大容差瘦身，N4）。
    //
    // ⚠️ 容差是"米"，而 cart 已是"图纸单位"（v3.13 起 1 单位 = 比例/1000 米）。
    // 不换算的话，1:3000 下容差会被放大 3 倍解读 —— 主干道会被削得过头。
    final unitsPerMeter = scale / 1000.0;
    final simp = _simplifyPath(cart, _roadTolM(rp.grade) / unitsPerMeter);
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
    // 每约 200 **米**一处：n 处均布，第 i 处在弧长 totalLen*(2i-1)/(2n)（n=1 时中点）。
    //
    // 注意：pts 是**图纸单位**（v3.13 起 1 单位 = 比例/1000 米），
    // 所以「200 米」要先换算成图纸单位；否则 1:3000 下会被当成
    // 200 单位 = 600 米，路名数量会少 3 倍。
    final spacingUnits = 200.0 / (scale / 1000.0);
    final n = math.max(1, (totalLen / spacingUnits).round());
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

  // ---- 纸面毫米 → 图纸单位（唯一换算入口）----

  /// 纸面毫米 → 图纸单位。
  ///
  /// ## 口径（按用户插件的实际行为对齐，v3.12）
  /// **1 纸面毫米 = 1 图纸单位**，与出图比例无关。
  ///
  /// 依据：解析用户插件产出的 `66.dxf` 实测 ——
  ///   · 字高 2.5   （插件设置里"字高 2.5"）
  ///   · 块按 xscale=1.0 插入（块本身 3.0 单位见方）
  ///   · 线宽 0.5
  /// 三者都是"图纸单位 = 设置里的毫米数"，没有乘任何比例因子。
  ///
  /// ## 旧口径为什么错
  /// 原实现是 `mm / 1000 * scale`：把 1 纸面毫米当成"1 米 × 比例"，
  /// 1:3000 时放大 3 倍 → 字高 7.5、块缩放 3.0，与插件画的差整整 3 倍
  /// （用户原话"差了好多"）。
  ///
  /// ## 关于"米"的说明
  /// 本导出器的坐标单位是**米**（本地平面投影），以往为了"纸面毫米"去乘
  /// 比例。但用户插件、以及现场照它出的图，都直接把图纸单位当毫米用
  /// （CAD 里按 1:1 画、打印时再设比例）。这里跟随用户口径：
  /// 尺寸数值 = 纸面毫米数，直接用。
  static double _mmOf(double mm, int scale) => mm;

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
