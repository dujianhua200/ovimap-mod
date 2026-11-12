import 'package:flutter/material.dart';

import '../../export/csv.dart';
import '../../geo/geo_util.dart';
import '../../models/map_label.dart';
import '../../services/export_saver.dart';
import '../../state/app_state.dart';
import '../dialogs.dart';
import '../../ui/design_tokens.dart';

/// 工程统计（桌面 E1）：点位总数 / 杆路总距离 / 敷设方式分布 / 光缆型号汇总。
///
/// **口径与「材料统计 CSV」（`CsvExporter.exportMaterialStats`）逐字一致**：
/// - 链口径复用 [buildLabelChains]（与地图连线 / DXF / KML / CSV 同源）；
/// - 段距 = 段标注数字 → `distanceM` → haversine（优先人工确认值）；
/// - 敷设方式 / 光缆型号取**段的后点**（`b.segKind` / `b.segCable`）；
/// - 盘留 = Σ `b.slackM`（竣工光缆用量 = 丈量长 + 盘留）。
/// 纯 Dart 计算，零网络；数据来自 `labels`（与导出同源，口径一致）。
class LayKindStat {
  const LayKindStat({required this.lenM, required this.segs});

  final double lenM;
  final int segs;
}

/// 统计结果（纯数据，便于测试断言）。
class ProjectStats {
  const ProjectStats({
    required this.pointCount,
    required this.segCount,
    required this.totalLenM,
    required this.slackTotalM,
    required this.byKind,
    required this.cableLenM,
  });

  /// 点位总数（全部 labels，含箱体/文字等非连线点）。
  final int pointCount;

  /// 段数（链上相邻点对，与材料统计「合计」行的段数同口径）。
  final int segCount;

  /// 杆路总距离（Σ 段距，米，不含盘留）。
  final double totalLenM;

  /// 接头盘留合计（米）。
  final double slackTotalM;

  /// 敷设方式 → 长度/段数（键为 `segKind`：0=默认 1=架空 2=埋地 3=管道）。
  final Map<int, LayKindStat> byKind;

  /// 光缆型号 → 长度（米）。
  final Map<String, double> cableLenM;
}

/// 敷设方式显示名（与 CSV/右栏属性面板一致）。
const Map<int, String> kSegKindNames = <int, String>{
  0: '默认',
  1: '架空',
  2: '埋地',
  3: '管道',
};

/// 段距口径：优先段标注里的数字，其次 distanceM，否则 haversine。
/// 与 `CsvExporter._segDist` 同判据（该私有函数不改，这里按同式实现并注明）。
double statsSegDist(MapLabel a, MapLabel b) {
  final t = b.distLabel.trim();
  if (t.isNotEmpty) {
    final m = RegExp(r'[\d.]+').firstMatch(t);
    final v = m == null ? null : double.tryParse(m.group(0) ?? '');
    if (v != null && v > 0) return v;
  }
  final dm = b.distanceM;
  if (dm != null && dm > 0) return dm;
  return GeoUtil.haversine(a.lat, a.lon, b.lat, b.lon);
}

/// 计算工程统计（纯函数，可测试）。
ProjectStats computeProjectStats(List<MapLabel> labels) {
  final byKind = <int, LayKindStat>{};
  final cableLen = <String, double>{};
  var totalLen = 0.0;
  var slackTotal = 0.0;
  var segs = 0;

  for (final chain in buildLabelChains(labels)) {
    for (var i = 1; i < chain.length; i++) {
      final a = chain[i - 1];
      final b = chain[i];
      final d = statsSegDist(a, b);
      totalLen += d;
      slackTotal += b.slackM;
      segs++;
      final k = b.segKind;
      final cur = byKind[k];
      byKind[k] = LayKindStat(lenM: (cur?.lenM ?? 0) + d, segs: (cur?.segs ?? 0) + 1);
      final spec = b.segCable.trim();
      if (spec.isNotEmpty) {
        cableLen[spec] = (cableLen[spec] ?? 0) + d;
      }
    }
  }

  return ProjectStats(
    pointCount: labels.length,
    segCount: segs,
    totalLenM: totalLen,
    slackTotalM: slackTotal,
    byKind: byKind,
    cableLenM: cableLen,
  );
}

/// 右栏「工程统计」区块：无选中点时展示打开工程的整体情况（E1）。
class StatsSection extends StatelessWidget {
  const StatsSection({super.key, required this.st});

  final AppState st;

  String get _projectName =>
      st.projectName.trim().isEmpty ? '未命名工程' : st.projectName.trim();

  Future<void> _exportCsv(BuildContext context) async {
    try {
      final f = await CsvExporter.exportPoles(_projectName, st.labels);
      if (!context.mounted) return;
      await ExportSaver.saveOrShare(context, f,
          suggestedName: f.uri.pathSegments.last);
    } catch (e) {
      if (context.mounted) toast(context, '导出点位表失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = computeProjectStats(st.labels);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TokC.field,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TokC.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('工程统计',
              style: TextStyle(
                  color: kTextMain,
                  fontSize: 13,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          _row('点位总数', '${s.pointCount}'),
          _row('杆路总距离', _fmtM(s.totalLenM)),
          if (s.slackTotalM > 0) _row('接头盘留合计', _fmtM(s.slackTotalM)),
          if (s.byKind.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text('敷设方式分布',
                style: TextStyle(color: kTextSub, fontSize: 11)),
            for (final e in s.byKind.entries)
              _row(_kindName(e.key),
                  '${_fmtM(e.value.lenM)} · ${e.value.segs} 段'),
          ],
          if (s.cableLenM.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text('光缆型号汇总',
                style: TextStyle(color: kTextSub, fontSize: 11)),
            for (final e in s.cableLenM.entries) _row(e.key, _fmtM(e.value)),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _exportCsv(context),
              icon: const Icon(Icons.table_view,
                  size: 15, color: kTextMain),
              label: const Text('导出点位表 CSV（Excel 排查用）',
                  style: TextStyle(color: kTextMain, fontSize: 12)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: TokC.divider),
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: kTextSub, fontSize: 12)),
            ),
            Text(value,
                style: const TextStyle(color: kTextMain, fontSize: 12)),
          ],
        ),
      );
  static String _kindName(int k) =>
      kSegKindNames[k] ?? '未知($k)';

  static String _fmtM(double m) => m >= 1000
      ? '${(m / 1000).toStringAsFixed(m >= 10000 ? 1 : 2)} km'
      : '${m.toStringAsFixed(m == m.roundToDouble() ? 0 : 1)} m';
}
