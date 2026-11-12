import 'dart:io';

import 'package:ovimap/symbols/dxf_block_parser.dart';

void main(List<String> args) {
  final path = args.isNotEmpty ? args.first : 'assets/dxf/lispblock.dxf';
  final text = File(path).readAsStringSync();
  final sw = Stopwatch()..start();
  final r = DxfBlockParser.parse(text);
  sw.stop();
  stdout.writeln('parse ms: ${sw.elapsedMilliseconds}');
  stdout.writeln('blocks: ${r.blocks.length}  legend: ${r.legend.length}');
  stdout.writeln('warnings: ${r.warnings}');
  final names = r.blocks.keys.toList()..sort();
  for (final n in names) {
    final b = r.blocks[n]!;
    stdout.writeln('  ${n.padRight(26)} strokes=${b.strokes.length.toString().padLeft(4)} '
        'w=${b.width.toStringAsFixed(1)} h=${b.height.toStringAsFixed(1)} '
        'nested=${b.nested}');
  }
  stdout.writeln('--- legend ---');
  for (final e in r.legend) {
    final b = r.blocks[e.block];
    stdout.writeln('  ${e.block.padRight(12)} -> ${e.label.padRight(20)} '
        'size=${b == null ? "MISSING" : "${b.width.toStringAsFixed(1)}x${b.height.toStringAsFixed(1)}"}');
  }
}
