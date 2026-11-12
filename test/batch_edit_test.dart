import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/csv.dart';
import 'package:ovimap/models/diff_report.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/state/app_state.dart';
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

  test('applyBatch：批量改后材料统计联动 + 一次撤销还原', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap_batch');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final st = AppState();
    const g = 'g1';
    st.labels.addAll([
      MapLabel(
          typeId: 'pipe',
          seq: 1,
          lat: 32.0,
          lon: 114.0,
          lineGroupId: g,
          name: 'GK-1'),
      MapLabel(
          typeId: 'pipe',
          seq: 2,
          lat: 32.0,
          lon: 114.001,
          lineGroupId: g,
          name: 'GK-2',
          distLabel: '100'),
    ]);

    st.selectChain(g);
    expect(st.selectedIds.length, 2, reason: '选整条线组应含 2 点');

    final n = st.applyBatch(const BatchEdit(
      segKind: 1,
      segCable: '48芯GYTS',
      slackM: 5,
      namePrefix: 'GL',
    ));
    expect(n, 2);
    expect(st.labels[1].segKind, 1);
    expect(st.labels[1].segCable, '48芯GYTS');
    expect(st.labels[1].slackM, 5);
    expect(st.labels[1].name, 'GL-2', reason: '仅换前缀保留原编号');

    // 材料统计随之重算（复用既有公式）：出现架空段与型号
    final f = await CsvExporter.exportMaterialStats('批量测试', st.labels);
    final text = f.readAsStringSync();
    expect(text.contains('架空'), isTrue);
    expect(text.contains('100.0'), isTrue);
    expect(text.contains('48芯GYTS'), isTrue);

    // 一次撤销：整批还原
    st.undoDraft();
    expect(st.labels.length, 2);
    expect(st.labels[1].segKind, 0);
    expect(st.labels[1].segCable, '');
    expect(st.labels[1].slackM, 0);
    expect(st.labels[1].name, 'GK-2');

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('applyBatch：未选点返回 0，不改动', () {
    final st = AppState();
    st.labels.add(
        MapLabel(typeId: 'pipe', lat: 32.0, lon: 114.0, lineGroupId: 'g'));
    expect(st.applyBatch(const BatchEdit(segKind: 1)), 0);
    expect(st.labels.first.segKind, 0);
  });
}
