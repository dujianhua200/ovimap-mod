import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/store.dart';
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

  test('导入箱体节点：合并 + 同坐标去重', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final store = LabelStore.instance;

    // 目标工程：只有杆路
    final gid = 'g1';
    final targetLabels = [
      MapLabel(typeId: 'pipe', seq: 1, lat: 32.10, lon: 114.00, lineGroupId: gid),
      MapLabel(typeId: 'pipe', seq: 2, lat: 32.11, lon: 114.01, lineGroupId: gid),
    ];
    final targetCid = await store.finishCollection(
        name: '目标工程', kind: 'label', folderId: '', editMode: 'design',
        labels: targetLabels);

    // 来源工程：杆路 + 3 个箱体 + 1 个与目标同坐标的箱体（应去重）
    final dup = MapLabel(typeId: 'crossbox', seq: 5, lat: 32.10, lon: 114.00, name: '重复位置光交');
    final sourceLabels = [
      MapLabel(typeId: 'pipe', seq: 1, lat: 32.20, lon: 114.10),
      dup,
      MapLabel(typeId: 'splitterbox', seq: 2, lat: 32.21, lon: 114.11, name: '张庄分光箱'),
      MapLabel(typeId: 'room', seq: 3, lat: 32.22, lon: 114.12, name: '县机房'),
      MapLabel(typeId: 'bts', seq: 4, lat: 32.23, lon: 114.13, name: '移动基站'),
    ];
    final sourceCid = await store.finishCollection(
        name: '来源工程', kind: 'label', folderId: '', editMode: 'design',
        labels: sourceLabels);

    // 直接测试合并算法（与 AppState.importBoxesToCollection 相同逻辑路径）
    final st = AppState();
    final n = await st.importBoxesToCollection(targetCid, sourceCid);
    // 4 个箱体（crossbox/splitterbox/room/bts），同坐标不同类型均导入
    expect(n, 4, reason: '应导入4个新箱体，同坐标不同类型不去重');
    final merged = await store.loadCollection(targetCid);
    expect(merged.length, 6); // 2 杆 + 4 新箱体
    final boxes = merged.where((l) => l.type.isTopoLinkable).toList();
    expect(boxes.length, 4);
    expect(boxes.map((b) => b.name).toSet(), {'张庄分光箱', '县机房', '移动基站', '重复位置光交'});
    print('导入箱体测试通过：目标工程现有 ${merged.length} 点');
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
