/// 打印指定图块的原始 DXF 组码，用于核对"HATCH 边界是否被误读成直线"这类问题。
///
/// 用法：dart run tool/dump_raw_block.dart gl001 gx005_x
import 'dart:io';

void main(List<String> args) {
  final text = File('assets/dxf/lispblock.dxf').readAsStringSync();
  final lines = text.split('\n');
  final pairs = <List<String>>[];
  for (var i = 0; i + 1 < lines.length; i += 2) {
    final code = int.tryParse(lines[i].trim());
    if (code == null) continue;
    pairs.add([code.toString(), lines[i + 1].replaceAll('\r', '').trimRight()]);
  }

  final wanted = args.isEmpty ? ['gl001'] : args;
  for (final name in wanted) {
    // 定位 BLOCK 定义
    var start = -1;
    for (var i = 0; i < pairs.length; i++) {
      if (pairs[i][0] == '0' && pairs[i][1] == 'BLOCK') {
        var j = i + 1;
        String? n;
        while (j < pairs.length && pairs[j][0] != '0') {
          if (pairs[j][0] == '2') n = pairs[j][1];
          j++;
        }
        if (n == name) {
          start = i;
          break;
        }
      }
    }
    if (start < 0) {
      stdout.writeln('=== $name: NOT FOUND ===');
      continue;
    }
    stdout.writeln('=== $name (raw) ===');
    var i = start;
    var count = 0;
    while (i < pairs.length && count < 400) {
      stdout.writeln('${pairs[i][0].padLeft(3)}  ${pairs[i][1]}');
      if (i > start && pairs[i][0] == '0' && pairs[i][1] == 'ENDBLK') break;
      i++;
      count++;
    }
    stdout.writeln('');
  }
}
