import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/analysis/route_check.dart';
import 'package:ovimap/geo/route_segments.dart';
import 'package:ovimap/models/map_label.dart';

void main() {
  // 构造一条线组的若干点：第 i 段（点i-1→点i）的段距 = dists[i-1]（写进 to.distanceM）。
  List<MapLabel> chain(
    List<double> dists, {
    int kind = 1,
    List<String> names = const [],
    List<int> seqs = const [],
    List<double> slacks = const [],
    List<String> cables = const [],
    List<String> distLabels = const [],
  }) {
    final labels = <MapLabel>[];
    for (var i = 0; i < dists.length + 1; i++) {
      labels.add(MapLabel(
        typeId: 'pipe',
        seq: seqs.length > i ? seqs[i] : i + 1,
        name: names.length > i ? names[i] : '',
        lat: 32.0 + i * 0.001, // 仅占位，段距走 distanceM
        lon: 114.0,
        lineGroupId: 'g',
        distanceM: i == 0 ? null : dists[i - 1],
        segKind: kind,
        slackM: i > 0 && slacks.length > i - 1 ? slacks[i - 1] : 0,
        segCable: i > 0 && cables.length > i - 1 ? cables[i - 1] : '',
        distLabel: i > 0 && distLabels.length > i - 1 ? distLabels[i - 1] : '',
      ));
    }
    return labels;
  }

  // 压制与本次检查无关的项，便于单测聚焦某个 code。
  RouteCheckOptions quiet() => RouteCheckOptions(
        minSegM: 0.0001,
        maxSegM: 1e12,
        requireKind: false,
        requireCable: false,
        completionMode: false,
      );

  List<RouteIssue> by(List<RouteSegment> segs, List<MapLabel> labels,
          [RouteCheckOptions? opt]) =>
      RouteChecker.check(segs, labels, opt: opt);

  group('段级检查', () {
    test('seg_too_short：正例(<下限) / 反例(正常)', () {
      final pos = RouteSegment.build(chain([3], kind: 1)); // 3 < 5
      expect(by(pos, chain([3], kind: 1)).where((i) => i.code == 'seg_too_short'),
          isNotEmpty);
      final neg = RouteSegment.build(chain([10], kind: 1)); // 10 >= 5
      expect(by(neg, chain([10], kind: 1)).where((i) => i.code == 'seg_too_short'),
          isEmpty);
    });

    test('seg_too_long：正例(>上限) / 反例(正常)', () {
      final pos = RouteSegment.build(chain([300], kind: 1)); // 300 > 200
      expect(by(pos, chain([300], kind: 1)).where((i) => i.code == 'seg_too_long'),
          isNotEmpty);
      final neg = RouteSegment.build(chain([100], kind: 1)); // 100 < 200
      expect(by(neg, chain([100], kind: 1)).where((i) => i.code == 'seg_too_long'),
          isEmpty);
    });

    test('seg_no_kind：正例(kind=0) / 反例(kind≠0)', () {
      final opt = RouteCheckOptions(requireKind: true);
      final pos = RouteSegment.build(chain([50], kind: 0));
      expect(by(pos, chain([50], kind: 0), opt)
          .where((i) => i.code == 'seg_no_kind'),
          isNotEmpty);
      final neg = RouteSegment.build(chain([50], kind: 1));
      expect(by(neg, chain([50], kind: 1), opt)
          .where((i) => i.code == 'seg_no_kind'),
          isEmpty);
    });

    test('seg_no_cable：正例(要求且为空) / 反例(已填)', () {
      final opt = RouteCheckOptions(requireKind: false, requireCable: true);
      final pos = RouteSegment.build(chain([50], kind: 1, cables: ['']));
      expect(by(pos, chain([50], kind: 1, cables: ['']), opt)
          .where((i) => i.code == 'seg_no_cable'),
          isNotEmpty);
      final neg = RouteSegment.build(chain([50], kind: 1, cables: ['48芯GYTS']));
      expect(by(neg, chain([50], kind: 1, cables: ['48芯GYTS']), opt)
          .where((i) => i.code == 'seg_no_cable'),
          isEmpty);
    });

    test('seg_slack_missing：正例(竣工且=0) / 反例(已填)', () {
      final opt = RouteCheckOptions(requireKind: false, completionMode: true);
      final pos = RouteSegment.build(chain([50], kind: 1, slacks: [0]));
      expect(by(pos, chain([50], kind: 1, slacks: [0]), opt)
          .where((i) => i.code == 'seg_slack_missing'),
          isNotEmpty);
      final neg = RouteSegment.build(chain([50], kind: 1, slacks: [5]));
      expect(by(neg, chain([50], kind: 1, slacks: [5]), opt)
          .where((i) => i.code == 'seg_slack_missing'),
          isEmpty);
    });

    test('seg_label_drift：边界刚好 5% 不报、5.1% 报，且解析不出跳过', () {
      final opt = RouteCheckOptions(requireKind: false, labelDriftRatio: 0.05);
      // 实测 100m：标注 105 → 偏差 5% → 不报
      final at = RouteSegment.build(chain([100], kind: 1, distLabels: ['105']));
      expect(by(at, chain([100], kind: 1, distLabels: ['105']), opt)
          .where((i) => i.code == 'seg_label_drift'),
          isEmpty);
      // 实测 100m：标注 105.1 → 偏差 5.1% → 报
      final over = RouteSegment.build(chain([100], kind: 1, distLabels: ['105.1']));
      expect(by(over, chain([100], kind: 1, distLabels: ['105.1']), opt)
          .where((i) => i.code == 'seg_label_drift'),
          isNotEmpty);
      // 标注为纯文字 → 解析不出 → 跳过（不报错）
      final text = RouteSegment.build(chain([100], kind: 1, distLabels: ['约一百米']));
      expect(by(text, chain([100], kind: 1, distLabels: ['约一百米']), opt)
          .where((i) => i.code == 'seg_label_drift'),
          isEmpty);
      // 防御：解析结果为 0 / 非有限（".0"、"0"、"."）无意义，跳过不报
      for (final bad in ['.0', '0', '.', '..']) {
        final b = RouteSegment.build(chain([100], kind: 1, distLabels: [bad]));
        expect(by(b, chain([100], kind: 1, distLabels: [bad]), opt)
            .where((i) => i.code == 'seg_label_drift'),
            isEmpty,
            reason: '标注 "$bad" 不应触发 drift');
      }
    });
  });

  group('geo_jump', () {
    test('正例：3 段，排除自身参照', () {
      // 3 段：50/50/500。对最后一段，参照值=(50+50)/2=50，500>3×50 且 >50 → 触发。
      // 用"排除自身"的参照，3 段链也能判定（含自身的均值会使 >均值×3 不可能）。
      final opt = RouteCheckOptions(requireKind: false);
      final segs = RouteSegment.build(chain([50, 50, 500], kind: 1));
      final issues = by(segs, chain([50, 50, 500], kind: 1), opt);
      final jumps = issues.where((i) => i.code == 'geo_jump');
      expect(jumps.length, 1);
      expect(jumps.first.level, IssueLevel.warn);
    });

    test('反例：3 段均匀不误报', () {
      // 3 段均为 100：参照值=(100+100)/2=100，100>3×100 不成立 → 不触发。
      final opt = RouteCheckOptions(requireKind: false);
      final segs = RouteSegment.build(chain([100, 100, 100], kind: 1));
      final issues = by(segs, chain([100, 100, 100], kind: 1), opt);
      expect(issues.where((i) => i.code == 'geo_jump'), isEmpty);
    });

    test('反例：单段链（仅 2 点）不触发 geo_jump（即使段距很大）', () {
      final opt = RouteCheckOptions(requireKind: false);
      final segs = RouteSegment.build(chain([1000], kind: 1));
      final issues = by(segs, chain([1000], kind: 1), opt);
      expect(issues.where((i) => i.code == 'geo_jump'), isEmpty);
    });
  });

  group('点级检查', () {
    test('label_dup_name：正例(重名) / 反例(唯一)', () {
      final opt = quiet();
      final pos = chain([50], kind: 1, names: ['A', 'A']);
      expect(by(RouteSegment.build(pos), pos, opt)
          .where((i) => i.code == 'label_dup_name'),
          isNotEmpty);
      final neg = chain([50], kind: 1, names: ['A', 'B']);
      expect(by(RouteSegment.build(neg), neg, opt)
          .where((i) => i.code == 'label_dup_name'),
          isEmpty);
    });

    test('label_unnamed：正例(seq>1 且无名) / 反例(已命名 / seq=1)', () {
      final opt = quiet();
      final pos = chain([50], kind: 1, names: ['GK-1', '']); // 第2点无名
      final posIssues = by(RouteSegment.build(pos), pos, opt);
      final unnamed = posIssues.where((i) => i.code == 'label_unnamed');
      expect(unnamed.length, 1);
      expect(unnamed.first.labelIds, [pos[1].id]);

      final negNamed = chain([50], kind: 1, names: ['GK-1', 'GK-2']);
      expect(by(RouteSegment.build(negNamed), negNamed, opt)
          .where((i) => i.code == 'label_unnamed'),
          isEmpty);

      // 链首点（seq=1）无名也不报
      final headUnnamed = chain([50], kind: 1, names: ['', 'GK-2']);
      expect(by(RouteSegment.build(headUnnamed), headUnnamed, opt)
          .where((i) => i.code == 'label_unnamed'),
          isEmpty);
    });

    test('label_seq_gap：正例(序号跳变) / 反例(连续)', () {
      final opt = quiet();
      final pos = chain([50], kind: 1, seqs: [1, 3]); // 从 1 跳到 3
      final gap = by(RouteSegment.build(pos), pos, opt)
          .where((i) => i.code == 'label_seq_gap');
      expect(gap.length, 1);
      expect(gap.first.labelIds, [pos[0].id, pos[1].id]);

      final neg = chain([50], kind: 1, seqs: [1, 2]);
      expect(by(RouteSegment.build(neg), neg, opt)
          .where((i) => i.code == 'label_seq_gap'),
          isEmpty);
    });
  });

  group('labelIds 可定位', () {
    test('段类问题定位 [from.id, to.id]', () {
      final labels = chain([3], kind: 1); // 触发 seg_too_short（error）
      final segs = RouteSegment.build(labels);
      final issues = by(segs, labels);
      final short = issues.firstWhere((i) => i.code == 'seg_too_short');
      expect(short.labelIds, [segs.first.from.id, segs.first.to.id]);
    });
    test('点类问题定位 [label.id]', () {
      final labels = chain([50], kind: 1, names: ['A', 'A']);
      final issues = by(RouteSegment.build(labels), labels, quiet());
      final dup = issues.firstWhere((i) => i.code == 'label_dup_name');
      expect(dup.labelIds, contains(labels[0].id));
      expect(dup.labelIds, contains(labels[1].id));
    });
  });

  group('排序', () {
    test('error → warn → info，同级稳定', () {
      // 构造含 error / warn / info 的场景：两短段(3m→too_short) + kind=0(→no_kind) + 第3点无名
      final labels = chain([3, 3], kind: 0, names: ['GK-1', 'GK-2', '']);
      final issues = RouteChecker.check(RouteSegment.build(labels), labels);
      const rank = {IssueLevel.error: 0, IssueLevel.warn: 1, IssueLevel.info: 2};
      final ranks = issues.map((i) => rank[i.level]!).toList();
      // 非递减 = 已按 error/warn/info 排好
      for (var i = 1; i < ranks.length; i++) {
        expect(ranks[i] >= ranks[i - 1], isTrue,
            reason: '第 $i 项等级不应低于前一项');
      }
      expect(issues.any((i) => i.level == IssueLevel.error), isTrue);
      expect(issues.any((i) => i.level == IssueLevel.warn), isTrue);
      expect(issues.any((i) => i.level == IssueLevel.info), isTrue);
      // 首个 error 早于首个 warn 早于首个 info
      final firstError = issues.indexWhere((i) => i.level == IssueLevel.error);
      final firstWarn = issues.indexWhere((i) => i.level == IssueLevel.warn);
      final firstInfo = issues.indexWhere((i) => i.level == IssueLevel.info);
      expect(firstError, lessThan(firstWarn));
      expect(firstWarn, lessThan(firstInfo));
    });
  });

  test('IssueLevel.label 中文', () {
    expect(IssueLevel.error.label, '错误');
    expect(IssueLevel.warn.label, '警告');
    expect(IssueLevel.info.label, '提示');
  });
}
