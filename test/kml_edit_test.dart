import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/kml_import.dart';
import 'package:ovimap/models/map_label.dart';

void main() {
  test('KML 解析：Point 与 LineString 混合', () {
    const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>光交箱A</name>
      <Point><coordinates>114.081400,32.130100,0</coordinates></Point>
    </Placemark>
    <Placemark>
      <name>老杆路</name>
      <LineString>
        <coordinates>
          114.080000,32.130000,0
          114.081000,32.130500
          114.082000,32.131000,0
        </coordinates>
      </LineString>
    </Placemark>
    <Placemark>
      <name>无坐标块</name>
    </Placemark>
  </Document>
</kml>
''';
    final r = KmlImporter.parse(xml);
    expect(r, isNotNull);
    expect(r!.pointCount, 1);
    expect(r.lineCount, 1);
    // 1 个点 + 3 个线顶点
    expect(r.labels.length, 4);
    final pt = r.labels.first;
    expect(pt.name, '光交箱A');
    expect(pt.lat, closeTo(32.1301, 1e-6));
    expect(pt.lon, closeTo(114.0814, 1e-6));
    // 线要素：首顶点带名称、同一 lineGroupId
    final linePts = r.labels.skip(1).toList();
    expect(linePts.length, 3);
    expect(linePts[0].lineGroupId, isNotEmpty);
    expect(linePts[0].lineGroupId, linePts[2].lineGroupId);
    expect(linePts[0].name, '老杆路');
    expect(linePts[1].name, isEmpty);
    expect(linePts[0].lineGroupId != pt.lineGroupId, isTrue);
  });

  test('KML 解析：CDATA 名称与非法坐标过滤', () {
    const xml = '''
<Placemark><name><![CDATA[<b>大楼</b>分支]]></name>
<Point><coordinates>abc,def 114.5,32.5 999,32.5 114.5,32.5</coordinates></Point></Placemark>
''';
    final r = KmlImporter.parse(xml);
    expect(r, isNotNull);
    expect(r!.pointCount, 1);
    expect(r.labels.first.name, '<b>大楼</b>分支');
  });

  test('KML 解析：空内容返回 null', () {
    expect(KmlImporter.parse('<kml><Document/></kml>'), isNull);
    expect(KmlImporter.parse('不是KML'), isNull);
  });

  test('快照撤销：MapLabel JSON 往返无损', () {
    final l = MapLabel(
      typeId: 'crossbox',
      seq: 2,
      lat: 32.1301,
      lon: 114.0814,
      name: '李庄光交',
      note: '12芯',
    )
      ..lineGroupId = 'g9'
      ..holes = 12
      ..usedHoles = 4
      ..slackM = 8.5
      ..segCable = '48芯GYTS'
      ..segKind = 3
      ..photoPaths.addAll(['abc_1.jpg', 'abc_2.jpg']);
    final snapshot = MapLabel.fromJson(
        (l.toJson().map((k, v) => MapEntry(k, v))));
    // 通过序列化往返模拟快照恢复
    final restored = MapLabel.fromJson(l.toJson());
    expect(restored.lat, snapshot.lat);
    expect(restored.name, '李庄光交');
    expect(restored.lineGroupId, 'g9');
    expect(restored.holes, 12);
    expect(restored.slackM, 8.5);
    expect(restored.segCable, '48芯GYTS');
    expect(restored.segKind, 3);
    expect(restored.photoPaths, ['abc_1.jpg', 'abc_2.jpg']);
    // 旧数据无 photoPaths 字段：默认空列表，不崩
    final legacy = MapLabel.fromJson({'typeId': 'pipe', 'lat': 32, 'lon': 114});
    expect(legacy.photoPaths, isEmpty);
  });
}
