import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/archive_book.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String root;
  _FakePathProvider(this.root);
  @override
  Future<String?> getExternalStoragePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('成册：无照片时正常出海 zip，缺项记入 skipped 不抛错', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_book');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    const g = 'g1';
    final labels = [
      MapLabel(
          typeId: 'pipe',
          seq: 1,
          lat: 32.0,
          lon: 114.0,
          lineGroupId: g,
          name: 'GK-1',
          distLabel: '50'),
      MapLabel(
          typeId: 'pipe',
          seq: 2,
          lat: 32.0,
          lon: 114.001,
          lineGroupId: g,
          name: 'GK-2',
          distLabel: '50'),
      MapLabel(typeId: 'crossbox', seq: 3, lat: 32.0, lon: 114.001, name: '光交'),
    ];

    final r = await ArchiveBookExporter.export(name: '成册测试', labels: labels);

    expect(r.zip.existsSync(), isTrue);
    expect(r.zip.lengthSync(), greaterThan(0));
    expect(r.included.contains('路由图.dxf'), isTrue);
    expect(r.included.contains('工程量清单.csv'), isTrue);
    expect(r.included.contains('材料统计.csv'), isTrue);
    // 无挂接照片 → 照片册被跳过（不抛错）
    expect(r.included.contains('照片册.zip'), isFalse);
    expect(r.skipped.any((s) => s.contains('照片册')), isTrue);

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('成册：空工程不抛错（各子项按缺项跳过）', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_book_empty');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final r = await ArchiveBookExporter.export(name: '空工程', labels: const []);
    // 仍应出海 zip（含成册说明），DXF 因杆路为空被跳过
    expect(r.zip.existsSync(), isTrue);
    expect(r.skipped.any((s) => s.contains('路由图')), isTrue);
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
