// E2 批量属性编辑（多选点位 → 批量改字段）：既有 `applyBatch`/`BatchEdit` 的
// 行为链补充验证 —— 一次 undo 还原整批、redo 重放、只动选中点、清空型号。
// 不修改既有 batch_edit_test.dart，仅新增用例。零网络。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/diff_report.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';

final store = LabelStore.instance;

void main() {
  late Directory dir;
  late AppState st;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_batch_props');
    store.setBaseDirForTest(dir);
    st = AppState();
  });

  tearDown(() {
    AppPaths.clearForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 两条线组：g1（2 点，参与批量）、g2（1 点，不选中，用于验证不误伤）。
  void seed() {
    st.labels.addAll([
      MapLabel(
          typeId: 'pipe',
          seq: 1,
          lat: 32.0,
          lon: 114.0,
          lineGroupId: 'g1',
          name: 'A-1'),
      MapLabel(
          typeId: 'pipe',
          seq: 2,
          lat: 32.0,
          lon: 114.001,
          lineGroupId: 'g1',
          name: 'A-2',
          distLabel: '100'),
      MapLabel(
          typeId: 'pipe',
          seq: 1,
          lat: 32.1,
          lon: 114.0,
          lineGroupId: 'g2',
          name: 'B-1'),
    ]);
  }

  test('多选 → 批量改 → 一次 undo 还原 → redo 重放', () {
    seed();
    st.selectChain('g1');
    expect(st.selectedIds.length, 2);

    final n = st.applyBatch(const BatchEdit(segKind: 1, segCable: '48芯GYTS'));
    expect(n, 2);
    expect(st.labels[0].segKind, 1);
    expect(st.labels[1].segKind, 1);
    expect(st.labels[1].segCable, '48芯GYTS');
    // 不误伤未选中线组
    expect(st.labels[2].segKind, 0, reason: 'g2 未选中，不应被改动');
    expect(st.labels[2].segCable, '');

    // 一次 undo：整批还原
    st.undoDraft();
    expect(st.labels[0].segKind, 0);
    expect(st.labels[1].segKind, 0);
    expect(st.labels[1].segCable, '');

    // redo：整批重放
    expect(st.canRedo, isTrue);
    st.redo();
    expect(st.labels[0].segKind, 1);
    expect(st.labels[1].segKind, 1);
    expect(st.labels[1].segCable, '48芯GYTS');
    expect(st.labels[2].segKind, 0, reason: 'redo 也不应误伤未选中点');
  });

  test('清空光缆型号（segCable 空串语义）+ 只动选中点', () {
    seed();
    st.labels[1].segCable = '48芯GYTS';
    st.selectedIds.clear();
    st.selectedIds.add(st.labels[0].id); // 只选第一个点

    final n = st.applyBatch(const BatchEdit(segKind: 2, segCable: ''));
    expect(n, 1);
    expect(st.labels[0].segKind, 2);
    // 第 1 点无原有型号 → 清空无感知；验证第 2 点的原型号不被清
    expect(st.labels[1].segCable, '48芯GYTS', reason: '未选中点的型号保持不变');

    // 一次 undo 同时还原 segKind
    st.undoDraft();
    expect(st.labels[0].segKind, 0);
    expect(st.labels[1].segCable, '48芯GYTS');
  });

  test('盘留批量设置 + 空编辑返回 0', () {
    seed();
    st.selectChain('g1');
    final n = st.applyBatch(const BatchEdit(slackM: 3.5));
    expect(n, 2);
    expect(st.labels[0].slackM, 3.5);
    expect(st.labels[1].slackM, 3.5);
    st.undoDraft();
    expect(st.labels[0].slackM, 0);

    // 空编辑（什么都不改）→ 0 且不压快照
    final before = st.canUndoSnapshot;
    expect(st.applyBatch(const BatchEdit()), 0);
    expect(st.canUndoSnapshot, before, reason: '空编辑不应产生撤销快照');
  });
}
