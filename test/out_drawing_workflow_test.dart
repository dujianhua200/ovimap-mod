// 「打点 → 连杆路 → 段标 → 体检 → 出图」端到端工作流护栏。
//
// 这是滑洲云图存在的理由：线路设计人员现场打完点，回来要的是**一张能交付的图**。
// 本轮把这条链上的三个环节统一到了同一份真源（RouteSegment / GeoUtil.segTextFor），
// 因此这里必须有一条测试**跨环节**地验证：屏幕上看到的段标、体检报告里的数字、
// 导出的 DXF 里的文字，是同一套口径——否则"屏上一套、图纸一套"会变成现场返工。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/analysis/route_check.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/models/diff_report.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  late AppState st;
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('ovimap_flow');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
  });

  /// 一步一步按真实操作打 4 个点（一线 4 点，段距 38 / 42.5 / 25）。
  void punchPoints() {
    st.labels.addAll([
      MapLabel(
          typeId: 'pole', seq: 1, lat: 32.0, lon: 114.0, lineGroupId: 'g1',
          name: 'GK-1'),
      MapLabel(
          typeId: 'pole', seq: 2, lat: 32.0004, lon: 114.0, lineGroupId: 'g1',
          name: 'GK-2', distanceM: 38),
      MapLabel(
          typeId: 'pole', seq: 3, lat: 32.0008, lon: 114.0, lineGroupId: 'g1',
          name: 'GK-3', distanceM: 42.5),
      MapLabel(
          typeId: 'pole', seq: 4, lat: 32.0010, lon: 114.0, lineGroupId: 'g1',
          name: 'GK-4', distanceM: 25),
    ]);
  }

  /// 全选 + 批量设敷设方式（真实路径：图上框选一排点 → 批量编辑）。
  int setAllKinds(int kind) {
    st.selectedIds
      ..clear()
      ..addAll(st.labels.map((l) => l.id));
    return st.applyBatch(BatchEdit(segKind: kind));
  }

  Future<String> exportDxf(String name) async {
    final r = await DxfExporter.export(
      name: name,
      labels: st.labels,
      includeSurroundings: false,
      version: DxfVersion.r12,
    );
    return gbk_bytes.decode(r.file.readAsBytesSync());
  }

  test('全链路：打点 → 批量设「埋地」→ 段标实时带前缀 → 体检通过 → DXF 同口径', () async {
    punchPoints();

    // ① 刚打完点：还没填敷设方式，段标只有裸距离。
    expect(st.segments.map((s) => s.text).toList(), ['38', '42.5', '25']);

    // ② 体检先揪出"未填敷设方式"——这正是设计人员出图前该被拦下来的一步。
    final before = RouteChecker.check(st.segments, st.labels);
    expect(before.any((i) => i.code == 'seg_no_kind'), isTrue);

    // ③ 批量设敷设方式（不再逐段填）。段标**实时**变成「埋xx」，无需任何"生成"动作。
    //    返回 4 = 本批影响的**点数**（applyBatch 的既有语义），不是段数；
    //    4 个点里第 1 点没有来向段，所以只有 3 段得到了前缀。
    expect(setAllKinds(2), 4);
    expect(st.segments.map((s) => s.text).toList(), ['埋38', '埋42.5', '埋25']);

    // ④ 复检：敷设方式问题消失，且没有 error 级问题 → 可以出图。
    final after = RouteChecker.check(st.segments, st.labels);
    expect(after.any((i) => i.code == 'seg_no_kind'), isFalse);
    expect(after.where((i) => i.level == IssueLevel.error), isEmpty);

    // ⑤ 出一张图：屏上的段标与图上的段标必须逐字相同（含"整数不留 .0"）。
    final text = await exportDxf('全链路');
    expect(text, contains('埋38'));
    expect(text, contains('埋42.5'));
    expect(text, contains('埋25'));
    expect(text, isNot(contains('埋38.0')));
    expect(text, contains('GK-1'));
    expect(text, contains('GK-4'));
  });

  test('挪动一个点后段标自动跟随：图上不会留下焊死的旧数字', () async {
    punchPoints();
    setAllKinds(2);
    expect(st.segments.first.text, '埋38');

    // 甲方要求把第 2 点往后挪：38 → 55。
    st.labels[1].distanceM = 55;

    // 关键：段标是**推导**出来的，不是打点时写死的字符串。
    expect(st.segments.first.text, '埋55');
    expect(st.labels[1].distLabel, '', reason: '距离永远不该被固化进 distLabel');

    final text = await exportDxf('挪点后');
    expect(text, contains('埋55'));
    expect(text, isNot(contains('埋38')), reason: '旧数字不能残留在图纸上');
  });

  test('手填标注优先于实时推导，且会被体检盯上（防手误）', () async {
    punchPoints();
    setAllKinds(2);

    // 现场复测：这一段手工写成 埋42.5（与几何 38 不符）。
    st.setSegLabel(st.labels[1], '埋42.5');
    expect(st.segments.first.text, '埋42.5');

    final issues = RouteChecker.check(st.segments, st.labels);
    final drift = issues.where((i) => i.code == 'seg_label_drift').toList();
    expect(drift.length, 1);
    expect(drift.first.labelIds,
        containsAll(<String>[st.labels[0].id, st.labels[1].id]));

    // 清掉手填后回到实时推导。
    expect(st.clearSegLabels([st.labels[1]]), 1);
    expect(st.segments.first.text, '埋38');
  });

  test('长杆档（≥1km）：屏幕段标与图纸段标不分叉（曾经一处写 1.05km、一处写 1050）',
      () async {
    // 跨河长杆档：1500 米，埋地。
    st.labels.addAll([
      MapLabel(
          typeId: 'pole', seq: 1, lat: 32.0, lon: 114.0, lineGroupId: 'g1',
          name: 'K-1'),
      MapLabel(
          typeId: 'pole', seq: 2, lat: 32.0135, lon: 114.0, lineGroupId: 'g1',
          name: 'K-2', distanceM: 1500, segKind: 2),
    ]);

    // 屏上（左栏段落表 / 地图段标 / 编辑框自动补距）走的就是这个字符串。
    expect(st.segments.first.text, '埋1500');

    final text = await exportDxf('长杆档');
    expect(text, contains('埋1500'));
    expect(text, isNot(contains('km')), reason: '图纸标注图层单位是米，不能混进 km');
    expect(text, isNot(contains('埋1500.0')));
  });
}
