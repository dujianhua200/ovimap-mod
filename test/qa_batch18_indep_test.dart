import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/search.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';

/// QA 独立对抗验证（第十八批 R1-R4），与工程师 batch18_test.dart 互为对拍。
/// 原则：距离用本文件独立实现的 haversine 对拍；R2/R4 用磁盘级断言。
void main() {
  // ---------- 独立 haversine（不调用工程的 SearchService/GeoUtil） ----------
  double refHaversineM(double la1, double lo1, double la2, double lo2) {
    const r = 6371008.8; // IUGG 平均半径（工程用 6371000，对拍留 0.5% 容差）
    double rad(double d) => d * math.pi / 180;
    final dLa = rad(la2 - la1);
    final dLo = rad(lo2 - lo1);
    final h = math.pow(math.sin(dLa / 2), 2) +
        math.cos(rad(la1)) *
            math.cos(rad(la2)) *
            math.pow(math.sin(dLo / 2), 2);
    return r * 2 * math.asin(math.sqrt(h));
  }

  group('E/R3 独立对拍：sortByDistance 与 haversine', () {
    test('自造乱序 [3km, 200m, 800m] → 升序，且距离与独立实现对拍（<0.5%）', () {
      const baseLa = 34.80, baseLo = 114.35;
      // 沿纬线向东偏移造点：米 → 经度差
      double lonOffsetForM(double m) =>
          m / (111320.0 * math.cos(baseLa * math.pi / 180));
      final p3km = SearchResult(
          name: 'p3km', address: '', lat: baseLa, lon: baseLo + lonOffsetForM(3000));
      final p200 = SearchResult(
          name: 'p200', address: '', lat: baseLa, lon: baseLo + lonOffsetForM(200));
      final p800 = SearchResult(
          name: 'p800', address: '', lat: baseLa, lon: baseLo + lonOffsetForM(800));

      final out = SearchService.sortByDistance([p3km, p200, p800],
          nearLat: baseLa, nearLon: baseLo);
      expect(out.map((e) => e.name).toList(), ['p200', 'p800', 'p3km']);

      // 工程实现 vs 独立实现，相对误差 < 0.5%
      for (final p in [p200, p800, p3km]) {
        final got = SearchService.haversineM(baseLa, baseLo, p.lat, p.lon);
        final ref = refHaversineM(baseLa, baseLo, p.lat, p.lon);
        expect((got - ref).abs() / ref, lessThan(0.005),
            reason: '工程 haversine($got) 与独立实现($ref) 偏差过大');
      }
      // 造点准确性：p200 距基准 ≈200m（±10m）
      expect(
          (SearchService.haversineM(baseLa, baseLo, p200.lat, p200.lon) - 200)
              .abs(),
          lessThan(10));
    });

    test('已知距离锚点：纬度差 1° ≈ 111.19km（±200m）', () {
      final d = SearchService.haversineM(34.0, 114.0, 35.0, 114.0);
      expect((d - 111194.9).abs(), lessThan(200));
    });

    test('无基准点 / 单参 / 空列表 / 单元素：不崩、原序、不改输入', () {
      const a = SearchResult(name: 'a', address: '', lat: 10, lon: 10);
      const b = SearchResult(name: 'b', address: '', lat: 20, lon: 20);
      final input = [b, a];

      expect(SearchService.sortByDistance(input).map((e) => e.name).toList(),
          ['b', 'a']);
      expect(
          SearchService.sortByDistance(input, nearLat: 15)
              .map((e) => e.name)
              .toList(),
          ['b', 'a']);
      expect(
          SearchService.sortByDistance(input, nearLon: 15)
              .map((e) => e.name)
              .toList(),
          ['b', 'a']);
      // 输入未被原地排序
      expect(input.map((e) => e.name).toList(), ['b', 'a']);
      expect(SearchService.sortByDistance(const [], nearLat: 1, nearLon: 1),
          isEmpty);
      expect(SearchService.sortByDistance([a], nearLat: 1, nearLon: 1).length,
          1);
    });
  });

  group('D/R2 独立对抗：持久化格式与三态', () {
    late Directory tmp;
    late AppState st;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('qa_r2');
      LabelStore.instance.setBaseDirForTest(tmp);
      SharedPreferences.setMockInitialValues({});
      st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<String> save1(String name) async {
      st.projectName = name;
      st.labels = [
        MapLabel(typeId: 'pipe', seq: 1, lat: 34.80, lon: 114.35),
      ];
      return st.finishCollection();
    }

    test('visibleCids 持久化格式：单元素/多元素写入与重启恢复一致', () async {
      final c1 = await save1('A');
      final c2 = await save1('B');
      // 多元素：逗号分隔、无空项、无重复
      final raw2 = st.prefs.getString(AppState.prefVisible)!;
      expect(raw2.contains(','), isTrue);
      expect(raw2.split(',').where((s) => s.trim().isEmpty), isEmpty);
      expect(raw2.split(',').toSet().length, raw2.split(',').length,
          reason: '不应有重复 cid');

      // 隐藏一个：集合与持久化同步
      st.toggleVisible(c1);
      expect(st.prefs.getString(AppState.prefVisible)!, c2);

      // 模拟重启：含该值的 mock prefs → init 恢复一致
      SharedPreferences.setMockInitialValues({
        AppState.prefVisible: st.prefs.getString(AppState.prefVisible)!,
      });
      final st2 = AppState();
      st2.setPrefsForTest(await SharedPreferences.getInstance());
      await st2.init();
      expect(st2.visibleCids, {c2});
      expect(st2.overlayLabels.containsKey(c2), isTrue,
          reason: '重启后可见收藏的 overlayLabels 应已加载');
    });

    test('三态：新建保存→显示；隐藏后编辑保存→保持隐藏；已显示编辑保存→刷新保持', () async {
      // ① 新建保存
      final cid = await save1('T');
      expect(st.visibleCids.contains(cid), isTrue);
      expect(st.overlayLabels[cid]!.length, 1);

      // ② 隐藏 → 编辑保存 → 保持隐藏，但文件已更新
      st.toggleVisible(cid);
      final meta =
          (await st.store.loadIndex()).firstWhere((m) => m.id == cid);
      await st.openCollection(meta);
      st.labels.add(MapLabel(typeId: 'pipe', seq: 2, lat: 34.802, lon: 114.352));
      await st.finishCollection();
      expect(st.visibleCids.contains(cid), isFalse);
      expect(st.overlayLabels.containsKey(cid), isFalse);
      expect((await st.store.loadCollection(cid)).length, 2);

      // ③ 已显示 → 编辑保存 → 保持显示且数据刷新
      st.toggleVisible(cid); // 重新显示
      final meta2 =
          (await st.store.loadIndex()).firstWhere((m) => m.id == cid);
      await st.openCollection(meta2);
      st.labels.add(MapLabel(typeId: 'pipe', seq: 3, lat: 34.803, lon: 114.353));
      await st.finishCollection();
      expect(st.visibleCids.contains(cid), isTrue);
      expect(st.overlayLabels[cid]!.length, 3);
    });
  });

  group('F/R4 独立对抗：加入收藏不污染草稿（磁盘级）', () {
    late Directory tmp;
    late AppState st;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('qa_r4');
      LabelStore.instance.setBaseDirForTest(tmp);
      SharedPreferences.setMockInitialValues({});
      st = AppState();
      st.setPrefsForTest(await SharedPreferences.getInstance());
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('加入收藏后：草稿磁盘内容不变 + 内存 labels 对象不变 + 撤销栈不受影响', () async {
      // 先把草稿真实落盘（模拟用户正在编辑）
      st.projectName = '草稿工程';
      st.labels = [
        MapLabel(typeId: 'pipe', seq: 1, lat: 34.80, lon: 114.35, name: 'GK-1'),
        MapLabel(typeId: 'pipe', seq: 2, lat: 34.801, lon: 114.351, name: 'GK-2'),
      ];
      await st.store.saveDraft(st.labels, st.projectName, '', 'design');
      final draftMeta1 = await st.store.loadDraftMeta();
      final draftBefore = await st.store.loadDraft();
      expect(draftBefore.length, 2);

      final undoBefore = st.canUndoSnapshot;
      final sameObj1 = st.labels.first;

      final cid = await st.savePointAsCollection('搜索点甲', 34.8100, 114.3600,
          note: '示例路 1 号');

      // 内存草稿：同一对象实例、长度不变（撤销栈红线：无快照进出）
      expect(identical(st.labels.first, sameObj1), isTrue);
      expect(st.labels.length, 2);
      expect(st.canUndoSnapshot, undoBefore);

      // 磁盘草稿：内容一致
      final draftAfter = await st.store.loadDraft();
      expect(draftAfter.length, 2);
      expect(draftMeta1.projectName,
          (await st.store.loadDraftMeta()).projectName);
      expect(draftAfter.map((e) => e.id).toList(),
          draftBefore.map((e) => e.id).toList());

      // 收藏文件可读、typeId/坐标正确、索引可查、自动显示
      final saved = await st.store.loadCollection(cid);
      expect(saved.length, 1);
      expect(saved.first.typeId, 'pipe');
      expect(saved.first.lat, 34.8100);
      expect(saved.first.lon, 114.3600);
      expect(saved.first.note, '示例路 1 号');
      expect((await st.store.loadIndex()).any((m) => m.id == cid), isTrue);
      expect(st.visibleCids.contains(cid), isTrue);
      expect(st.overlayLabels[cid], isNotEmpty);
    });

    test('重名 (2)(3) 与空名兜底（QA 独立复算）', () async {
      final c1 = await st.savePointAsCollection('同一名字', 34.81, 114.36);
      final c2 = await st.savePointAsCollection('同一名字', 34.82, 114.37);
      final c3 = await st.savePointAsCollection('同一名字', 34.83, 114.38);
      expect(c1, isNot(c2));
      expect(c2, isNot(c3));
      expect((await st.store.loadCollection(c2)).first.name, '同一名字(2)');
      expect((await st.store.loadCollection(c3)).first.name, '同一名字(3)');

      final e1 = await st.savePointAsCollection('   ', 34.84, 114.39);
      final e2 = await st.savePointAsCollection('', 34.85, 114.40);
      expect((await st.store.loadCollection(e1)).first.name, '收藏点');
      expect((await st.store.loadCollection(e2)).first.name, '收藏点(2)');
    });

    test('临时标记不进业务数据（源路径审计）：_searchMark 仅页面态', () async {
      final src = await File('lib/ui/home_page.dart').readAsString();
      expect(src.contains('SearchResult? _searchMark'), isTrue);
      // 不存在把 _searchMark 塞进 labels/草稿的路径
      expect(RegExp(r'_searchMark[^;]*labels').hasMatch(src), isFalse);
      // home_page 不直接操作撤销栈
      expect(src.contains('pushUndoSnapshot'), isFalse);
      // 临时标记是独立 MarkerLayer 分支，不在 _buildMarkers 业务符号里
      final bm = src.indexOf('MarkerLayer(markers: _buildMarkers');
      final sm = src.indexOf('if (_searchMark != null)');
      expect(bm, greaterThan(-1));
      expect(sm, greaterThan(bm), reason: '临时标记应是独立 MarkerLayer 分支');
    });
  });

  group('C/R1 独立源级审计（UI 内联逻辑，源级+导出链路断言）', () {
    test('恢复路径无强制回落；导出链路 rangeM 直通 DxfExporter', () async {
      final dlg = await File('lib/ui/dialogs.dart').readAsString();
      // 恢复：?? 880 兜底，其后无 "不在档位→880" 回落
      expect(dlg.contains("prefs.getDouble('dxfRangeM') ?? 50"), isTrue);
      expect(dlg.contains('contains(rangeM)) rangeM = 880'), isFalse);
      // 新预设档位在 UI
      expect(dlg.contains('[30, 50, 100, 200, 300, 500, 880]'), isTrue);
      // 自定义输入校验 20~5000 + 确认即持久化
      expect(dlg.contains('v < 20 || v > 5000'), isTrue);
      expect(dlg.contains("prefs.setDouble('dxfRangeM', v)"), isTrue);

      // 导出链路：dialogs 传 rangeM: rangeM；DxfExporter 用它算底图 bbox
      expect(dlg.contains('rangeM: rangeM'), isTrue);
      final dxf = await File('lib/export/dxf.dart').readAsString();
      expect(dxf.contains('double rangeM = 50'), isTrue);
      expect(dxf.contains('boundsOf(labels, rangeM)'), isTrue,
          reason: 'rangeM 必须实际参与底图范围计算（链路无断裂）');
    });

    test('【观察项】越界历史值（如 5/30000）恢复时不回落——记录现状（非阻断）', () async {
      // 现状：恢复不做 20~5000 夹紧，越界值以「自定义(x)m」显示并直接用于导出。
      // 旧版本值域只有 {300,500,880,1000}（均合法），越界值只可能来自
      // 手工改 prefs / 数据损坏，低概率脏数据。记录现状，防无意改动无感知。
      final dlg = await File('lib/ui/dialogs.dart').readAsString();
      expect(dlg.contains('?? 50'), isTrue);
      expect(dlg.contains('clamp(20'), isFalse);
    });
  });
}
