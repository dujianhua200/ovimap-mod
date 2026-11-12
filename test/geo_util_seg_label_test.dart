import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/geo/geo_util.dart';
import 'package:ovimap/models/map_label.dart';

/// 段标注显示口径（[GeoUtil.segLabelFor]）单测：地图 / 导出唯一真源。
void main() {
  // 构造一个带手填段标注的点。
  MapLabel mkLabel(String distLabel) => MapLabel(distLabel: distLabel);

  test('distLabel 非空 → 原样返回（手填优先级最高）', () {
    expect(GeoUtil.segLabelFor(mkLabel('埋42.5'), '38.0'), equals('埋42.5'));
    expect(GeoUtil.segLabelFor(mkLabel('架38'), '12.3'), equals('架38'));
    // 前后空格按 trim 后判定（与历史口径一致）：'埋 42.5 ' 返回 '埋 42.5'。
    expect(GeoUtil.segLabelFor(mkLabel(' 埋42.5 '), '38.0'), equals('埋42.5'));
  });

  test('distLabel 仅空白 → 视为未手填，落到自动距离（与历史口径一致）', () {
    // 历史实现是 `distLabel.trim().isNotEmpty ? distLabel.trim() : 距离`，
    // 所以"只有空格"必须落到自动距离，而不是把空格原样画到地图上。
    expect(GeoUtil.segLabelFor(mkLabel('   '), '12.3'), equals('12.3'));
    expect(GeoUtil.segLabelFor(mkLabel('   '), '12.3', prefix: '埋'),
        equals('埋12.3'));
  });

  test('distLabel 空 + 无前缀 → 仅显示已格式化距离文本', () {
    expect(GeoUtil.segLabelFor(mkLabel(''), '42.0'), equals('42.0'));
    expect(GeoUtil.segLabelFor(MapLabel(), '1.23km'), equals('1.23km'));
  });

  test('distLabel 空 + 有前缀 → 前缀 + 距离文本', () {
    expect(GeoUtil.segLabelFor(mkLabel(''), '42.0', prefix: '埋'),
        equals('埋42.0'));
    expect(GeoUtil.segLabelFor(mkLabel(''), '38.5', prefix: '架'),
        equals('架38.5'));
  });

  test('prefix 默认空串等价于不改行为', () {
    expect(GeoUtil.segLabelFor(mkLabel(''), '42.0'),
        equals(GeoUtil.segLabelFor(mkLabel(''), '42.0', prefix: '')));
  });
}
