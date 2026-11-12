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
  test('链提取：箱体插两杆之间不打断杆路（与地图连线口径一致）', () {
    final p1 = MapLabel(
        typeId: 'pipe', lat: 32.0, lon: 114.0, lineGroupId: 'g1');
    final box = MapLabel(
        typeId: 'fiberbox', lat: 32.0005, lon: 114.0005, name: '分纤盒');
    final p2 = MapLabel(
        typeId: 'concrete', lat: 32.001, lon: 114.001, lineGroupId: 'g1');
    final chains = buildLabelChains([p1, box, p2]);
    expect(chains.length, 1, reason: '箱体不应把杆路剪断');
    expect(chains.first.length, 2, reason: 'p1 与 p2 直接相连');
  });

  test('多链交错：各自成链，互不串线', () {
    final a1 = MapLabel(
        typeId: 'pipe', lat: 32.0, lon: 114.0, lineGroupId: 'gA');
    final b1 = MapLabel(
        typeId: 'concrete', lat: 32.1, lon: 114.1, lineGroupId: 'gB');
    final a2 = MapLabel(
        typeId: 'pipe', lat: 32.001, lon: 114.001, lineGroupId: 'gA');
    final b2 = MapLabel(
        typeId: 'concrete', lat: 32.101, lon: 114.101, lineGroupId: 'gB');
    final chains = buildLabelChains([a1, b1, a2, b2]);
    expect(chains.length, 2);
    expect(identical(chains[0][0], a1) && identical(chains[0][1], a2), isTrue);
    expect(identical(chains[1][0], b1) && identical(chains[1][1], b2), isTrue);
  });

  test('previousChainLabel：跳过箱体/文字取同组上一杆（竣工段距基准）', () {
    final st = AppState();
    final p1 = MapLabel(
        typeId: 'pipe',
        lat: 32.0,
        lon: 114.0,
        lineGroupId: 'g1',
        name: 'GK-1');
    final box = MapLabel(
        typeId: 'fiberbox', lat: 32.0005, lon: 114.0005, name: '分纤盒');
    final txt = MapLabel(
        typeId: 'text', lat: 32.0007, lon: 114.0007, name: '备注');
    final p2 = MapLabel(
        typeId: 'pipe', lat: 32.001, lon: 114.001, lineGroupId: 'g1');
    st.labels.addAll([p1, box, txt, p2]);
    expect(identical(st.previousChainLabel(p2), p1), isTrue,
        reason: 'p2 的上一杆是 p1，而不是中间的箱体/文字');
    expect(st.previousChainLabel(p1), isNull, reason: '链起点没有上一杆');
  });

  test('导入近邻去重：同类型 5m 内视为同位置，不再要求坐标逐位相同', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final store = LabelStore.instance;

    final targetCid = await store.finishCollection(
        name: '目标',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: [
          MapLabel(typeId: 'crossbox', lat: 32.0, lon: 114.0, name: '原光交'),
        ]);
    final sourceCid = await store.finishCollection(
        name: '来源',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: [
          MapLabel(
              typeId: 'crossbox',
              lat: 32.00003,
              lon: 114.00003,
              name: '近旁光交'), // 距原光交约 4m，应判为同位置
          MapLabel(
              typeId: 'crossbox',
              lat: 32.001,
              lon: 114.0,
              name: '远处光交'), // 约 110m，应导入
        ]);

    final st = AppState();
    final n = await st.importBoxesToCollection(targetCid, sourceCid);
    expect(n, 1, reason: '近旁光交去重，只导入远处光交');
    final merged = await store.loadCollection(targetCid);
    expect(merged.length, 2);
    // 原光交保留（未覆盖模式不改动原点属性）
    expect(merged.any((l) => l.name == '原光交'), isTrue);
    expect(merged.any((l) => l.name == '远处光交'), isTrue);
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
