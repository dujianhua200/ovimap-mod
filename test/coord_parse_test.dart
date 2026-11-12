import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/geo/geo_util.dart';

void main() {
  group('parseCoordInput 坐标解析', () {
    test('十进制：逗号/空格/全角分隔，经纬自动换序', () {
      expect(GeoUtil.parseCoordInput('32.1301,114.0814'),
          [32.1301, 114.0814]); // 纬度在前
      final r = GeoUtil.parseCoordInput('114.0814 32.1301');
      expect(r, isNotNull);
      expect(r![0], closeTo(32.1301, 1e-6)); // 经度在前自动换序
      expect(r[1], closeTo(114.0814, 1e-6));
      expect(GeoUtil.parseCoordInput('32.1301，114.0814'),
          [32.1301, 114.0814]);
    });

    test('度分秒：半球字母在前后都支持', () {
      final r = GeoUtil.parseCoordInput("32°07'48\"N 114°05'24\"E");
      expect(r, isNotNull);
      expect(r![0], closeTo(32.13, 0.001)); // 48" = 0.8'
      expect(r[1], closeTo(114.09, 0.001)); // 5'24" = 5.4'
    });

    test('度分秒：中文单位混排', () {
      final r = GeoUtil.parseCoordInput('北纬32度07分48秒 东经114度05分24秒');
      // 无 N/S/E/W 单字母，按先纬后经惯例
      expect(r, isNotNull);
      expect(r![0], closeTo(32.13, 0.001));
      expect(r[1], closeTo(114.09, 0.001));
    });

    test('非法输入返回 null', () {
      expect(GeoUtil.parseCoordInput('信阳市平桥区'), isNull);
      expect(GeoUtil.parseCoordInput(''), isNull);
      expect(GeoUtil.parseCoordInput('123'), isNull);
      expect(GeoUtil.parseCoordInput('99,200'), isNull); // 经度越界
    });
  });
}
