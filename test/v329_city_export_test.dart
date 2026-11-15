// 最终验收：信阳市区导出有建筑、速度快。
import 'dart:convert' show latin1;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/bundled_basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/export/frame_template.dart';
import 'package:ovimap/models/label_type.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/symbols/symbol_catalog.dart';

void main() {
  late Directory tmp;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = Directory.systemTemp.createTempSync('ov_final');
    LabelStore.instance.setBaseDirForTest(tmp);
    AppPaths.setBaseForTest(tmp);
    LabelType.installCatalog(SymbolCatalog.fromTextSync(
        File('assets/dxf/lispblock.dxf').readAsStringSync()));
    BundledBasemap.setTestBypass(true);
  });

  tearDown(() => AppPaths.clearForTest());

  test('信阳市区导出：有建筑且不慢', () async {
    // 市区一条 30 点线路
    final labels = <MapLabel>[
      for (var i = 0; i < 30; i++)
        MapLabel(
          typeId: 'gl003', seq: i + 1,
          lat: 32.140 + i * 0.0009,
          lon: 114.085 + i * 0.0006,
          lineGroupId: 'g', name: 'P${i + 1}', distanceM: 100,
        ),
    ];
    final frame = parseDxfFrame(
        latin1.decode(File('assets/frames/frame_a3.dxf').readAsBytesSync()));

    final st = Stopwatch()..start();
    final r = await DxfExporter.export(
      name: '信阳市区', labels: labels, version: DxfVersion.r12,
      fixedScale: 3000, frame: frame,
      includeSurroundings: true, rangeM: 50,
      clipInjectedBasemap: true,
    );
    final ms = st.elapsedMilliseconds;
    final txt = latin1.decode(r.file.readAsBytesSync());
    final jz = RegExp(r'0\nPOLYLINE\n8\nJianZhu\n').allMatches(txt).length;
    final dl = RegExp(r'0\nPOLYLINE\n8\nDaoLu').allMatches(txt).length;

    // ignore: avoid_print
    print('耗时 ${ms} ms, ${txt.length ~/ 1024} KB');
    // ignore: avoid_print
    print('建筑 $jz 个, 道路 $dl 条, 警告 ${r.warnings.length}');
    for (final w in r.warnings) {
      // ignore: avoid_print
      print('  · $w');
    }

    expect(jz, greaterThan(50), reason: '信阳市区应有大量建筑轮廓');
    expect(dl, greaterThan(5), reason: '应有道路');
    expect(r.warnings.where((w) => w.contains('无建筑')), isEmpty,
        reason: '不应再报"无建筑轮廓"');
    expect(ms, lessThan(8000), reason: '导出应快');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
