// QA 补缺护栏（Phase7/E1 复验）：
// 1) T22 数据安全反事实：导入 .ovimap 遇**同名既有工程** → 绝不覆盖，
//    原工程完好在、新工程为副本（重名追加 (2)）。
// 2) E1 `computeProjectStats` 基线口径（工程师交付时无任何测试引用该纯函数）。
// 3) E1 vs CSV 材料统计**口径一致**交叉验证（totalLen/盘留/段数/敷设方式分布）：
//    统计面板的数字用户会直接用于光缆用量，必须与材料统计 CSV 同源同值。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/csv.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/ui/desktop/stats_section.dart';

final store = LabelStore.instance;

void main() {
  late Directory dir;
  late AppState st;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ovimap_qa_phase7_gap');
    store.setBaseDirForTest(dir);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
  });

  tearDown(() {
    AppPaths.clearForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  MapLabel pt(String id, int seq, double lat, double lon,
          {String? group, String? distLabel, double? distanceM,
           int segKind = 0, String segCable = '', double slackM = 0}) =>
      MapLabel(
          typeId: 'pipe', seq: seq, lat: lat, lon: lon, lineGroupId: group ?? '')
        ..id = id
        ..distLabel = distLabel ?? ''
        ..distanceM = distanceM
        ..segKind = segKind
        ..segCable = segCable
        ..slackM = slackM;

  group('T22 数据安全：同名导入绝不覆盖既有工程', () {
    test('既有「甲工程」(3点) + 导入同名 .ovimap (2点) → 原工程完好，新工程为副本', () async {
      // 既有工程（3 点）。
      st.projectName = '甲工程';
      st.labels = <MapLabel>[
        pt('A-1', 1, 32.0, 114.0, group: 'g1'),
        pt('A-2', 2, 32.001, 114.0, group: 'g1', distLabel: '111'),
        pt('A-3', 3, 32.002, 114.0, group: 'g1'),
      ];
      final cidA = await st.finishCollection();
      final before = await store.loadCollection(cidA);
      expect(before.length, 3);

      // 同名 .ovimap（2 点）。
      final f = File('${dir.path}/甲工程.ovimap');
      await f.writeAsString(jsonEncode(<String, dynamic>{
        'id': 'whatever-orig',
        'name': '甲工程',
        'kind': 'label',
        'folderId': '',
        'editMode': 'design',
        'labels': <Map<String, dynamic>>[
          {'id': 'B-1', 'typeId': 'pipe', 'seq': 1, 'lat': 32.1, 'lon': 114.0},
          {'id': 'B-2', 'typeId': 'pipe', 'seq': 2, 'lat': 32.101, 'lon': 114.0},
        ],
      }));

      final msg = await st.importProjectFile(f.path);
      expect(msg.contains('已导入并打开工程「甲工程(2)」'), isTrue, reason: '重名追加 (2)');

      // 原工程完好：id 不变、仍是 3 点、内容未被改。
      final idx = await store.loadIndex();
      expect(idx.where((m) => m.id == cidA), isNotEmpty,
          reason: '原工程必须仍在');
      final afterA = await store.loadCollection(cidA);
      expect(afterA.length, 3, reason: '原工程点位数不得被覆盖');
      expect(afterA.map((e) => e.id), containsAll(<String>['A-1', 'A-2', 'A-3']));

      // 新工程是副本（2 点），与原工程 id 不同。
      final copies = idx.where((m) => m.id != cidA && m.name.startsWith('甲工程'));
      expect(copies, isNotEmpty);
      final cidB = copies.first.id;
      final afterB = await store.loadCollection(cidB);
      expect(afterB.length, 2, reason: '新工程应为导入文件的 2 点');
      expect(afterB.map((e) => e.id), containsAll(<String>['B-1', 'B-2']));
    });
  });

  group('E1 computeProjectStats：基线口径', () {
    test('空 labels → 全 0', () {
      final s = computeProjectStats(const <MapLabel>[]);
      expect(s.pointCount, 0);
      expect(s.segCount, 0);
      expect(s.totalLenM, 0);
      expect(s.slackTotalM, 0);
      expect(s.byKind, isEmpty);
      expect(s.cableLenM, isEmpty);
    });

    test('2 点链：段距取标注值，敷设/型号/盘留归到段的后点', () {
      final labels = <MapLabel>[
        pt('A-1', 1, 32.0, 114.0, group: 'g1'),
        pt('A-2', 2, 32.001, 114.0, group: 'g1',
            distLabel: '100', segKind: 1, segCable: '48芯GYTS', slackM: 3.5),
        pt('C-1', 1, 32.5, 114.5), // 孤立点：计点位数，不计段
      ];
      final s = computeProjectStats(labels);
      expect(s.pointCount, 3);
      expect(s.segCount, 1);
      expect(s.totalLenM, 100.0, reason: '段距优先取段标注数字');
      expect(s.slackTotalM, 3.5);
      expect(s.byKind[1]!.lenM, 100.0);
      expect(s.byKind[1]!.segs, 1);
      expect(s.byKind.containsKey(0), isFalse, reason: '无 0 段则不出现默认项');
      expect(s.cableLenM['48芯GYTS'], 100.0);
    });

    test('段距口径：无标注时用 distanceM，再退 haversine（>0 且有限）', () {
      final d = statsSegDist(
        pt('A-1', 1, 32.0, 114.0, group: 'g1'),
        pt('A-2', 2, 32.001, 114.0, group: 'g1', distanceM: 88.0),
      );
      expect(d, 88.0);
      final d2 = statsSegDist(
        pt('A-1', 1, 32.0, 114.0, group: 'g1'),
        pt('A-2', 2, 32.001, 114.0, group: 'g1'),
      );
      expect(d2, greaterThan(0));
      expect(d2.isFinite, isTrue);
    });
  });

  group('E1 vs CSV 材料统计：口径一致（用户拿它对光缆用量）', () {
    test('混合工程：统计面板 totalLen/盘留/段数/敷设分布 == CSV 材料统计', () async {
      final labels = <MapLabel>[
        // g1: 3 点 2 段（一段有标注、一段无标注走 haversine）。
        pt('P-1', 1, 32.0, 114.0, group: 'g1'),
        pt('P-2', 2, 32.001, 114.0, group: 'g1',
            distLabel: '100', segKind: 1, segCable: 'GYTS-48', slackM: 2.0),
        pt('P-3', 3, 32.002, 114.0, group: 'g1', segKind: 2, slackM: 1.5),
        // g2: 2 点 1 段。
        pt('Q-1', 1, 32.1, 114.2, group: 'g2'),
        pt('Q-2', 2, 32.101, 114.2, group: 'g2',
            distLabel: '50', segKind: 1, segCable: 'GYTA-24', slackM: 0.5),
      ];

      final stats = computeProjectStats(labels);
      final csv = await CsvExporter.exportMaterialStats('口径交叉', labels);
      final text = await csv.readAsString();

      // 合计行：`合计,${totalLen.toStringAsFixed(1)},${段数}`
      final totalLine =
          text.split('\r\n').firstWhere((l) => l.startsWith('合计,'));
      final parts = totalLine.split(',');
      final csvTotal = double.parse(parts[1]);
      final csvSegs = int.parse(parts[2]);
      expect((csvTotal - stats.totalLenM).abs(), lessThan(0.05),
          reason: '杆路总距离两口径必须一致');
      expect(csvSegs, stats.segCount, reason: '段数两口径必须一致');

      // 盘留：`盘留合计(米),${slackTotal}`
      final slackLine = text
          .split('\r\n')
          .firstWhere((l) => l.startsWith('盘留合计(米),'));
      final csvSlack = double.parse(slackLine.split(',')[1]);
      expect((csvSlack - stats.slackTotalM).abs(), lessThan(1e-6),
          reason: '盘留合计两口径必须一致');

      // 敷设方式分布：架空行 `架空,${len},段数`。
      final jiaKong = text
          .split('\r\n')
          .firstWhere((l) => l.startsWith('架空,'));
      final jp = jiaKong.split(',');
      expect((double.parse(jp[1]) - stats.byKind[1]!.lenM).abs(), lessThan(0.05));
      expect(int.parse(jp[2]), stats.byKind[1]!.segs);
    });
  });
}
