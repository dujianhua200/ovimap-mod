// R2000（AC1015）形态验证：图层线宽 370 / 真彩 420 / LWPOLYLINE / HATCH /
// 底图新图层渲染；以及 R12 反向断言（不得出现 370/420/LWPOLYLINE/HATCH）。
// 使用注入的合成 BasemapData，**不依赖网络**。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_validate.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '_dxf_fixture.dart';

/// 统计某图层上的 LWPOLYLINE 数量（R2000）。
int _lwPolyCount(String text, String layer) {
  final lines = text.split('\n');
  var count = 0;
  for (var i = 0; i + 1 < lines.length; i += 2) {
    if (lines[i].trim() != '0' || lines[i + 1].trim() != 'LWPOLYLINE') continue;
    for (var j = i + 2; j + 1 < lines.length; j += 2) {
      final c = lines[j].trim();
      if (c == '0') break;
      if (c == '8') {
        if (lines[j + 1].trim() == layer) count++;
        break;
      }
    }
  }
  return count;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('R2000：AC1015 / 370 / 420 / LWPOLYLINE / HATCH / 底图新图层', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_r2000');
    PathProviderPlatform.instance = FakePathProvider(dir.path);

    final r = await DxfExporter.export(
      name: 'R2000测试',
      labels: buildFixtureLabels(),
      includeSurroundings: true,
      basemap: buildSyntheticBasemap(),
      version: DxfVersion.r2000,
      buildingFill: true, // 显式开启：继续覆盖 HATCH 填充路径
    );
    final bytes = r.file.readAsBytesSync();
    final text = latin1.decode(bytes);

    // 版本头
    expect(text, contains('AC1015'));
    // 图层线宽 / 真彩（组码独占一行）
    expect(text, contains('\n370\n'), reason: 'R2000 图层应写 370 线宽');
    expect(text, contains('\n420\n'), reason: 'R2000 图层应写 420 真彩');
    // R2000 多段线形态
    expect(text, contains('LWPOLYLINE'));
    // 建筑填充 = HATCH
    expect(text, contains('HATCH'));
    // 新图层全部存在（底图 + 填充 + 地名）
    for (final layer in [
      'DaoLuBian',
      'DaoLuZhong',
      'JianZhu',
      'JianZhuFill',
      'DiMing',
    ]) {
      expect(text, contains(layer), reason: '缺少图层 $layer');
    }
    // 道路双线描边成对：5 条路 × 2 条描边 = 10 条 DaoLuBian LWPOLYLINE（≥2×路数）
    expect(_lwPolyCount(text, 'DaoLuBian'), greaterThanOrEqualTo(10));
    // 中心线已按新规格删除：颜色分级由图层表 420 表达（≥3 个不同真彩）
    final gradeColors = <int>{};
    for (final c in RegExp(r'420\n(\d+)\n').allMatches(text)) {
      gradeColors.add(int.parse(c.group(1)!));
    }
    expect(gradeColors.length, greaterThanOrEqualTo(3),
        reason: '道路中心线应至少 3 个等级真彩');

    // GBK 中文完整、无乱码；'李' = 0xC0 0xEE
    final decoded = gbk_bytes.decode(bytes);
    expect(decoded, contains('李庄村'));
    expect(decoded, contains('和谐花园'));
    expect(decoded, contains('主干道'));
    expect(decoded, contains('李庄1号楼'));
    expect(decoded.contains('\uFFFD'), isFalse,
        reason: 'GBK 解码出现替换符，存在乱码');
    expect(bytes, containsAllInOrder([0xC0, 0xEE]));

    // 报告为 ok（合成数据）→ 无失败指引
    expect(r.report, isNotNull);
    expect(r.report!.anyFailed, isFalse);

    // ★ R2000 必须结构合法（不再是「R12 结构贴 AC1015 标签」的非法文件）：
    //   实体句柄(5) + 100 子类标记 + $HANDSEED + OBJECTS 段，且通过严格结构自洽校验。
    expect(text, contains('\n5\n'), reason: 'R2000 实体必须有句柄');
    expect(text, contains('\n100\nAcDbEntity\n'), reason: 'R2000 实体须有子类标记');
    expect(text, contains(r'$HANDSEED'), reason: 'R2000 须有 \$HANDSEED');
    expect(text, contains('OBJECTS'), reason: 'R2000 须有 OBJECTS 段');
    final decoded20 = gbk_bytes.decode(bytes);
    final p20 = DxfStructureValidator.validate(decoded20, version: DxfVersion.r2000);
    expect(p20, isEmpty, reason: 'R2000 结构自洽校验失败：$p20');

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('R12：无 370/420/LWPOLYLINE/HATCH，建筑填充回退 SOLID', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_r12');
    PathProviderPlatform.instance = FakePathProvider(dir.path);

    final r = await DxfExporter.export(
      name: 'R12测试',
      labels: buildFixtureLabels(),
      includeSurroundings: true,
      basemap: buildSyntheticBasemap(),
      version: DxfVersion.r12,
      buildingFill: true, // 显式开启：继续覆盖 SOLID 三角填充路径
    );
    final bytes = r.file.readAsBytesSync();
    final text = latin1.decode(bytes);

    expect(text, contains('AC1009'));
    // 红线：R12 严禁出现 R2000 专有组码/形态（老读取器会拒）
    expect(text, isNot(contains('\n370\n')), reason: 'R12 不得写 370');
    expect(text, isNot(contains('\n420\n')), reason: 'R12 不得写 420');
    expect(text, isNot(contains('LWPOLYLINE')), reason: 'R12 不得写 LWPOLYLINE');
    expect(text, isNot(contains('HATCH')), reason: 'R12 不得写 HATCH');
    // R12 建筑填充回退 SOLID 三角近似
    expect(text, contains('0\nSOLID\n'));
    // 底图图层仍存在
    for (final layer in ['JianZhuFill', 'DaoLuBian', 'DaoLuZhong', 'DiMing']) {
      expect(text, contains(layer), reason: '缺少图层 $layer');
    }
    // GBK 中文完整
    final decoded = gbk_bytes.decode(bytes);
    expect(decoded.contains('\uFFFD'), isFalse);

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('默认版本为 R12（最广兼容；旧调用点不传 version 也专业出图）', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_default_ver');
    PathProviderPlatform.instance = FakePathProvider(dir.path);

    final r = await DxfExporter.export(
      name: '默认版本',
      labels: buildFixtureLabels(),
      includeSurroundings: true,
      basemap: buildSyntheticBasemap(),
    );
    final bytes = r.file.readAsBytesSync();
    final text = latin1.decode(bytes);
    // 默认 = R12（AC1009）：已用 ezdxf 严格打开验证；不得含 R2000 专有物
    expect(text, contains('AC1009'));
    expect(text, isNot(contains('LWPOLYLINE')));
    expect(text, isNot(contains('\n370\n')));
    expect(text, isNot(contains('\n420\n')));
    // 默认导出亦须结构合法（防复发闸门）
    final pd = DxfStructureValidator.validate(gbk_bytes.decode(bytes),
        version: DxfVersion.r12);
    expect(pd, isEmpty, reason: 'R12 结构自洽校验失败：$pd');
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
