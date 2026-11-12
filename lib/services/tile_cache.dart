import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import 'store.dart';

/// 三级缓存瓦片供给器：内存（ImageCache）→ 磁盘 → 网络。
/// 网络下载的瓦片自动落盘，可被离线下载复用。
class CacheTileProvider extends TileProvider {
  final String sourceId;
  final String urlTemplate;

  /// 递增序号：清缓存后让旧 ImageProvider key 失效。
  int generation = 0;

  CacheTileProvider({required this.sourceId, required this.urlTemplate})
      : super(headers: {
          'User-Agent': 'HuaZhouCloudMap/3.0 (Flutter; tile fetch)',
        });

  String urlFor(TileCoordinates c) => urlTemplate
      .replaceAll('{x}', '${c.x}')
      .replaceAll('{y}', '${c.y}')
      .replaceAll('{z}', '${c.z}')
      .replaceAll('{-y}', '${(1 << c.z) - 1 - c.y}');

  Future<File> _cacheFile(int z, int x, int y) async {
    final dir = await LabelStore.instance.tilesDir();
    final d = Directory('${dir.path}/$sourceId/$z');
    if (!d.existsSync()) d.createSync(recursive: true);
    return File('${d.path}/${x}_$y.tile');
  }

  Future<Uint8List> fetchBytes(TileCoordinates c) async {
    final f = await _cacheFile(c.z, c.x, c.y);
    if (f.existsSync()) {
      try {
        final b = await f.readAsBytes();
        if (b.isNotEmpty) return b;
      } catch (_) {}
    }
    final res = await http
        .get(Uri.parse(urlFor(c)), headers: headers)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
      throw HttpException('tile http ${res.statusCode}');
    }
    final bytes = res.bodyBytes;
    try {
      await f.writeAsBytes(bytes, flush: true);
    } catch (_) {}
    return bytes;
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _CacheImage(coordinates, this);

  /// 清空本图源磁盘缓存。
  Future<int> clearDiskCache() async {
    generation++;
    try {
      final dir = await LabelStore.instance.tilesDir();
      final d = Directory('${dir.path}/$sourceId');
      if (d.existsSync()) {
        d.deleteSync(recursive: true);
        return 1;
      }
    } catch (_) {}
    return 0;
  }
}

class _CacheKey {
  final int x, y, z, gen;
  final String sourceId;
  const _CacheKey(this.x, this.y, this.z, this.gen, this.sourceId);

  @override
  bool operator ==(Object other) =>
      other is _CacheKey &&
      other.x == x &&
      other.y == y &&
      other.z == z &&
      other.gen == gen &&
      other.sourceId == sourceId;

  @override
  int get hashCode => Object.hash(x, y, z, gen, sourceId);
}

class _CacheImage extends ImageProvider<_CacheKey> {
  final TileCoordinates coordinates;
  final CacheTileProvider provider;
  const _CacheImage(this.coordinates, this.provider);

  @override
  Future<_CacheKey> obtainKey(ImageConfiguration configuration) async =>
      _CacheKey(coordinates.x, coordinates.y, coordinates.z,
          provider.generation, provider.sourceId);

  @override
  ImageStreamCompleter loadImage(_CacheKey key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1,
      informationCollector: () sync* {
        yield ErrorDescription(
            'tile ${key.sourceId} z${key.z}/${key.x}/${key.y}');
      },
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await provider.fetchBytes(coordinates);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }
}

/// 离线区域下载：把当前视野按目标级别的全部瓦片抓入磁盘缓存。
class OfflineDownload {
  OfflineDownload._();
  static final OfflineDownload instance = OfflineDownload._();

  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;

  /// 估算某视野在目标级别的瓦片数。
  int estimateTiles(LatLngBounds boundsDisp, int zoom) {
    final r = _tileRange(boundsDisp, zoom);
    return (r.$3 - r.$1 + 1) * (r.$4 - r.$2 + 1);
  }

  (int, int, int, int) _tileRange(LatLngBounds b, int z) {
    final n = math.pow(2, z).toDouble();
    int xOf(double lon) =>
        ((lon + 180.0) / 360.0 * n).floor().clamp(0, n.toInt() - 1);
    int yOf(double lat) {
      final clamped = lat.clamp(-85.0511, 85.0511);
      final rad = clamped * math.pi / 180.0;
      return ((1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) /
                  2 *
                  n)
              .floor()
              .clamp(0, n.toInt() - 1);
    }

    final x0 = xOf(b.west);
    final x1 = xOf(b.east);
    final y0 = yOf(b.north);
    final y1 = yOf(b.south);
    return (math.min(x0, x1), math.min(y0, y1), math.max(x0, x1),
        math.max(y0, y1));
  }

  /// 开始下载。[onProgress] 回调 (完成数, 总数, 新下载数)。返回下载的新瓦片数。
  Future<int> download({
    required CacheTileProvider provider,
    required LatLngBounds boundsDisp,
    required int targetZoom,
    required void Function(int done, int total, int fresh) onProgress,
  }) async {
    _cancelled = false;
    final r = _tileRange(boundsDisp, targetZoom);
    final tiles = <TileCoordinates>[
      for (var x = r.$1; x <= r.$3; x++)
        for (var y = r.$2; y <= r.$4; y++) TileCoordinates(x, y, targetZoom),
    ];
    final total = tiles.length;
    var done = 0;
    var fresh = 0;
    var idx = 0;

    Future<void> worker() async {
      while (!_cancelled) {
        final my = idx++;
        if (my >= tiles.length) return;
        try {
          await provider.fetchBytes(tiles[my]);
          fresh++;
        } catch (_) {
          // 单瓦片失败不阻塞整体
        }
        done++;
        onProgress(done, total, fresh);
      }
    }

    final workers =
        List<Future<void>>.generate(math.min(8, total), (_) => worker());
    await Future.wait(workers);
    return fresh;
  }
}
