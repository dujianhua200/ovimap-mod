import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../geo/geo_util.dart';
import '../models/diff_report.dart';
import '../models/map_label.dart';
import '../services/store.dart';
import 'topo.dart';

/// CSV 导出：杆点坐标表 + 配线芯线占用表。
class CsvExporter {
  CsvExporter._();

  /// 导出杆点 CSV：编号、WGS-84 纬度、WGS-84 经度。
  static Future<File> exportPoles(String name, List<MapLabel> labels) async {
    final sb = StringBuffer();
    sb.write('杆子编号,纬度(WGS84),经度(WGS84)\r\n');
    var poleIndex = 1;
    for (final label in labels) {
      if (label.typeId == 'track' || label.typeId == 'none') continue;
      var number = label.name.trim();
      if (number.isEmpty) number = '$poleIndex';
      sb.write('${_csvEscape(number)},'
          '${label.lat.toStringAsFixed(8)},'
          '${label.lon.toStringAsFixed(8)}\r\n');
      poleIndex++;
    }
    if (poleIndex == 1) throw Exception('没有可导出的杆子标签');
    final dir = await LabelStore.instance.exportDir();
    final f = File('${dir.path}/${sanitizeName(name)}.csv');
    // UTF-8 BOM，Excel 直接打开不乱码
    await robustWriteBytes(f, [
      0xEF, 0xBB, 0xBF,
      ...utf8.encode(sb.toString()),
    ]);
    return f;
  }

  /// 配线芯线占用表（CSV）：基于拓扑树逐边输出上下级、连接光缆、芯数，
  /// 并对每个分光器箱做两项校验：
  /// 1) 下级数量 ≤ 分光比下行端口数；
  /// 2) 分光器数量 ≤ 上游光缆芯数（每个分光器占 1 芯）。
  static Future<(File, int)> exportCoreTable(
      String name, List<MapLabel> labels) async {
    final roots = Topology.buildTree(labels);
    final all = Topology.flatten(roots);
    Topology.assignTitles(roots);
    final sb = StringBuffer();
    sb.write('序号,上级节点,下级节点,连接光缆,光缆芯数,上级分光比,校验\r\n');
    var idx = 1, warnCount = 0;
    for (final n in all) {
      for (final c in n.children) {
        var check = 'OK';
        final pr = Topology.parseRatio(n.src.splitterRatio);
        if (pr > 0 && n.children.length > pr) {
          check = '端口不足：${n.title}分光比1:$pr，已有${n.children.length}个下级';
        } else if (pr > 0 && n.cableCores > 0 && n.children.length > n.cableCores) {
          check = '馈用芯不足：${c.cable}仅${n.cableCores}芯，'
              '${n.title}内${n.children.length}台分光器占${n.children.length}芯';
        }
        if (check != 'OK') warnCount++;
        sb.write('${idx++},'
            '${_csvEscape(n.title)},'
            '${_csvEscape(c.title)},'
            '${_csvEscape(c.cable)},'
            '${c.cableCores > 0 ? c.cableCores : ''},'
            '${_csvEscape(n.src.splitterRatio)},'
            '${_csvEscape(check)}\r\n');
      }
    }
    sb.write('\r\n汇总\r\n');
    sb.write('箱名,分光比,下级占用,剩余端口,上游芯数,结论\r\n');
    for (final n in all) {
      final ratio = Topology.parseRatio(n.src.splitterRatio);
      if (ratio <= 0) continue;
      final used = n.children.length;
      final concl = used <= ratio ? '正常' : '超限！需换更大分光比或增加一级分光';
      if (used > ratio) warnCount++;
      sb.write('${_csvEscape(n.title)},'
          '${n.src.splitterRatio},'
          '$used,${ratio - used > 0 ? ratio - used : 0},'
          '${n.cableCores > 0 ? n.cableCores : ''},'
          '$concl\r\n');
    }
    if (idx == 1) {
      throw Exception('拓扑树为空：请先在拓扑编辑里连接节点，或标记光交/分光箱/分纤盒');
    }
    final dir = await LabelStore.instance.exportDir();
    final f = File('${dir.path}/${sanitizeName(name)}_芯线占用表.csv');
    await robustWriteBytes(f, [
      0xEF, 0xBB, 0xBF,
      ...utf8.encode(sb.toString()),
    ]);
    return (f, warnCount);
  }

