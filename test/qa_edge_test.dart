// QA 独立对抗测试（严过关）——不复用工程师用例，专门覆盖边界与错误路径。
//
// 覆盖：
//  · route_layout.autoPoles：档距>总长 / 0 / 负数 / NaN / 极小距离 / 纬度突变 / 首末不变式
//  · csv.buildDesignDiff：空集合 / 全一致 / 阈值边界 / 净长度差符号 / 备注分支
//  · app_state.applyBatch：空选择 / 一次撤销还原全字段 / 跨链互不影响 / 仅换前缀保留原数字
//  · archive_book.export：空工程仍出海 ZIP / ZIP 可解码 / 含成册说明.txt
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/archive_book.dart';
import 'package:ovimap/export/csv.dart';
import 'package:ovimap/geo/geo_util.dart';
import 'package:ovimap/geo/route_layout.dart';
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

  // ================= A. route_layout.autoPoles 对抗 =================

  group('QA · route_layout.autoPoles', () {
    test('档距 > 总长：仍含起止两点，且不越界', () {
      const sLat = 32.10, sLon = 114.00, eLat = 32.10, eLon = 114.01;
      final total = RouteLayout.haversineM(sLat, sLon, eLat, eLon);
      final poles = RouteLayout.autoPoles(
          startLat: sLat,
          startLon: sLon,
          endLat: eLat,
          endLon: eLon,
          spacingM: total * 3.0); // 档距远大于总长
      expect(poles.length, 2, reason: '一档到底 → 起点 + 终点');
      expect(poles.first[0], closeTo(sLat, 1e-9));
      expect(poles.first[1], closeTo(sLon, 1e-9));
      expect(poles.last[0], closeTo(eLat, 1e-9));
      expect(poles.last[1], closeTo(eLon, 1e-9));
    });

    test('档距为 0 或负数：兜底为 50m，不抛异常', () {
      const sLat = 32.10, sLon = 114.00, eLat = 32.10, eLon = 114.01;
      final total = RouteLayout.haversineM(sLat, sLon, eLat, eLon);
      final expectCount = (total / 50.0).ceil() + 1;
      for (final sp in [0.0, -1.0, -1000.0]) {
        final poles = RouteLayout.autoPoles(
            startLat: sLat,
            startLon: sLon,
            endLat: eLat,
            endLon: eLon,
            spacingM: sp);
        expect(poles.length, expectCount, reason: '档距 $sp 应兜底为 50m');
      }
    });

    test('档距为 NaN：应安全兜底，不抛异常（防御性）', () {
      expect(
        () => RouteLayout.autoPoles(
            startLat: 32.10,
            startLon: 114.00,
            endLat: 32.10,
            endLon: 114.01,
            spacingM: double.nan),
        returnsNormally,
        reason: 'UI 允许 double.tryParse("NaN")→NaN 透传，算法层必须自防御',
      );
    });

    test('极小距离（<1m）：含起止两点，无异常', () {
      final poles = RouteLayout.autoPoles(
          startLat: 32.10,
          startLon: 114.00,
          endLat: 32.10,
          endLon: 114.000005, // ≈0.5m
          spacingM: 50);
      expect(poles.length, 2);
      expect(poles.first[1], closeTo(114.00, 1e-9));
      expect(poles.last[1], closeTo(114.000005, 1e-9));
    });

    test('纬度突变：destination 与 autoPoles 均不崩、结果为有限值', () {
      final p = RouteLayout.destination(80, 10, 180, 500000);
      expect(p[0].isFinite, isTrue);
      expect(p[1].isFinite, isTrue);
      final poles = RouteLayout.autoPoles(
          startLat: 80,
          startLon: 10,
          endLat: -80,
          endLon: 10,
          spacingM: 100000);
      expect(poles.first[0], closeTo(80, 1e-6));
      expect(poles.last[0], closeTo(-80, 1e-6));
      for (final q in poles) {
        expect(q[0].isFinite && q[1].isFinite, isTrue);
        expect(q[0], inInclusiveRange(-90, 90));
      }
    });

    test('首=起点、末=终点不变式在任意档距下成立', () {
      const sLat = 31.97, sLon = 113.88, eLat = 32.12, eLon = 114.02;
      for (final sp in [1.0, 7.3, 50.0, 123.4, 999999.0]) {
        final poles = RouteLayout.autoPoles(
            startLat: sLat,
            startLon: sLon,
            endLat: eLat,
            endLon: eLon,
            spacingM: sp);
        expect(poles.first[0], closeTo(sLat, 1e-9), reason: 'sp=$sp 起点');
        expect(poles.first[1], closeTo(sLon, 1e-9), reason: 'sp=$sp 起点');
        expect(poles.last[0], closeTo(eLat, 1e-9), reason: 'sp=$sp 终点');
        expect(poles.last[1], closeTo(eLon, 1e-9), reason: 'sp=$sp 终点');
      }
    });
  });

  // ================= B. buildDesignDiff 对抗 =================

  group('QA · CsvExporter.buildDesignDiff', () {
    MapLabel pole(String name, double lat, double lon,
            {String g = 'g', String distLabel = ''}) =>
        MapLabel(
            typeId: 'pipe',
            name: name,
            lat: lat,
            lon: lon,
            lineGroupId: g,
            distLabel: distLabel);

    test('空集合双方：全 0、无变更项、给备注', () {
      final r = CsvExporter.buildDesignDiff(const [], const []);
      expect(r.summary.added, 0);
      expect(r.summary.removed, 0);
      expect(r.summary.moved, 0);
      expect(r.summary.kept, 0);
      expect(r.summary.netLenDiffM, closeTo(0, 1e-9));
      expect(r.poles, isEmpty);
      expect(r.changedPoles, isEmpty);
      expect(r.segs, isEmpty);
      expect(r.notes, isNotEmpty, reason: '无可比对段时应给提示');
    });

    test('全部一致：changedPoles 为空、kept=n、净长度差≈0', () {
      List<MapLabel> make() => [
            pole('GK-1', 32.0, 114.0, distLabel: '100'),
            pole('GK-2', 32.001, 114.0, distLabel: '100'),
          ];
      final r = CsvExporter.buildDesignDiff(make(), make());
      expect(r.summary.moved, 0);
      expect(r.summary.added, 0);
      expect(r.summary.removed, 0);
      expect(r.summary.kept, 2);
      expect(r.changedPoles, isEmpty);
      expect(r.summary.netLenDiffM, closeTo(0, 1e-6));
      expect(r.segs, isNotEmpty);
      expect(r.notes, isEmpty);
    });

    test('阈值边界：偏移恰好等于阈值算「一致」（严格大于才判偏移）', () {
      final design = [pole('P1', 32.0, 114.0)];
      final comp = [pole('P1', 32.0001, 114.0)];
      final off = GeoUtil.haversine(32.0, 114.0, 32.0001, 114.0);

      final eq = CsvExporter.buildDesignDiff(design, comp, offsetThreshold: off);
      expect(eq.summary.moved, 0, reason: 'off == threshold 不应算偏移');
      expect(eq.summary.kept, 1);

      final below =
          CsvExporter.buildDesignDiff(design, comp, offsetThreshold: off - 0.01);
      expect(below.summary.moved, 1, reason: 'off > threshold 应算偏移');
      expect(below.summary.kept, 0);
    });

    test('净长度差符号方向：竣工更长 → 正值；更短 → 负值', () {
      final design = [
        pole('P1', 32.0, 114.0, distLabel: '100'),
        pole('P2', 32.001, 114.0, distLabel: '100'),
      ];
      final longer = [
        pole('P1', 32.0, 114.0, distLabel: '150'),
        pole('P2', 32.001, 114.0, distLabel: '150'),
      ];
      final shorter = [
        pole('P1', 32.0, 114.0, distLabel: '40'),
        pole('P2', 32.001, 114.0, distLabel: '40'),
      ];
      final rl = CsvExporter.buildDesignDiff(design, longer);
      // 段距对比：段采用后点 distLabel，竣工 150 设计 100 → +50
      final seg = rl.segs.firstWhere((s) => s.seg == 'P1>P2');
      expect(seg.deltaM, closeTo(50, 1e-6));
      // 净长度差 = 竣工总段距(150) − 设计总段距(100) = +50
      expect(rl.summary.netLenDiffM, closeTo(50, 1e-6));
      expect(rl.summary.netLenDiffM, greaterThan(0));

      final rs = CsvExporter.buildDesignDiff(design, shorter);
      expect(rs.summary.netLenDiffM, lessThan(0));
      expect(rs.segs.firstWhere((s) => s.seg == 'P1>P2').deltaM,
          closeTo(-60, 1e-6));
    });

    test('同名相邻杆不足：segs 空 + 备注非空（另一分支 segs 非空 + 备注空）', () {
      final design = [pole('A', 32.0, 114.0), pole('B', 32.001, 114.0)];
      final comp = [pole('C', 32.0, 114.0), pole('D', 32.001, 114.0)];
      final r = CsvExporter.buildDesignDiff(design, comp);
      expect(r.segs, isEmpty);
      expect(r.notes, isNotEmpty);
    });

    test('空名回退 key（#type@seq）不产生崩溃、不误判', () {
      final design = [
        MapLabel(typeId: 'pipe', seq: 1, lat: 32.0, lon: 114.0, lineGroupId: 'g')
      ];
      final comp = [
        MapLabel(typeId: 'pipe', seq: 1, lat: 32.0, lon: 114.0, lineGroupId: 'g')
      ];
      final r = CsvExporter.buildDesignDiff(design, comp);
      expect(r.summary.kept, 1);
      expect(r.poles.first.key.startsWith('#'), isTrue);
    });
  });

  // ================= C. applyBatch 对抗 =================

  group('QA · AppState.applyBatch', () {
    test('空选择返回 0（含 renumber）：不改动任何点', () {
      final st = AppState();
      st.labels.add(MapLabel(
          typeId: 'pipe', seq: 1, lat: 32.0, lon: 114.0, name: 'GK-1'));
      expect(st.selectedIds, isEmpty);
      expect(st.applyBatch(const BatchEdit(segKind: 1)), 0);
      expect(st.applyBatch(const BatchEdit(renumber: true, namePrefix: 'X')), 0);
      expect(st.labels.first.segKind, 0);
      expect(st.labels.first.name, 'GK-1');
    });

    test('跨链选择互不影响：后一次 selectChain 只保留该链', () {
      final st = AppState();
      final a1 = MapLabel(
          typeId: 'pipe', seq: 1, lat: 32.0, lon: 114.0, lineGroupId: 'gA');
      final b1 = MapLabel(
          typeId: 'pipe', seq: 2, lat: 32.1, lon: 114.1, lineGroupId: 'gB');
      st.labels.addAll([a1, b1]);

      st.selectChain('gA');
      expect(st.selectedIds, {a1.id});
      st.selectChain('gB');
      expect(st.selectedIds, {b1.id}, reason: '切换链应清空旧选择');
      expect(st.selectedIds.contains(a1.id), isFalse);
    });

    test('distLabelPrefix：只换前缀、保留原数字（含中缀标注）', () {
      final st = AppState();
      final a = MapLabel(
          typeId: 'pipe',
          seq: 1,
          lat: 32.0,
          lon: 114.0,
          lineGroupId: 'g',
          distLabel: '100');
      final b = MapLabel(
          typeId: 'pipe',
          seq: 2,
          lat: 32.0,
          lon: 114.001,
          lineGroupId: 'g',
          distLabel: '埋42.5');
      st.labels.addAll([a, b]);
      st.selectChain('g');

      final n = st.applyBatch(const BatchEdit(distLabelPrefix: 'K0+'));
      expect(n, 2);
      expect(a.distLabel, 'K0+100', reason: '前缀 + 原数字');
      expect(b.distLabel, 'K0+42.5', reason: '取首个数字段并保留');
    });

    test('一次撤销：批量后单次 undoDraft 还原全部字段（含 distLabel）', () {
      final st = AppState();
      final a = MapLabel(
          typeId: 'pipe',
          seq: 1,
          lat: 32.0,
          lon: 114.0,
          lineGroupId: 'g',
          name: 'GK-1',
          distLabel: '100');
      final b = MapLabel(
          typeId: 'pipe',
          seq: 2,
          lat: 32.0,
          lon: 114.001,
          lineGroupId: 'g',
          name: 'GK-2',
          distLabel: '100');
      st.labels.addAll([a, b]);
      st.selectChain('g');

      st.applyBatch(const BatchEdit(
          segKind: 2,
          segCable: '48芯GYTS',
          slackM: 7,
          namePrefix: 'GL',
          distLabelPrefix: 'K0+'));
      expect(a.segKind, 2);
      expect(a.segCable, '48芯GYTS');
      expect(a.slackM, 7);
      expect(a.name, 'GL-1');
      expect(a.distLabel, 'K0+100');

      st.undoDraft(); // 一次撤销
      // 注意：undoDraft 以快照重建 labels（新对象），须按 id 取回校验
      final ra = st.labels.firstWhere((l) => l.id == a.id);
      final rb = st.labels.firstWhere((l) => l.id == b.id);
      expect(ra.segKind, 0);
      expect(ra.segCable, '');
      expect(ra.slackM, 0);
      expect(ra.name, 'GK-1');
      expect(ra.distLabel, '100');
      expect(rb.name, 'GK-2');
      expect(rb.distLabel, '100');
    });

    test('无编号命名仅换前缀：无数字则整体设为前缀', () {
      final st = AppState();
      final a = MapLabel(
          typeId: 'pipe',
          seq: 1,
          lat: 32.0,
          lon: 114.0,
          lineGroupId: 'g',
          name: '临时杆');
      st.labels.add(a);
      st.selectChain('g');
      st.applyBatch(const BatchEdit(namePrefix: 'GK'));
      expect(a.name, 'GK', reason: '无尾号 → 整体设为前缀');
    });
  });

  // ================= D. archive_book 对抗 =================

  group('QA · ArchiveBookExporter', () {
    test('空工程：仍出海 ZIP、可解码、含成册说明.txt、缺项记 skipped', () async {
      final dir = Directory.systemTemp.createTempSync('ovimap_qa_book');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);

      final r =
          await ArchiveBookExporter.export(name: '空工程', labels: const []);
      expect(r.zip.existsSync(), isTrue);
      expect(r.zip.lengthSync(), greaterThan(0));

      final bytes = r.zip.readAsBytesSync();
      final arch = ZipDecoder().decodeBytes(bytes);
      final names = arch.files.map((f) => f.name).toList();
      expect(names.contains('成册说明.txt'), isTrue,
          reason: '无论缺项与否都必须带成册说明');

      final note = arch.files.firstWhere((f) => f.name == '成册说明.txt');
      final text = utf8.decode(note.content as List<int>, allowMalformed: true);
      expect(text.contains('滑洲云图'), isTrue);
      expect(text.contains('空工程'), isTrue);

      // 空工程：DXF 与照片册都应跳过
      expect(r.skipped.any((s) => s.contains('路由图')), isTrue);
      expect(r.skipped.any((s) => s.contains('照片')), isTrue);

      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
