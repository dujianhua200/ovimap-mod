import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../export/basemap.dart';
import '../../export/dxf.dart';
import '../../export/dxf_version.dart';
import '../../export/local_basemap.dart';
import '../../services/app_paths.dart';
import '../../services/export_saver.dart';
import '../../services/store.dart';
import '../../state/app_state.dart';
import '../dialogs.dart';

/// 批量导出结果汇总（纯数据，便于测试断言与 UI 汇报）。
class BatchExportSummary {
  const BatchExportSummary({
    required this.ok,
    required this.skipped,
    required this.failed,
    required this.producedDirs,
  });

  /// 成功导出的工程数。
  final int ok;

  /// 因空工程被跳过的工程名（含原名，未清洗）。
  final List<String> skipped;

  /// 失败的「目录名（原因）」列表。
  final List<String> failed;

  /// 实际产出的子目录名（与 `root` 拼接即为落盘目录）。
  final List<String> producedDirs;

  /// 面向用户的一行中文摘要（目录另行拼接，调用方补）。
  String get message {
    final parts = <String>['批量导出完成：成功 $ok 个'];
    if (skipped.isNotEmpty) parts.add('空工程跳过 ${skipped.length} 个');
    if (failed.isNotEmpty) parts.add('失败 ${failed.length} 个');
    return parts.join(' · ');
  }
}

/// 批量导出 DXF（T21）：把多个选中工程各导出到 `导出/批量/<工程名>/` 子目录。
///
/// **复用既有 [DxfExporter.export]（不改其语义）**；导出选项沿用「导出成果」里
/// 用户上次勾选的记忆值（同一批 prefs 键），保证与单工程导出**口径一致**。
/// 路径统一走 [AppPaths.exportDir]（平台收口），交付/揭示目录走 [ExportSaver]。
Future<void> batchExportDxf(
  BuildContext context,
  AppState st,
  List<CollectionMeta> metas,
) async {
  if (metas.isEmpty) {
    toast(context, '请先选择要导出的工程（Ctrl/Shift 多选）');
    return;
  }
  if (!context.mounted) return;
  toast(context, '正在批量导出 ${metas.length} 个工程…');

  final base = await AppPaths.exportDir();
  final root = Directory('${base.path}/批量');
  try {
    await root.create(recursive: true);
  } catch (e) {
    if (context.mounted) toast(context, '创建导出目录失败：$e');
    return;
  }

  final summary = await runBatchExport(
    store: st.store,
    metas: metas,
    root: root,
    segPrefix: st.segPrefix,
  );

  if (!context.mounted) return;
  toast(context, '${summary.message}\n目录：${root.path}');

  if (summary.ok > 0) {
    await ExportSaver.revealDirectory(root);
  }
}

/// 批量导出**纯逻辑**（可测试、零 UI、零网络）：
/// 把 [metas] 中每个非空工程导出到 `[root]/<工程名>/<工程名>.dxf`。
///
/// - 选项从与单工程导出相同的 prefs 键读取（口径一致）；
/// - 空工程跳过；同名工程自动追加 `-2/-3…` 避免互相覆盖；
/// - 单个工程失败不影响其余（记入 [BatchExportSummary.failed]）。
///
/// 不弹任何 UI、不打开资源管理器 —— 便于在单元测试里对「各子目录产物」断言。
Future<BatchExportSummary> runBatchExport({
  required LabelStore store,
  required List<CollectionMeta> metas,
  required Directory root,
  String segPrefix = '', // 段标前缀（如 埋／架）：空串=仅数字；透传自 AppState.segPrefix
}) async {
  final opts = await _DxfBatchOptions.fromPrefs();

  var ok = 0;
  final failed = <String>[];
  final skipped = <String>[];
  final usedDirs = <String>{};
  final produced = <String>[];

  for (final m in metas) {
    final baseName = sanitizeName(m.name.isEmpty ? '未命名' : m.name);
    // 同名工程避免互相覆盖：追加 -2/-3…
    var dirName = baseName;
    var n = 2;
    while (usedDirs.contains(dirName)) {
      dirName = '$baseName-$n';
      n++;
    }
    usedDirs.add(dirName);
    final sub = Directory('${root.path}/$dirName');
    try {
      // 读取也纳入 try：单个工程文件损坏（解析失败）只记失败，
      // 不中断整批（故障隔离到工程粒度）。
      final labels = await store.loadCollection(m.id);
      if (labels.isEmpty) {
        skipped.add(m.name.isEmpty ? '未命名' : m.name);
        continue;
      }
      await sub.create(recursive: true);
      final r = await DxfExporter.export(
        name: dirName,
        labels: labels,
        includeLabelSymbols: opts.symbols,
        corridorWidth: opts.corridor,
        includeSurroundings: opts.surroundings,
        showStakes: opts.stakes,
        showLegend: opts.legend,
        completionRed: opts.redline,
        straightenedWiring: opts.straightened,
        version: opts.version,
        rangeM: opts.rangeM,
        layerRoads: opts.layerRoads,
        layerBuildingOutline: opts.layerBldOutline,
        buildingFill: opts.layerBldFill,
        showMinorRoadNames: opts.minorRoadNames,
        layerPlaces: opts.layerPlaces,
        segPrefix: segPrefix,
        placesTdtFallback: opts.tdtFallback,
        tdtKey: opts.tdtKey,
        amapKey: opts.amapKey,
        overpassEndpoints: opts.overpassEndpoints,
        convertGcj: opts.convertGcj,
        refreshBasemap: false,
        localBasemap: opts.localBasemap,
      );
      // DxfExporter 先落到 exportDir()/<name>.dxf；再拷进各自子目录。
      final dest = File('${sub.path}/$dirName.dxf');
      if (r.file.absolute.path != dest.absolute.path) {
        await r.file.copy(dest.path);
      }
      ok++;
      produced.add(dirName);
    } catch (e) {
      failed.add('$dirName（$e）');
    }
  }

  return BatchExportSummary(
    ok: ok,
    skipped: skipped,
    failed: failed,
    producedDirs: produced,
  );
}

