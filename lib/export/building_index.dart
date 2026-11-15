/// 建筑轮廓的**分块二进制索引**读取器（v3.28）。
///
/// ## 为什么需要
/// 旧实现（GeoJSON gzip）每次查询要 `gzip.decode(57MB)` + `jsonDecode`
/// 176 万栋建筑 —— **实测 15 秒/次**。导出流程会调用多次，用户反馈
/// "导出速度一直很慢"。
///
/// ## 格式（.ovbld v3，由 tool/build_index.py 生成）
/// ```
/// HEADER  magic(8) cell(4) lonMin(4) latMin(4) nCols(4) nRows(4)
///         indexOfs(8) dataOfs(8)
/// INDEX   nCells × (uint64 offset, uint32 compLen, uint32 nRings)
/// DATA    各网格块独立 gzip，首尾相接
/// ```
/// 块内（解压后）：`uint32 nRings` + 每环 `uint32 nPts` + nPts×(f32,f32)，
/// 坐标是**相对该格左下角**的偏移（float32 精度足够，体积省一半）。
///
/// 查询只解压命中的块（一般 1~25 块，几十 KB），解压量从 57MB 降到几百 KB。
library;

import 'dart:io' show gzip;
import 'dart:typed_data';

/// 分块索引查询器。构造后零拷贝持有整块字节，按需解压。
class BuildingIndex {
  BuildingIndex._(
    this._bytes,
    this._cell,
    this._lonMin,
    this._latMin,
    this._nCols,
    this._nRows,
    this._indexOfs,
    this._dataOfs,
  );

  /// 解析文件头。格式不对返回 null（调用方回退到 GeoJSON 路径）。
  static BuildingIndex? parse(Uint8List bytes) {
    if (bytes.length < 40) return null;
    final bd = ByteData.sublistView(bytes);
    // magic = "OVBL" + 版本 [3,1,0,0]，严格 8 字节
    if (bytes[0] != 0x4F || bytes[1] != 0x56 ||
        bytes[2] != 0x42 || bytes[3] != 0x4C) {
      return null;
    }
    final cell = bd.getFloat32(8, Endian.little);
    final lonMin = bd.getFloat32(12, Endian.little);
    final latMin = bd.getFloat32(16, Endian.little);
    final nCols = bd.getUint32(20, Endian.little);
    final nRows = bd.getUint32(24, Endian.little);
    final indexOfs = bd.getUint64(28, Endian.little);
    final dataOfs = bd.getUint64(36, Endian.little);
    if (cell <= 0 || nCols == 0 || nRows == 0) return null;
    if (indexOfs + nCols * nRows * 16 > bytes.length) return null;
    if (dataOfs > bytes.length) return null;
    return BuildingIndex._(
        bytes, cell, lonMin, latMin, nCols, nRows, indexOfs, dataOfs);
  }

  final Uint8List _bytes;
  final double _cell;
  final double _lonMin;
  final double _latMin;
  final int _nCols;
  final int _nRows;
  final int _indexOfs;
  final int _dataOfs;

  /// 数据覆盖范围（供 `covers()` 判断）。
  double get lonMin => _lonMin;
  double get latMin => _latMin;
  double get lonMax => _lonMin + _nCols * _cell;
  double get latMax => _latMin + _nRows * _cell;

  int _blocksRead = 0;
  int _bytesDecompressed = 0;
  int get blocksRead => _blocksRead;
  int get bytesDecompressed => _bytesDecompressed;

  /// 查询 bbox 内的建筑外环。
  ///
  /// 返回 `List<List<List<double>>>`：每个元素是一个环，
  /// 环内每个点是 `[lon, lat]` —— 与旧 `buildingsIn` 完全一致。
  List<List<List<double>>> query(
      double lonMin, double latMin, double lonMax, double latMax) {
    // 快速排除
    if (lonMax < this.lonMin || lonMin > this.lonMax) return const [];
    if (latMax < this.latMin || latMin > this.latMax) return const [];

    // 命中网格范围
    var ci0 = ((lonMin - _lonMin) / _cell).floor();
    var ci1 = ((lonMax - _lonMin) / _cell).floor();
    var cj0 = ((latMin - _latMin) / _cell).floor();
    var cj1 = ((latMax - _latMin) / _cell).floor();
    if (ci0 < 0) ci0 = 0;
    if (cj0 < 0) cj0 = 0;
    if (ci1 >= _nCols) ci1 = _nCols - 1;
    if (cj1 >= _nRows) cj1 = _nRows - 1;
    if (ci1 < ci0 || cj1 < cj0) return const [];

    final bd = ByteData.sublistView(_bytes);
    final out = <List<List<double>>>[];

    for (var cj = cj0; cj <= cj1; cj++) {
      for (var ci = ci0; ci <= ci1; ci++) {
        final idx = cj * _nCols + ci;
        final p = _indexOfs + idx * 16;
        final off = bd.getUint64(p, Endian.little);
        final compLen = bd.getUint32(p + 8, Endian.little);
        if (compLen == 0) continue;

        // 只解压这一块
        final start = _dataOfs + off;
        final chunk = Uint8List.sublistView(_bytes, start, start + compLen);
        _blocksRead++;
        final raw = gzip.decode(chunk);
        _bytesDecompressed += raw.length;

        // 该格原点
        final ox = _lonMin + ci * _cell;
        final oy = _latMin + cj * _cell;
        _decodeBlock(raw, ox, oy, lonMin, latMin, lonMax, latMax, out);
      }
    }
    return out;
  }

  /// 解一个块，只把**顶点落在框内**的环放进 [out]。
  ///
  /// 与旧实现同口径（`_ringInBox`：任一顶点在框内即保留），
  /// 保证换索引后导出结果与之前一致。
  static void _decodeBlock(
      List<int> raw,
      double ox,
      double oy,
      double lonMin,
      double latMin,
      double lonMax,
      double latMax,
      List<List<List<double>>> out) {
    final bd = ByteData.sublistView(
        raw is Uint8List ? raw : Uint8List.fromList(raw));
    var p = 0;
    final nRings = bd.getUint32(p, Endian.little);
    p += 4;
    for (var r = 0; r < nRings; r++) {
      final nPts = bd.getUint32(p, Endian.little);
      p += 4;
      final ring = <List<double>>[];
      var inBox = false;
      for (var k = 0; k < nPts; k++) {
        final lon = ox + bd.getFloat32(p, Endian.little);
        final lat = oy + bd.getFloat32(p + 4, Endian.little);
        p += 8;
        ring.add([lon, lat]);
        if (!inBox &&
            lon >= lonMin &&
            lon <= lonMax &&
            lat >= latMin &&
            lat <= latMax) {
          inBox = true;
        }
      }
      if (inBox && ring.length >= 3) out.add(ring);
    }
  }
}
