/// 路网的**分块二进制索引**读取器（v3.39）。
///
/// ## 为什么需要
/// 旧实现（`xinyang_roads.geojson.gz`）每次导出都要
/// `gzip.decode(10.5MB)` + `jsonDecode` 20.5 万条道路、173 万个坐标，
/// 实测单次 3~6 秒；而导出面板改档位/重算会反复触发。
/// 建筑早已索引化（见 [BuildingIndex]），道路一直没跟上 ——
/// 用户反馈"导出 dxf 速度太慢，几乎快要一分钟"里这是最大一块。
///
/// 索引化后：只解压**命中网格的块**（A3 图幅 1 块约 9KB），
/// 解析量从 173 万点降到几千点。
///
/// ## 格式（.ovrd v1，由 `tool/build_road_index.py` 生成）
/// ```
/// HEADER  magic(8) cell(4) lonMin(4) latMin(4) nCols(4) nRows(4)
///         indexOfs(8) dataOfs(8) tableOfs(8) tableLen(8)
/// INDEX   nCells × (uint64 offset, uint32 compLen, uint32 nRoads)
/// DATA    各网格块独立 gzip，首尾相接
/// TABLE   gzip(JSON {"names":[...], "highways":[...]})
/// ```
/// 块内（解压后）：
/// ```
/// uint32 nRoads
/// nRoads × ( uint32 nPts, uint32 nameIdx, uint16 highwayIdx, uint16 _pad,
///            uint32 rid, nPts × (int32 dLon, int32 dLat) )
/// ```
/// 坐标编码：**首点绝对、其后差分**，单位 1e-7°（分辨率 0.011 米），int32。
/// 差分是因为相邻点通常只差几十米，小整数让 gzip 压得更狠
/// （绝对编码 12.9MB → 差分 9.7MB）。**不相对格原点**：道路按外包框归属，
/// 长路顶点可能离格原点几十公里，相对或 int16 编码会溢出把路压扁
/// （实测最大偏差 92 公里）。
/// `nameIdx == 0xFFFFFFFF` 表示无路名。
/// `rid` 是道路的全局稳定 id = **源要素序号**。跨格的长路在相邻块各存一份，
/// 查询侧必须靠 rid 去重。不能用"路名+首末点"当键：20 万条里有 8 处碰撞
/// （同名且首末点相同的断开路段），碰撞会把两条路并成一条、几何错位几十公里。
library;

import 'dart:convert' show jsonDecode, utf8;
import 'dart:io' show gzip;
import 'dart:typed_data';

/// 索引里读出一条道路。
///
/// `pts` 用项目的内部顺序 **[lat, lon]**（与旧 `BundledRoad` 一致，
/// 避免调用方再翻一次坐标）。
class IndexedRoad {
  final List<List<double>> pts;
  final String name;
  final String highway;

  /// 道路的全局稳定 id（源要素序号，跨块一致）。
  final int rid;
  const IndexedRoad(this.pts, this.name, this.highway, this.rid);
}

/// 分块路网索引。构造后零拷贝持有整块字节，按需解压。
class RoadIndex {
  RoadIndex._(
    this._bytes,
    this._cell,
    this._lonMin,
    this._latMin,
    this._nCols,
    this._nRows,
    this._indexOfs,
    this._dataOfs,
  );

  /// 解析文件头并读字符串表。格式不对返回 null（调用方回退 GeoJSON 路径）。
  static RoadIndex? parse(Uint8List bytes) {
    // HEADER = 8(magic) + 4*5 + 8*4 = 60 字节
    if (bytes.length < 60) return null;
    if (bytes[0] != 0x4F || bytes[1] != 0x56 ||
        bytes[2] != 0x52 || bytes[3] != 0x44) {
      return null; // 不是 "OVRD"
    }
    final bd = ByteData.sublistView(bytes);
    final cell = bd.getFloat32(8, Endian.little);
    final lonMin = bd.getFloat32(12, Endian.little);
    final latMin = bd.getFloat32(16, Endian.little);
    final nCols = bd.getUint32(20, Endian.little);
    final nRows = bd.getUint32(24, Endian.little);
    final indexOfs = bd.getUint64(28, Endian.little);
    final dataOfs = bd.getUint64(36, Endian.little);
    final tableOfs = bd.getUint64(44, Endian.little);
    final tableLen = bd.getUint64(52, Endian.little);
    if (cell <= 0 || nCols == 0 || nRows == 0) return null;
    if (indexOfs + nCols * nRows * 16 > bytes.length) return null;
    if (dataOfs > bytes.length) return null;
    if (tableLen > 0 && tableOfs + tableLen > bytes.length) return null;

    List<String> names = const [];
    List<String> highways = const [];
    if (tableLen > 0) {
      try {
        final chunk =
            Uint8List.sublistView(bytes, tableOfs, tableOfs + tableLen);
        final t = jsonDecode(utf8.decode(gzip.decode(chunk)));
        if (t is Map) {
          final n = t['names'];
          final h = t['highways'];
          if (n is List) names = [for (final e in n) '$e'];
          if (h is List) highways = [for (final e in h) '$e'];
        }
      } catch (_) {
        return null;
      }
    }

    final idx = RoadIndex._(
        bytes, cell, lonMin, latMin, nCols, nRows, indexOfs, dataOfs);
    idx._names = names;
    idx._highways = highways;
    return idx;
  }

  final Uint8List _bytes;
  final double _cell;
  final double _lonMin;
  final double _latMin;
  final int _nCols;
  final int _nRows;
  final int _indexOfs;
  final int _dataOfs;

  /// 定点单位：整数 ÷ 1e7 = 度
  static const double _microDeg = 10000000.0;

  List<String> _names = const [];
  List<String> _highways = const [];

