// 源级接线断言（零运行、纯静态）：确认「从文件选择」入口确实走 file_picker（SAF），
// 扩展名过滤含 geojson/json，且既有「粘贴/剪贴板」入口仍然保留（两入口并存）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/ui/dialogs.dart').readAsStringSync();

  test('从文件选择入口：确实调用 file_picker 的 SAF 选择器 + 扩展名过滤', () {
    expect(src, contains("import 'package:file_picker/file_picker.dart';"));
    expect(src, contains('FilePicker.platform.pickFiles('));
    expect(src, contains('FileType.custom'));
    expect(src, contains("allowedExtensions: const ['geojson', 'json']"));
    // 大文件只取路径，不做全量内存拷贝
    expect(src, contains('withData: false'));
  });

  test('读取走「文件 → 文本 → 既有落盘路径」，不重写解析/存储', () {
    expect(src, contains('BasemapFileImporter.importFromPath('));
    expect(src, contains('BasemapFileImporter.importFromBytes('));
    // 仍复用既有实现（未另起炉灶）
    expect(src, contains('GeoJsonImporter.parse'));
    expect(src, contains('LocalBasemapStore'));
  });

  test('既有「粘贴/剪贴板」入口仍在（两入口并存，未删除）', () {
    expect(src, contains('读取剪贴板'));
    expect(src, contains('解析并导入'));
    expect(src, contains("Clipboard.getData('text/plain')"));
    expect(src, contains('粘贴 GeoJSON 全文'));
  });

  test('用户取消不报错：picked 为空时静默返回', () {
    expect(src, contains('if (picked == null || picked.files.isEmpty) return;'));
  });

  test('中文错误提示区分：非 GeoJSON / 文件过大 / 导入失败', () {
    expect(src, contains('所选文件不是有效的 GeoJSON'));
    expect(src, contains('BasemapImportException'));
    expect(src, contains('导入失败'));
  });

  test('入口文案与信息展示存在', () {
    expect(src, contains('从文件选择…'));
    expect(src, contains('当前已导入'));
  });
}
