// ExportSaver 单测（零网络 / 零插件）：
// - 纯函数（默认文件名 / 扩展名补齐 / 取扩展名）可直接验证；
// - 交付入口在「文件不存在」时提前返回 false，不触碰 file_picker / share。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/services/export_saver.dart';

void main() {
  group('resolveSuggestedName（纯函数）', () {
    test('未提供建议名 → 用文件本身的文件名', () {
      final f = File('/tmp/ovimap/a/b/导出.kml');
      expect(ExportSaver.resolveSuggestedName(f, null), '导出.kml');
    });

    test('空 / 全空白建议名 → 回退文件名', () {
      final f = File('/tmp/ovimap/a/b/导出.kml');
      expect(ExportSaver.resolveSuggestedName(f, ''), '导出.kml');
      expect(ExportSaver.resolveSuggestedName(f, '   '), '导出.kml');
    });

    test('建议名 trim 后使用', () {
      final f = File('/tmp/ovimap/a/b/导出.kml');
      expect(ExportSaver.resolveSuggestedName(f, '  设计成果.dxf '), '设计成果.dxf');
    });
  });

  group('ensureExtension（纯函数）', () {
    test('缺扩展名则补齐', () {
      expect(ExportSaver.ensureExtension('/tmp/out', 'dxf'), '/tmp/out.dxf');
    });

    test('已有同扩展名（大小写不敏感）不重复补', () {
      expect(ExportSaver.ensureExtension('/tmp/out.dxf', 'dxf'), '/tmp/out.dxf');
      expect(ExportSaver.ensureExtension('/tmp/out.DXF', 'dxf'), '/tmp/out.DXF');
    });

    test('扩展名为空 → 原样返回', () {
      expect(ExportSaver.ensureExtension('/tmp/out', ''), '/tmp/out');
    });
  });

  group('extensionOf（纯函数）', () {
    test('正常扩展名', () {
      expect(ExportSaver.extensionOf('a.kml'), 'kml');
      expect(ExportSaver.extensionOf('a.b.csv'), 'csv');
    });

    test('无扩展名 / 隐藏文件 / 结尾点 → 空串', () {
      expect(ExportSaver.extensionOf('noext'), '');
      expect(ExportSaver.extensionOf('.hidden'), '');
      expect(ExportSaver.extensionOf('trailing.'), '');
    });
  });

  testWidgets('文件不存在：saveOrShare 提前返回 false，不触发任何插件调用',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold();
      }),
    ));

    final missing = File(
        '${Directory.systemTemp.path}/__ovimap_not_exist_${DateTime.now().microsecondsSinceEpoch}.kml');
    if (missing.existsSync()) missing.deleteSync();

    final ok = await ExportSaver.saveOrShare(ctx, missing);
    expect(ok, isFalse);
  });
}