  /// 数据覆盖范围（供 `covers()` 判断）。
  double get lonMin => _lonMin;
  double get latMin => _latMin;
  double get lonMax => _lonMin + _nCols * _cell;
  double get latMax => _latMin + _nRows * _cell;

  /// 索引里登记的路名数量（不是道路条数）。
  int get nameCount => _names.length;

  /// 统计量（诊断用）。
  int _blocksRead = 0;
  int _bytesDecompressed = 0;
  int get blocksRead => _blocksRead;
  int get bytesDecompressed => _bytesDecompressed;

  /// 解压块缓存：同一次导出会对同一 bbox 反复查询（预览/换算），
  /// 缓存解压结果避免重复 inflate。只保留最近若干块，防止内存增长。
  final Map<int, Uint8List> _blockCache = {};
  static const int _cacheLimit = 64;

  Uint8List _block(int cellIdx) {
    final hit = _blockCache[cellIdx];
    if (hit != null) return hit;

    final bd = ByteData.sublistView(_bytes);
    final p = _indexOfs + cellIdx * 16;
    final off = bd.getUint64(p, Endian.little);
    final compLen = bd.getUint32(p + 8, Endian.little);
    if (compLen == 0) return Uint8List(0);

    final start = _dataOfs + off;
    final chunk = Uint8List.sublistView(_bytes, start, start + compLen);
    _blocksRead++;
    final raw = gzip.decode(chunk);
    _bytesDecompressed += raw.length;
    final u = raw is Uint8List ? raw : Uint8List.fromList(raw);

    if (_blockCache.length >= _cacheLimit) _blockCache.clear();
    _blockCache[cellIdx] = u;
    return u;
  }

  /// 查询 bbox 内的道路。
  ///
  /// 返回 [lat, lon] 顺序的 `IndexedRoad`。跨格重复的道路已按
  /// [IndexedRoad.rid] 去重，结果里每条路只出现一次。
  ///
  /// `hasData` 为 false 时返回空表（该片确实没有内置路网）。
  List<IndexedRoad> query(
      double lonMin, double latMin, double lonMax, double latMax) {
    if (lonMax < this.lonMin || lonMin > this.lonMax) return const [];
    if (latMax < this.latMin || latMin > this.latMax) return const [];

    var ci0 = ((lonMin - _lonMin) / _cell).floor();
    var ci1 = ((lonMax - _lonMin) / _cell).floor();
    var cj0 = ((latMin - _latMin) / _cell).floor();
    var cj1 = ((latMax - _latMin) / _cell).floor();
    if (ci0 < 0) ci0 = 0;
    if (cj0 < 0) cj0 = 0;
    if (ci1 >= _nCols) ci1 = _nCols - 1;
    if (cj1 >= _nRows) cj1 = _nRows - 1;
    if (ci1 < ci0 || cj1 < cj0) return const [];

    final out = <IndexedRoad>[];
    final seen = <int>{};

    for (var cj = cj0; cj <= cj1; cj++) {
      for (var ci = ci0; ci <= ci1; ci++) {
        final idx = cj * _nCols + ci;
        final raw = _block(idx);
        if (raw.isEmpty) continue;
        _decodeBlock(raw, lonMin, latMin, lonMax, latMax, out, seen);
      }
    }
    return out;
  }

  /// 解一个块，只保留**与查询框相交**的道路。
  ///
  /// 相交判据用整条线的外包框（不是"任一顶点在框内"）：
  /// 路网是线，跨框的长路整条顶点都在框外但线本身穿过框，
  /// 用顶点判据会漏掉（正是"道路不连续"的一类根因）。
  void _decodeBlock(
    Uint8List raw,
    double lonMin,
    double latMin,
    double lonMax,
    double latMax,
    List<IndexedRoad> out,
    Set<int> seen,
  ) {
    final bd = ByteData.sublistView(raw);
    var p = 0;
    final nRoads = bd.getUint32(p, Endian.little);
    p += 4;

    for (var r = 0; r < nRoads; r++) {
      final nPts = bd.getUint32(p, Endian.little);
      final nameIdx = bd.getUint32(p + 4, Endian.little);
      final hwIdx = bd.getUint16(p + 8, Endian.little);
      final rid = bd.getUint32(p + 12, Endian.little);
      p += 16;
      if (nPts == 0) continue;
      if (p + nPts * 8 > raw.length) break; // 数据损坏，停止该块（每点 8 字节）

      final pts = <List<double>>[];
      var rlMin = double.infinity, rlMax = -double.infinity;
      var raMin = double.infinity, raMax = -double.infinity;
      // 首点绝对、其后差分；单位 1e-7 度
      var qx = 0, qy = 0;
      for (var i = 0; i < nPts; i++) {
        final dx = bd.getInt32(p, Endian.little);
        final dy = bd.getInt32(p + 4, Endian.little);
        p += 8;
        if (i == 0) {
          qx = dx;
          qy = dy;
        } else {
          qx += dx;
          qy += dy;
        }
        final lon = qx / _microDeg;
        final lat = qy / _microDeg;
        pts.add([lat, lon]);
        if (lon < rlMin) rlMin = lon;
        if (lon > rlMax) rlMax = lon;
        if (lat < raMin) raMin = lat;
        if (lat > raMax) raMax = lat;
      }

      // 外包框相交判定（线要素，不能用顶点判定）
      if (rlMax < lonMin || rlMin > lonMax) continue;
      if (raMax < latMin || raMin > latMax) continue;
      if (pts.length < 2) continue;

      final name = nameIdx < _names.length ? _names[nameIdx] : '';
      final hw = hwIdx < _highways.length ? _highways[hwIdx] : '';
      if (!seen.add(rid)) continue;
      out.add(IndexedRoad(pts, name, hw, rid));
    }
  }
}