  static String _csvEscape(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  // ================= 材料统计一键出表 =================

  /// 材料统计 CSV：符号分类数量 + 按敷设方式的分段长度 + 盘留合计 +
  /// 按段光缆型号的芯线公里数。设计概算 / 竣工结算的基础数据表。
  static Future<File> exportMaterialStats(
      String name, List<MapLabel> labels) async {
    final sb = StringBuffer();
    // ---- 1. 符号分类数量 ----
    sb.write('【符号分类数量】\r\n');
    sb.write('类型,数量\r\n');
    final typeCount = <String, int>{};
    for (final l in labels) {
      if (l.typeId == 'track' || l.typeId == 'none') continue;
      final n = l.type.name;
      typeCount[n] = (typeCount[n] ?? 0) + 1;
    }
    for (final e in typeCount.entries) {
      sb.write('${_csvEscape(e.key)},${e.value}\r\n');
    }
    // ---- 2. 按敷设方式的分段长度 ----
    sb.write('\r\n【分段长度（按敷设方式）】\r\n');
    sb.write('敷设方式,长度(米),段数\r\n');
    final kindLen = <int, double>{};
    final kindCnt = <int, int>{};
    final kindNames = {0: '默认', 1: '架空', 2: '埋地', 3: '管道'};
    var totalLen = 0.0, slackTotal = 0.0;
    for (final chain in buildLabelChains(labels)) {
      for (var i = 1; i < chain.length; i++) {
        final a = chain[i - 1], b = chain[i];
        final d = _segDist(a, b);
        kindLen[b.segKind] = (kindLen[b.segKind] ?? 0) + d;
        kindCnt[b.segKind] = (kindCnt[b.segKind] ?? 0) + 1;
        totalLen += d;
        slackTotal += b.slackM;
      }
    }
    for (final e in kindLen.entries) {
      sb.write('${_csvEscape(kindNames[e.key] ?? '${e.key}')},'
          '${e.value.toStringAsFixed(1)},${kindCnt[e.key]}\r\n');
    }
    sb.write('合计,${totalLen.toStringAsFixed(1)},'
        '${kindCnt.values.fold(0, (a, b) => a + b)}\r\n');
    // ---- 3. 按段光缆型号统计芯线公里 ----
    sb.write('\r\n【段光缆型号统计】\r\n');
    sb.write('型号,芯数,长度(米),芯线公里数\r\n');
    final cableLen = <String, double>{};
    for (final chain in buildLabelChains(labels)) {
      for (var i = 1; i < chain.length; i++) {
        final a = chain[i - 1], b = chain[i];
        final spec = b.segCable.trim();
        if (spec.isEmpty) continue;
        cableLen[spec] = (cableLen[spec] ?? 0) + _segDist(a, b);
      }
    }
    for (final e in cableLen.entries) {
      final cores = Topology.parseCores(e.key);
      final km = e.value / 1000 * (cores > 0 ? cores : 1);
      sb.write('${_csvEscape(e.key)},'
          '${cores > 0 ? cores : ''},'
          '${e.value.toStringAsFixed(1)},${km.toStringAsFixed(2)}\r\n');
    }
    // ---- 4. 盘留 ----
    sb.write('\r\n【接头盘留】\r\n');
    sb.write('盘留合计(米),$slackTotal\r\n');
    sb.write('口径说明,竣工光缆用量=丈量长度+接头盘留；分段长度优先取人工确认值\r\n');

    final dir = await LabelStore.instance.exportDir();
    final f = File('${dir.path}/${sanitizeName(name)}_材料统计.csv');
    await robustWriteBytes(f, [0xEF, 0xBB, 0xBF, ...utf8.encode(sb.toString())]);
    return f;
  }

  // ================= 工程量清单（451 号文口径） =================

  /// 工程量清单 CSV：按通信线路工程定额项归类，数量由现场打点自动统计。
  /// 口径参考 451 号文（技工 114 元/工日、辅助材料费率 0.3%），
  /// 具体以设计文件与竣工实测为准。
  static Future<File> exportBoq(String name, List<MapLabel> labels) async {
    // 分段长度（按敷设方式）
    final kindLen = <int, double>{};
    for (final chain in buildLabelChains(labels)) {
      for (var i = 1; i < chain.length; i++) {
        final a = chain[i - 1], b = chain[i];
        kindLen[b.segKind] = (kindLen[b.segKind] ?? 0) + _segDist(a, b);
      }
    }
    String lenKm(int kind) => ((kindLen[kind] ?? 0) / 1000).toStringAsFixed(3);
    int count(String typeId) =>
        labels.where((l) => l.typeId == typeId).length;

    final sb = StringBuffer();
    sb.write('序号,定额项目,单位,数量,备注\r\n');
    var idx = 1;
    void row(String item, String unit, String qty, String note) {
      sb.write('${idx++},${_csvEscape(item)},$unit,${_csvEscape(qty)},'
          '${_csvEscape(note)}\r\n');
    }

    row('架空光缆敷设', '千米', lenKm(1), '敷设方式=架空 的分段长度合计');
    row('管道光缆敷设', '千米', lenKm(3), '敷设方式=管道 的分段长度合计');
    row('埋式光缆敷设', '千米', lenKm(2), '敷设方式=埋地 的分段长度合计');
    row('光缆接续', '头', '${count('riser')}', '以引上点计，接头数量以设计/竣工为准');
    row('人孔', '个', '${count('manhole')}', '');
    row('手井', '个', '${count('handwell')}', '');
    row('水泥杆（杆高以设计为准）', '根',
        '${count('concrete')}', '8m/10m 分列需在名称中注明后人工拆分');
    row('木杆', '根', '${count('wood')}', '');
    row('电力杆', '根', '${count('electric')}', '借杆挂缆需另行计列');
    row('光缆交接箱', '个', '${count('crossbox')}', '');
    row('分光器（含箱体安装）', '个', '${count('splitterbox')}', '分光比分项见芯线占用表');
    row('分纤盒', '个', '${count('fiberbox')}', '');
    row('ONU 箱', '个', '${count('onubox')}', '');
    row('机房/基站设备安装', '处',
        '${count('room') + count('bts')}', '');
    sb.write('\r\n口径说明,工程量由滑洲云图现场打点自动统计；'
        '预算口径参考 451 号文：技工 114 元/工日、辅助材料费率 0.3%；'
        '最终以设计文件与竣工实测为准\r\n');

    final dir = await LabelStore.instance.exportDir();
    final f = File('${dir.path}/${sanitizeName(name)}_工程量清单.csv');
    await robustWriteBytes(f, [0xEF, 0xBB, 0xBF, ...utf8.encode(sb.toString())]);
    return f;
  }

  // ================= 竣工对比设计 =================

  /// 计算设计 ↔ 竣工变更对照报告（纯函数，可单测）。
  ///
  /// · 杆位：竣工有设计无=新增；设计有竣工无=缺失；双方有且偏移 > [offsetThreshold]=偏移；
  ///   否则=一致。杆位 key 取名称，空名回退 `#type@seq`。
  /// · 段距：同名相邻杆对（`起点名>终点名`）的段距差。
  /// · 净长度差 = 竣工总段距 − 设计总段距（不含盘留）。
  static DesignDiffReport buildDesignDiff(
    List<MapLabel> design,
    List<MapLabel> completion, {
    double offsetThreshold = 1.0,
  }) {
    final designByKey = {for (final l in _diffCandidates(design)) _diffKey(l): l};
    final comp = _diffCandidates(completion);
    final compKeys = {for (final l in comp) _diffKey(l)};

    final poles = <DiffPoleItem>[];
    var added = 0, moved = 0, kept = 0;
    for (final l in comp) {
      final k = _diffKey(l);
      final d = designByKey[k];
      if (d == null) {
        added++;
        poles.add(DiffPoleItem(
          key: k,
          status: DiffStatus.added,
          cLat: l.lat,
          cLon: l.lon,
        ));
      } else {
        final off = _haversine(d.lat, d.lon, l.lat, l.lon);
        final status =
            off > offsetThreshold ? DiffStatus.moved : DiffStatus.same;
        if (status == DiffStatus.moved) {
          moved++;
        } else {
          kept++;
        }
        poles.add(DiffPoleItem(
          key: k,
          status: status,
          dLat: d.lat,
          dLon: d.lon,
          cLat: l.lat,
          cLon: l.lon,
          offsetM: off,
        ));
      }
    }
    var removed = 0;
    for (final l in _diffCandidates(design)) {
      final k = _diffKey(l);
      if (!compKeys.contains(k)) {
        removed++;
        poles.add(DiffPoleItem(
          key: k,
          status: DiffStatus.removed,
          dLat: l.lat,
          dLon: l.lon,
        ));
      }
    }

    // 段距对比：同名相邻杆对
    final designSegs = <String, double>{};
    for (final chain in buildLabelChains(design)) {
      for (var i = 1; i < chain.length; i++) {
        final a = chain[i - 1], b = chain[i];
        final na = a.name.trim(), nb = b.name.trim();
        if (na.isEmpty || nb.isEmpty) continue;
        designSegs['$na>$nb'] = _segDist(a, b);
      }
    }
    final segs = <DiffSegItem>[];
    for (final chain in buildLabelChains(completion)) {
      for (var i = 1; i < chain.length; i++) {
        final a = chain[i - 1], b = chain[i];
        final na = a.name.trim(), nb = b.name.trim();
        if (na.isEmpty || nb.isEmpty) continue;
        final dk = '$na>$nb';
        final dd = designSegs[dk];
        if (dd == null) continue;
        final cd = _segDist(a, b);
        segs.add(DiffSegItem(
            seg: dk, designM: dd, compM: cd, deltaM: cd - dd));
      }
    }

    final summary = DiffSummary(
      added: added,
      removed: removed,
      moved: moved,
      kept: kept,
      netLenDiffM: _totalLen(completion) - _totalLen(design),
    );
    final notes = <String>[];
    if (segs.isEmpty) {
      notes.add('无同名相邻杆段可对比（请保证设计与竣工使用相同编号）');
    }
    return DesignDiffReport(
        poles: poles, segs: segs, summary: summary, notes: notes);
  }

  /// 竣工(当前)与设计对比 CSV：变更量汇总 + 杆位增/删/偏移 + 同名相邻杆段距对比。
  /// [designLabels] 设计版点位，[completionLabels] 竣工版点位。
  /// [offsetThreshold] 位置偏移阈值（米，默认 1m）。旧签名兼容：新增参数带默认值。
  static Future<File> exportDesignDiff(String name,
      List<MapLabel> designLabels, List<MapLabel> completionLabels,
      {double offsetThreshold = 1.0}) async {
    final report = buildDesignDiff(designLabels, completionLabels,
        offsetThreshold: offsetThreshold);
    final s = report.summary;

    final sb = StringBuffer();
    // 变更量汇总（新增段；旧栏目全部保留）
    sb.write('【变更量汇总】\r\n');
    sb.write('新增杆位,${s.added}\r\n');
    sb.write('缺失杆位,${s.removed}\r\n');
    sb.write('偏移杆位,${s.moved}（偏移阈值 ${offsetThreshold.toStringAsFixed(1)} 米）\r\n');
    sb.write('一致杆位,${s.kept}\r\n');
    sb.write('净长度差(米),${s.netLenDiffM.toStringAsFixed(1)}\r\n');

    sb.write('\r\n【杆位对比】\r\n');
    sb.write('编号,状态,设计坐标,竣工坐标,偏移(米)\r\n');
    for (final p in report.poles) {
      switch (p.status) {
        case DiffStatus.added:
          sb.write('${_csvEscape(p.key)},新增,无,'
              '${_coordLL(p.cLat, p.cLon)},-\r\n');
          break;
        case DiffStatus.removed:
          sb.write('${_csvEscape(p.key)},缺失（设计有竣工无）,'
              '${_coordLL(p.dLat, p.dLon)},无,-\r\n');
          break;
        case DiffStatus.moved:
        case DiffStatus.same:
          sb.write('${_csvEscape(p.key)},'
              '${p.status == DiffStatus.moved ? '偏移' : '一致'},'
              '${_coordLL(p.dLat, p.dLon)},${_coordLL(p.cLat, p.cLon)},'
              '${p.offsetM.toStringAsFixed(1)}\r\n');
          break;
      }
    }
    sb.write('合计,新增${s.added} · 偏移${s.moved} · 一致${s.kept} · 缺失${s.removed},,,\r\n');

    // 段距对比：同名相邻杆对
    sb.write('\r\n【段距对比（同名相邻杆）】\r\n');
    sb.write('杆段,设计距离(米),竣工距离(米),差值(米)\r\n');
    for (final seg in report.segs) {
      sb.write('${_csvEscape(seg.seg)},${seg.designM.toStringAsFixed(1)},'
          '${seg.compM.toStringAsFixed(1)},${seg.deltaM.toStringAsFixed(1)}\r\n');
    }
    if (report.segs.isEmpty) {
      sb.write('提示,没有可对比的同名相邻杆段（请保证设计与竣工使用相同编号）,,\r\n');
    }

    final dir = await LabelStore.instance.exportDir();
    final f = File('${dir.path}/${sanitizeName(name)}_竣工对比设计.csv');
    await robustWriteBytes(f, [0xEF, 0xBB, 0xBF, ...utf8.encode(sb.toString())]);
    return f;
  }

  /// 参与对照的点位：排除轨迹/无标签。
  static List<MapLabel> _diffCandidates(List<MapLabel> labels) =>
      labels.where((l) => l.typeId != 'track' && l.typeId != 'none').toList();

  /// 对照 key：优先名称，空名回退 `#type@seq`。
  static String _diffKey(MapLabel l) {
    final n = l.name.trim();
    return n.isNotEmpty ? n : '#${l.typeId}@${l.seq}';
  }

  /// 总段距（Σ 链上相邻段距，不含盘留）。
  static double _totalLen(List<MapLabel> labels) {
    var total = 0.0;
    for (final chain in buildLabelChains(labels)) {
      for (var i = 1; i < chain.length; i++) {
        total += _segDist(chain[i - 1], chain[i]);
      }
    }
    return total;
  }

  static String _coordLL(double? lat, double? lon) {
    if (lat == null || lon == null) return '';
    return '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
  }

  /// 段距（标注优先口径）——唯一实现见 [GeoUtil.segLenLabelFirst]。
  static double _segDist(MapLabel a, MapLabel b) =>
      GeoUtil.segLenLabelFirst(a, b);

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
}
