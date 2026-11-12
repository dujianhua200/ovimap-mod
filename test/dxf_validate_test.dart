// DXF 结构校验器（防复发闸门）回归：真实导出必须通过；人为破坏的结构必须被抓出。
//
// ★ 教训固化：字符串 matching（如「含 AC1015/370/420」）**不足以证明文件合法**。
//   必须做「结构自洽」（本文件）+「真实解析器严格打开」（tool/validate_dxf.py 用 ezdxf）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_validate.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '_dxf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('真实导出（R12 / R2000 + 合成底图）必须通过严格结构校验', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_val_ok');
    PathProviderPlatform.instance = FakePathProvider(dir.path);

    for (final v in DxfVersion.values) {
      final r = await DxfExporter.export(
        name: 'val_${v.name}',
        labels: buildFixtureLabels(),
        includeSurroundings: true,
        basemap: buildSyntheticBasemap(),
        version: v,
        straightenedWiring: true,
      );
      final text = gbk_bytes.decode(r.file.readAsBytesSync());
      final problems = DxfStructureValidator.validate(text, version: v);
      expect(problems, isEmpty, reason: '${v.name} 结构校验未通过：$problems');
      expect(DxfStructureValidator.isValid(text, version: v), isTrue);
    }
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('负例：组码/值不成对被抓出', () {
    const bad = '0\nSECTION\n2\nHEADER\n9\n'; // 有效 token 数为奇数
    final p = DxfStructureValidator.validate(bad, version: DxfVersion.r12);
    expect(p.any((s) => s.contains('不成对')), isTrue, reason: '$p');
  });

  test('负例：未闭合的 POLYLINE（缺 SEQEND）被抓出', () {
    const bad = '0\nSECTION\n2\nENTITIES\n'
        '0\nPOLYLINE\n8\nL\n66\n1\n70\n0\n'
        '0\nVERTEX\n8\nL\n10\n0\n20\n0\n30\n0\n'
        '0\nENDSEC\n0\nEOF\n';
    final p = DxfStructureValidator.validate(bad, version: DxfVersion.r12);
    expect(p.any((s) => s.contains('未闭合的 POLYLINE')), isTrue, reason: '$p');
  });

  test('负例：LWPOLYLINE 顶点数(90)与实际不一致被抓出', () {
    const bad = '0\nSECTION\n2\nENTITIES\n'
        '0\nLWPOLYLINE\n5\n20\n100\nAcDbEntity\n8\nL\n100\nAcDbPolyline\n'
        '90\n5\n70\n0\n10\n0\n20\n0\n10\n1\n20\n1\n' // 声称 5 点，实际 2 点
        '0\nENDSEC\n0\nEOF\n';
    final p = DxfStructureValidator.validate(bad, version: DxfVersion.r2000);
    expect(p.any((s) => s.contains('顶点数不自洽')), isTrue, reason: '$p');
  });

  test('负例：R2000 缺 \$HANDSEED 被抓出', () {
    const bad = '0\nSECTION\n2\nHEADER\n9\n\$ACADVER\n1\nAC1015\n0\nENDSEC\n'
        '0\nSECTION\n2\nTABLES\n0\nENDSEC\n'
        '0\nSECTION\n2\nBLOCKS\n0\nENDSEC\n'
        '0\nSECTION\n2\nENTITIES\n0\nENDSEC\n'
        '0\nSECTION\n2\nOBJECTS\n0\nENDSEC\n0\nEOF\n';
    final p = DxfStructureValidator.validate(bad, version: DxfVersion.r2000);
    expect(p.any((s) => s.contains(r'$HANDSEED')), isTrue, reason: '$p');
  });

  test('负例：R2000 缺 OBJECTS 段被抓出', () {
    const bad = '0\nSECTION\n2\nHEADER\n9\n\$ACADVER\n1\nAC1015\n'
        '9\n\$HANDSEED\n5\nFF\n0\nENDSEC\n'
        '0\nSECTION\n2\nTABLES\n0\nENDSEC\n'
        '0\nSECTION\n2\nBLOCKS\n0\nENDSEC\n'
        '0\nSECTION\n2\nENTITIES\n0\nENDSEC\n0\nEOF\n';
    final p = DxfStructureValidator.validate(bad, version: DxfVersion.r2000);
    expect(p.any((s) => s.contains('OBJECTS')), isTrue, reason: '$p');
  });

  test('负例：R2000 重复句柄被抓出', () {
    const bad = '0\nSECTION\n2\nHEADER\n9\n\$ACADVER\n1\nAC1015\n'
        '9\n\$HANDSEED\n5\nFF\n0\nENDSEC\n'
        '0\nSECTION\n2\nTABLES\n0\nENDSEC\n'
        '0\nSECTION\n2\nBLOCKS\n0\nENDSEC\n'
        '0\nSECTION\n2\nENTITIES\n'
        '0\nLINE\n5\n20\n100\nAcDbEntity\n8\nL\n100\nAcDbLine\n'
        '10\n0\n20\n0\n30\n0\n11\n1\n21\n1\n31\n0\n'
        '0\nLINE\n5\n20\n100\nAcDbEntity\n8\nL\n100\nAcDbLine\n'
        '10\n0\n20\n0\n30\n0\n11\n1\n21\n1\n31\n0\n' // 句柄重复 20
        '0\nENDSEC\n0\nSECTION\n2\nOBJECTS\n0\nENDSEC\n0\nEOF\n';
    final p = DxfStructureValidator.validate(bad, version: DxfVersion.r2000);
    expect(p.any((s) => s.contains('重复句柄')), isTrue, reason: '$p');
  });

  test('负例：R12 出现 R2000 专有组码 370/420 被抓出', () {
    const bad = '0\nSECTION\n2\nHEADER\n9\n\$ACADVER\n1\nAC1009\n0\nENDSEC\n'
        '0\nSECTION\n2\nTABLES\n'
        '0\nTABLE\n2\nLAYER\n70\n1\n0\nLAYER\n2\nGanLu\n70\n0\n62\n3\n6\nCONTINUOUS\n370\n35\n0\nENDTAB\n'
        '0\nENDSEC\n'
        '0\nSECTION\n2\nBLOCKS\n0\nENDSEC\n'
        '0\nSECTION\n2\nENTITIES\n0\nENDSEC\n0\nEOF\n';
    final p = DxfStructureValidator.validate(bad, version: DxfVersion.r12);
    expect(p.any((s) => s.contains('370')), isTrue, reason: '$p');
  });
}
