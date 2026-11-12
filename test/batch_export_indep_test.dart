// T21：批量导出 DXF——多工程 → 各自子目录产物；空工程跳过；同名不互相覆盖。
// 零网络：关掉「周边底图」后，DXF 完全由点位生成（不触 Overpass/瓦片）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/ui/desktop/batch_export.dart';

final store = LabelStore.instance;

List<MapLabel> labelsN(String tag, int n) => [
      for (var i = 0; i < n; i++)
        MapLabel(
            typeId: 'pipe',
            seq: i + 1,
            lat: 32.0 + i * 0.01,
            lon: 114.0 + i * 0.01)
          ..id = '$tag-$i',
    ];

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_batch_export');
    store.setBaseDirForTest(dir);
    // 关掉周边矢量 + 显式关闭本地底图 → DXF 纯由点位生成（零网络、
    // 与 LocalBasemapStore 的磁盘状态完全解耦，消除并行负载下的文件竞争面）。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'dxfSurroundings': false,
      'dxfUseLocal': false,
    });
  });

  tearDown(() {
    AppPaths.clearForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<CollectionMeta> makeLocal(String name, int n) async {
    final cid = await store.finishCollection(
      name: name,
      kind: 'label',
      folderId: '',
      editMode: 'design',
      labels: labelsN(name, n),
    );
    final idx = await store.loadIndex();
    return idx.firstWhere((m) => m.id == cid);
  }

  test('多工程 → 各自子目录产物，DXF 内容健康（GBK + 杆路层）', () async {
    final a = await makeLocal('甲工程', 3);
    final b = await makeLocal('乙工程', 2);
    final root = Directory('${dir.path}/labels/export/批量')
      ..createSync(recursive: true);

    final summary =
        await runBatchExport(store: store, metas: [a, b], root: root);

    expect(summary.failed, isEmpty, reason: 'failed=${summary.failed}');
    expect(summary.ok, 2);
    expect(summary.skipped, isEmpty);
    expect(summary.producedDirs, containsAll(<String>['甲工程', '乙工程']));

    final fa = File('${root.path}/甲工程/甲工程.dxf');
    final fb = File('${root.path}/乙工程/乙工程.dxf');
    expect(fa.existsSync(), isTrue);
    expect(fb.existsSync(), isTrue);
    expect(fa.lengthSync(), greaterThan(0));

    // DXF 为 GBK 编码（非 UTF-8）：按字节取，ASCII 标记原样保留。
    final ascii = String.fromCharCodes(fa.readAsBytesSync());
    expect(ascii.contains('ANSI_936'), isTrue, reason: 'DXF 头声明 GBK 代码页');
    expect(ascii.contains('GanLu'), isTrue, reason: '杆路图层存在');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('空工程被跳过，其余照常导出', () async {
    final a = await makeLocal('甲', 2);
    final empty = await makeLocal('空工程', 0);
    final root = Directory('${dir.path}/labels/export/批量')
      ..createSync(recursive: true);

    final summary =
        await runBatchExport(store: store, metas: [a, empty], root: root);

    expect(summary.ok, 1);
    expect(summary.skipped, contains('空工程'));
    expect(File('${root.path}/甲/甲.dxf').existsSync(), isTrue);
    expect(Directory('${root.path}/空工程').existsSync(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('同名工程 → 追加 -2，互不覆盖', () async {
    final x = await makeLocal('同名', 2);
    final y = await makeLocal('同名', 3);
    expect(x.id == y.id, isFalse);
    final root = Directory('${dir.path}/labels/export/批量')
      ..createSync(recursive: true);

    final summary =
        await runBatchExport(store: store, metas: [x, y], root: root);

    expect(summary.ok, 2);
    expect(summary.producedDirs, containsAll(<String>['同名', '同名-2']));
    expect(File('${root.path}/同名/同名.dxf').existsSync(), isTrue);
    expect(File('${root.path}/同名-2/同名-2.dxf').existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('空目标集合：直接成功 0（UI 层另行提示）', () async {
    final root = Directory('${dir.path}/labels/export/批量')
      ..createSync(recursive: true);
    final summary =
        await runBatchExport(store: store, metas: const [], root: root);
    expect(summary.ok, 0);
    expect(summary.producedDirs, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