/// 批次导出选项（从与单工程导出相同的 prefs 键读取，保持口径一致）。
class _DxfBatchOptions {
  const _DxfBatchOptions({
    required this.symbols,
    required this.surroundings,
    required this.stakes,
    required this.legend,
    required this.redline,
    required this.straightened,
    required this.version,
    required this.rangeM,
    required this.corridor,
    required this.layerRoads,
    required this.layerBldOutline,
    required this.layerBldFill,
    required this.minorRoadNames,
    required this.layerPlaces,
    required this.tdtFallback,
    required this.tdtKey,
    required this.amapKey,
    required this.overpassEndpoints,
    required this.convertGcj,
    required this.localBasemap,
  });

  final bool symbols;
  final bool surroundings;
  final bool stakes;
  final bool legend;
  final bool redline;
  final bool straightened;
  final DxfVersion version;
  final double rangeM;
  final double corridor;
  final bool layerRoads;
  final bool layerBldOutline;
  final bool layerBldFill;
  final bool minorRoadNames;
  final bool layerPlaces;
  final bool tdtFallback;
  final String tdtKey;
  final String amapKey;
  final String overpassEndpoints;
  final bool convertGcj;
  final BasemapData? localBasemap;

  /// 读取「导出成果 → DXF」里持久化的同一批选项（默认值与 `showDxfOptions` 一致）。
  static Future<_DxfBatchOptions> fromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    bool opt(String k, bool def) => prefs.getBool(k) ?? def;

    // 本地开源矢量底图（离线优先，项目级复用）：读一次，整体复用。
    final localStore = await LocalBasemapStore.open();
    var hasLocal = localStore.exists();
    BasemapData? localBm = hasLocal ? await localStore.load() : null;
    if (localBm == null) hasLocal = false;

    final userKey = prefs.getString(AppState.prefTdtKey)?.trim() ?? '';
    final tdtKey = userKey.isEmpty ? AppState.builtinTdtKey : userKey;
    final userAmapKey = prefs.getString(AppState.prefAmapKey)?.trim() ?? '';
    final amapKey = userAmapKey.isEmpty ? AppState.builtinAmapKey : userAmapKey;
    final overpass =
        prefs.getString(AppState.prefOverpassEndpoints)?.trim() ?? '';
    final convertGcj =
        prefs.getString(AppState.prefTdtCoordSys) != AppState.tdtCoordWgs84;

    final surroundings = opt('dxfSurroundings', true);
    final useLocal = hasLocal && opt('dxfUseLocal', true);

    return _DxfBatchOptions(
      symbols: opt('dxfSymbols', true),
      surroundings: surroundings,
      stakes: opt('dxfStakes', true),
      legend: opt('dxfLegend', true),
      redline: opt('dxfRedline', false),
      straightened: opt('dxfStraightened', false),
      version: (prefs.getString('dxfVersion') ?? 'r12') == 'r2000'
          ? DxfVersion.r2000
          : DxfVersion.r12,
      rangeM: prefs.getDouble('dxfRangeM') ?? 880,
      corridor: double.tryParse(prefs.getString('dxfCorridor') ?? '0') ?? 0,
      layerRoads: opt('dxfLayerRoads', true),
      layerBldOutline: opt('dxfLayerBldOutline', true),
      layerBldFill: opt('dxfLayerBldFill', false),
      minorRoadNames: opt('dxfMinorRoadNames', false),
      layerPlaces: opt('dxfLayerPlaces', true),
      tdtFallback: opt('dxfTdtFallback', true),
      tdtKey: tdtKey,
      amapKey: amapKey,
      overpassEndpoints: overpass,
      convertGcj: convertGcj,
      localBasemap: (surroundings && useLocal) ? localBm : null,
    );
  }
}
