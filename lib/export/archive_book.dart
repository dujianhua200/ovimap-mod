import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import '../geo/geo_util.dart';
import '../models/map_label.dart';
import '../services/store.dart';
import 'csv.dart';
import 'dxf.dart';
import 'dxf_version.dart';
import 'photo_book.dart';

/// 成册结果：ZIP 文件 + 已包含项 + 缺失（跳过）项。
class ArchiveBookResult {
  final File zip;
  final List<String> included;
  final List<String> skipped;

  ArchiveBookResult(this.zip, this.included, this.skipped);
}

/// 竣工资料一键成册（ZIP）：**严格 4 项**
/// （DXF 路由图 + 工程量清单 CSV + 材料统计 CSV + 竣工照片册），
/// 附「成册说明.txt」。
///
/// 缺项（如无挂接照片）逐个 try/catch 跳过，不抛错，记入 [ArchiveBookResult.skipped]
/// 并在说明页标注。
class ArchiveBookExporter {
  ArchiveBookExporter._();

  /// 一键成册：逐个子产物生成（失败/无数据 → 跳过），最后 `ZipEncoder` 组装。
  static Future<ArchiveBookResult> export({
    required String name,
    required List<MapLabel> labels,
    String folderId = '',
    int pointCount = 0,
    double totalLenM = 0,
    String editMode = 'completion',
    String segPrefix = '', // 段标前缀（如 埋／架）：空串=仅数字；透传自 AppState.segPrefix
  }) async {
    final archive = Archive();
    final included = <String>[];
    final skipped = <String>[];

    // 1) DXF 路由图（复用 DxfExporter；不抓取周边矢量，保证离线可用）
    //    成册资料要交给结算/甲方，兼容性优先级最高 → **固定 R12（AC1009）**，
    //    与全局默认一致（这也是成册最初的原始语义）。
    //    R2000 用的是最小表集（TABLES 仅 LAYER/STYLE），个别老 CAD 可能提示"修复"，
    //    不适合作为对外交付物，故成册不采用。
    try {
      final r = await DxfExporter.export(
        name: name,
        labels: labels,
        includeSurroundings: false,
        version: DxfVersion.r12,
        segPrefix: segPrefix,
      );
      final bytes = r.file.readAsBytesSync();
      archive.addFile(ArchiveFile('路由图.dxf', bytes.length, bytes));
      included.add('路由图.dxf');
    } catch (e) {
      skipped.add('路由图.dxf（$e）');
    }

    // 2) 工程量清单（451 号文口径）
    try {
      final f = await CsvExporter.exportBoq(name, labels);
      final bytes = f.readAsBytesSync();
      archive.addFile(ArchiveFile('工程量清单.csv', bytes.length, bytes));
      included.add('工程量清单.csv');
    } catch (e) {
      skipped.add('工程量清单.csv（$e）');
    }

    // 3) 材料统计
    try {
      final f = await CsvExporter.exportMaterialStats(name, labels);
      final bytes = f.readAsBytesSync();
      archive.addFile(ArchiveFile('材料统计.csv', bytes.length, bytes));
      included.add('材料统计.csv');
    } catch (e) {
      skipped.add('材料统计.csv（$e）');
    }

    // 4) 竣工照片册（复用 PhotoBookExporter；无挂接照片时其抛错 → 跳过）
    try {
      final f = await PhotoBookExporter.export(name, labels);
      final bytes = f.readAsBytesSync();
      archive.addFile(ArchiveFile('照片册.zip', bytes.length, bytes));
      included.add('照片册.zip');
    } catch (_) {
      skipped.add('照片册（无挂接照片）');
    }

    // 附：成册说明.txt
    final pts = pointCount > 0 ? pointCount : _pointCount(labels);
    final len = totalLenM > 0 ? totalLenM : totalLenOf(labels);
    final now = DateTime.now();
    final ts = '${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}:${_two(now.minute)}';
    final sb = StringBuffer()
      ..write('滑洲云图 · 竣工资料成册说明\r\n')
      ..write('工程名称：${name.isEmpty ? '未命名项目' : name}\r\n')
      ..write('资料类型：${editMode == 'completion' ? '竣工' : '设计'}\r\n')
      ..write('点位数：$pts\r\n')
      ..write('总里程：${len.toStringAsFixed(1)} 米\r\n')
      ..write('生成时间：$ts\r\n')
      ..write('\r\n包含资料：\r\n');
    for (final e in included) {
      sb.write('  · $e\r\n');
    }
    if (skipped.isNotEmpty) {
      sb.write('\r\n缺项（已跳过）：\r\n');
      for (final e in skipped) {
        sb.write('  · $e\r\n');
      }
    }
    sb.write('\r\n说明：仅含 路由图 / 工程量清单 / 材料统计 / 照片册 四项；'
        '口径参考 451 号文，最终以设计文件与竣工实测为准。\r\n');
    final noteBytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(sb.toString())];
    archive.addFile(ArchiveFile('成册说明.txt', noteBytes.length, noteBytes));

    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null || zipBytes.isEmpty) {
      throw Exception('成册打包失败');
    }
    final dir = await LabelStore.instance.exportDir();
    final out = File('${dir.path}/${sanitizeName(name)}_竣工资料成册.zip');
    await robustWriteBytes(out, zipBytes);
    return ArchiveBookResult(out, included, skipped);
  }

  /// 参与统计的点位（排除轨迹/无标签）。
  static int _pointCount(List<MapLabel> labels) =>
      labels.where((l) => l.typeId != 'track' && l.typeId != 'none').length;

  /// 总里程（Σ 段距），口径与 [CsvExporter] 一致。
  static double totalLenOf(List<MapLabel> labels) {
    var total = 0.0;
    for (final chain in buildLabelChains(labels)) {
      for (var i = 1; i < chain.length; i++) {
        total += _segDist(chain[i - 1], chain[i]);
      }
    }
    return total;
  }

  /// 段距（标注优先口径）——唯一实现见 [GeoUtil.segLenLabelFirst]。
  static double _segDist(MapLabel a, MapLabel b) =>
      GeoUtil.segLenLabelFirst(a, b);

  static String _two(int v) => v.toString().padLeft(2, '0');
}
