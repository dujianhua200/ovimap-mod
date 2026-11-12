import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart'
    show InMemorySharedPreferencesStore, SharedPreferencesStorePlatform;

void main() {
  // 用内存版 SharedPreferences 让 AppState.segPrefix 可用（不依赖真实平台通道）。
  setUpAll(() {
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  });

  Future<AppState> newApp() async {
    final prefs = await SharedPreferences.getInstance();
    final st = AppState();
    st.setPrefsForTest(prefs);
    return st;
  }

  // 构造一条杆路：p1 起点(无 distanceM)，p2/p3 各有 distanceM 与敷设方式。
  // 段1 = p1→p2（38m, 架空），段2 = p2→p3（42.5m, 埋地）。
  List<MapLabel> mkChain(
      {String p2Label = '', String p3Label = '', int p3Kind = 2}) {
    return [
      MapLabel(
          typeId: 'pipe', seq: 1, name: 'GK-1', lat: 32.0, lon: 114.0, lineGroupId: 'g'),
      MapLabel(
          typeId: 'pipe',
          seq: 2,
          name: 'GK-2',
          lat: 32.001,
          lon: 114.001,
          lineGroupId: 'g',
          distanceM: 38,
          segKind: 1, // 架空
          distLabel: p2Label),
      MapLabel(
          typeId: 'pipe',
          seq: 3,
          name: 'GK-3',
          lat: 32.002,
          lon: 114.002,
          lineGroupId: 'g',
          distanceM: 42.5,
          segKind: p3Kind,
          distLabel: p3Label),
    ];
  }

  test('不覆盖模式：只填空白段，已有标注不动', () async {
    final st = await newApp();
    st.labels = mkChain(p2Label: '', p3Label: '手填老标注');
    final n = st.autoFillSegLabels(); // overwrite=false
    expect(n, 1, reason: '只有 p2（空白）被填，p3 已有标注不动');
    expect(st.labels[1].distLabel, '架38');
    expect(st.labels[2].distLabel, '手填老标注');
  });

  test('覆盖模式：全部重写', () async {
    final st = await newApp();
    st.labels = mkChain(p2Label: '旧架38', p3Label: '手填老标注');
    final n = st.autoFillSegLabels(overwrite: true);
    expect(n, 2, reason: '两段都重写');
    expect(st.labels[1].distLabel, '架38');
    expect(st.labels[2].distLabel, '埋42.5');
  });

  test('架空段得到"架+距离"形式', () async {
    final st = await newApp();
    st.labels = mkChain(p2Label: '', p3Label: '');
    st.autoFillSegLabels(overwrite: true);
    // 架空(1)→前缀"架"；埋地(2)→前缀"埋"
    expect(st.labels[1].distLabel, startsWith('架'));
    expect(st.labels[1].distLabel, '架38');
    expect(st.labels[2].distLabel, startsWith('埋'));
  });

  test('全局段标前缀回退：kind=0 段用 segPrefix，两者皆空则纯数字', () async {
    final st = await newApp();
    st.labels = mkChain(p2Label: '', p3Label: '', p3Kind: 0); // p3 改默认方式
    // 先验证默认（segPrefix 空）→ 纯数字
    st.autoFillSegLabels(overwrite: true);
    expect(st.labels[1].distLabel, '架38');
    expect(st.labels[2].distLabel, '42.5',
        reason: 'kind=0 且 segPrefix 空 → 只写距离纯数字');

    // 设置全局前缀 G → kind=0 段带 G，架空段仍带"架"
    st.setSegPrefix('G');
    st.labels = mkChain(p2Label: '', p3Label: '', p3Kind: 0);
    st.autoFillSegLabels(overwrite: true);
    expect(st.labels[1].distLabel, '架38');
    expect(st.labels[2].distLabel, 'G42.5',
        reason: 'kind=0 回退到全局段标前缀 G');
  });

  test('返回条数正确：段数 = Σ(链长-1)', () async {
    final st = await newApp();
    // 再加一条独立线组，共 2 链：链1(2段)+链2(1段)=3 段
    final extra = [
      MapLabel(
          typeId: 'pipe', seq: 4, lat: 33.0, lon: 115.0, lineGroupId: 'g2', distanceM: 10, segKind: 1),
    ];
    st.labels = [...mkChain(p2Label: '', p3Label: ''), ...extra];
    // 段1(p1→p2)、段2(p2→p3)、段3(p2?? 实际 g2 只有 p4 单点 → 0 段)
    // 修正：给 g2 再加一点形成 1 段
    st.labels = [
      ...mkChain(p2Label: '', p3Label: ''),
      MapLabel(typeId: 'pipe', seq: 4, lat: 33.0, lon: 115.0, lineGroupId: 'g2'),
      MapLabel(typeId: 'pipe', seq: 5, lat: 33.001, lon: 115.001, lineGroupId: 'g2', distanceM: 20, segKind: 1),
    ];
    final n = st.autoFillSegLabels(overwrite: true);
    expect(n, 3, reason: '链1(2段)+链2(1段)=3 段');
  });

  test('可一次撤销回退整批', () async {
    final st = await newApp();
    st.labels = mkChain(p2Label: '', p3Label: '');
    final before = st.labels.map((l) => l.distLabel).toList();
    final n = st.autoFillSegLabels(overwrite: true);
    expect(n, 2);
    expect(st.labels[1].distLabel, isNot(equals(before[1])));
    // 一次撤销：整批回到填之前
    st.undoDraft();
    expect(st.labels.map((l) => l.distLabel).toList(), before,
        reason: '撤销后所有段标注应还原');
  });

  test('无改动时返回 0（不压快照、可重复调用）', () async {
    final st = await newApp();
    st.labels = mkChain(p2Label: '', p3Label: '');
    final first = st.autoFillSegLabels(overwrite: true); // 填 2 段
    expect(first, 2);
    // 第二次（默认不覆盖）：已无空白段 → 无改动 → 0
    final second = st.autoFillSegLabels();
    expect(second, 0);
    expect(st.labels[1].distLabel, '架38');
  });
}
