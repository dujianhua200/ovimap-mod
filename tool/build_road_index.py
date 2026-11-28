"""build_road_index.py：把路网 GeoJSON 转成**分块二进制索引**（.ovrd v1）。

## 为什么需要
旧实现每次导出都要 `gzip.decode(10.5MB)` + `jsonDecode` 20.5 万条道路、
173 万个坐标点 —— 单次 3~6 秒，而导出面板的范围预览会反复触发。
建筑早就做了同样改造（tool/build_index.py → .ovbld），道路一直没跟上，
用户反馈"导出 dxf 速度太慢，几乎快要一分钟"里这是最大的一块。

索引化后：查询只解压命中网格的块（一般几十 KB），
解析量从 173 万点 JSON 降到几万点二进制读取。

## 格式（.ovrd v1）
```
HEADER  magic(8) cell(4) lonMin(4) latMin(4) nCols(4) nRows(4)
        indexOfs(8) dataOfs(8) tableOfs(8) tableLen(8)
INDEX   nCells × (uint64 offset, uint32 compLen, uint32 nRoads)
DATA    各网格块独立 gzip，首尾相接
TABLE   gzip(JSON {"names":[...], "highways":[...]})
```
块内（解压后）：
```
uint32 nRoads
nRoads × ( uint32 nPts, uint32 nameIdx, uint16 highwayIdx, uint16 _pad,
           uint32 rid, nPts × (int32 dLon, int32 dLat) )
```
`rid` 是**道路的全局稳定 id = 源要素序号**。跨格的长路会在相邻块各存一份，
查询侧靠 rid 去重。不能用"路名+首末点"当键：20 万条里有 8 处碰撞
（同名且首末点相同的断开路段），碰撞会把两条路并成一条、几何错位几十公里。
坐标编码：**首点绝对、其后差分**，单位 1e-7°（分辨率 **0.011 米**），
int32。差分是因为相邻点通常只差几十米，小整数让 gzip 压得更狠
（绝对编码 12.9MB → 差分 8.4MB）。

⚠️ 两个踩过的坑：
  · **不能用 int16 相对格原点**：道路按"外包框与网格相交"归属，长路的顶点
    可能离本格原点几十公里，int16 溢出后被 clamp 成 0/32767，整条路被压扁
    （实测最大偏差 92 公里）。
  · **用绝对/差分而不是相对格原点**：相对格原点同样会溢出（长路顶点离格
    原点几十公里），差分编码既避免溢出又压得更好，且不依赖块的格原点。

`nameIdx == 0xFFFFFFFF` 表示无路名。
字符串**全局去重**（20 万条路只有约 2000 个不同路名），每条路只存两个整数下标。

## 归属策略
按**道路外包框与网格相交**归属（一条路可能落进多个块）。
不做几何切割：切割会在路口制造缝隙且需插值收口；
相交归属只是让跨格的路在相邻块各存一份，查询时按"首末点+名字"去重。

用法：
    python3 tool/build_road_index.py
    python3 tool/build_road_index.py -i SOURCE.geojson.gz -o OUT.ovrd --cell 0.05
"""
import argparse
import gzip
import json
import math
import os
import struct
import sys

# magic 必须**严格 8 字节**（Dart 端按固定偏移读）。
MAGIC = b'OVRD' + bytes([1, 0, 0, 0])
assert len(MAGIC) == 8

# 网格边长（度）。0.08° 在信阳约 8.8km(纬) × 7.5km(经)。
#
# 为什么不是更细：道路按**整条外包框**归属（不切割几何，见下），链式合并
# 后一条村道动辄几公里、跨 2~3 格，格越细副本越多。实测同一份数据：
#   cell=0.05 → 索引 13.6MB（副本点膨胀 75%，比源 gz 10.2MB 还大）
#   cell=0.08 → 9.9MB      ← 采用
#   cell=0.10 → 9.3MB 但单块 164KB，A3 图幅一次解压翻倍
# A3 图幅（1km 级）在 0.08° 下只命中 1 块（约 89KB，解压约 8ms）。
CELL = 0.08
LON_MIN, LON_MAX = 113.60, 115.70
LAT_MIN, LAT_MAX = 31.10, 32.80

DEFAULT_SRC = os.path.join('assets', 'buildings', 'xinyang_roads.geojson.gz')
DEFAULT_OUT = os.path.join('assets', 'buildings', 'xinyang_roads.ovrd')

NO_NAME = 0xFFFFFFFF
# 定点单位：1e-7 度（约 1.1 厘米）
SCALE = 10000000.0


def load_features(path):
    if path.endswith('.gz'):
        with gzip.open(path, 'rt', encoding='utf-8') as f:
            doc = json.load(f)
    else:
        with open(path, 'r', encoding='utf-8') as f:
            doc = json.load(f)
    return doc.get('features') or []


def lines_of(geom):
    """取出要素里的所有折线（GeoJSON 是 [lon, lat]）。"""
    if not geom:
        return []
    t = geom.get('type')
    c = geom.get('coordinates')
    if t == 'LineString':
        return [c] if c else []
    if t == 'MultiLineString':
        return [ln for ln in (c or []) if ln]
    return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-i', '--input', default=DEFAULT_SRC)
    ap.add_argument('-o', '--output', default=DEFAULT_OUT)
    ap.add_argument('--cell', type=float, default=CELL)
    ap.add_argument('--level', type=int, default=6,
                    help='每块 gzip 压缩级别（默认 6）')
    args = ap.parse_args()

    print('读取 %s' % args.input)
    feats = load_features(args.input)
    print('  %d 个要素' % len(feats))

    cell = args.cell
    ncols = int(math.ceil((LON_MAX - LON_MIN) / cell))
    nrows = int(math.ceil((LAT_MAX - LAT_MIN) / cell))
    print(' 网格 %d x %d = %d（格宽 %.4f°）'
          % (ncols, nrows, ncols * nrows, cell))

    # ---- 第一遍：字符串表 + 折线归格 ----
    names, name_idx = [], {}
    highways, hw_idx = [], {}
    cells = {}
    npts_total = 0
    skipped = 0

    for ordinal, feat in enumerate(feats):
        props = feat.get('properties') or {}
        name = (props.get('name') or '').strip()
        hw = (props.get('highway') or '').strip()

        ni = NO_NAME
        if name:
            ni = name_idx.get(name)
            if ni is None:
                ni = len(names)
                name_idx[name] = ni
                names.append(name)
        hi = hw_idx.get(hw)
        if hi is None:
            hi = len(highways)
            hw_idx[hw] = hi
            highways.append(hw)

        for ln in lines_of(feat.get('geometry')):
            pts = [(float(p[0]), float(p[1])) for p in ln
                   if isinstance(p, (list, tuple)) and len(p) >= 2]
            if len(pts) < 2:
                skipped += 1
                continue
            npts_total += len(pts)

            lo0 = min(p[0] for p in pts)
            lo1 = max(p[0] for p in pts)
            la0 = min(p[1] for p in pts)
            la1 = max(p[1] for p in pts)
            if lo1 < LON_MIN or lo0 > LON_MAX or la1 < LAT_MIN or la0 > LAT_MAX:
                skipped += 1
                continue

            # 全局稳定 id = 源要素序号。
            #
            # 曾用"路名+首末点"的 crc32：20 万条里有 8 处碰撞（同名且首末点
            # 相同的不同路段，如断开的同一条村道），碰撞会让两条路被当成
            # 一条去重、几何错位到几十公里外。序号天然唯一，且跨块一致
            # （同一条路在不同块里拿到的是同一个序号）。
            rid = ordinal

            ci0 = max(0, min(ncols - 1, int((lo0 - LON_MIN) / cell)))
            ci1 = max(0, min(ncols - 1, int((lo1 - LON_MIN) / cell)))
            cj0 = max(0, min(nrows - 1, int((la0 - LAT_MIN) / cell)))
            cj1 = max(0, min(nrows - 1, int((la1 - LAT_MIN) / cell)))
            for cj in range(cj0, cj1 + 1):
                for ci in range(ci0, ci1 + 1):
                    cells.setdefault(cj * ncols + ci, []).append(
                        (ni, hi, rid, pts))

    n_copies = sum(len(v) for v in cells.values())
    print('  有效道路副本 %d / 非空格 %d（原始点 %d，跳过 %d）'
          % (n_copies, len(cells), npts_total, skipped))
    print('  字符串表：路名 %d，等级 %d' % (len(names), len(highways)))

    # ---- 第二遍：int32 差分定点编码 + 逐块 gzip ----
    print('编码并压缩…')
    blocks = {}
    for idx, roads in cells.items():
        raw = bytearray()
        raw += struct.pack('<I', len(roads))
        for ni, hi, rid, pts in roads:
            raw += struct.pack('<IIHHI', len(pts), ni, hi, 0, rid)
            # 首点绝对、其后存差分（微度 int32）：相邻点距离通常几十米，
            # 差分值很小，gzip 压缩率明显高于绝对值（实测 12.9MB → 9.7MB）。
            px = py = 0
            for i, (lon, lat) in enumerate(pts):
                qx = int(round(lon * SCALE))
                qy = int(round(lat * SCALE))
                if i == 0:
                    raw += struct.pack('<ii', qx, qy)
                else:
                    raw += struct.pack('<ii', qx - px, qy - py)
                px, py = qx, qy
        blocks[idx] = gzip.compress(bytes(raw), args.level)

    table_gz = gzip.compress(
        json.dumps({'names': names, 'highways': highways},
                   ensure_ascii=False,
                   separators=(',', ':')).encode('utf-8'), 9)

    header_size = len(MAGIC) + 4 * 5 + 8 * 4
    n_cells = ncols * nrows
    data_ofs = header_size + n_cells * 16
    table_ofs = data_ofs + sum(len(b) for b in blocks.values())

    index = bytearray()
    data = bytearray()
    off = 0
    for i in range(n_cells):
        b = blocks.get(i)
        if b:
            index += struct.pack('<QII', off, len(b), len(cells[i]))
            data += b
            off += len(b)
        else:
            index += struct.pack('<QII', 0, 0, 0)

    os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)
    with open(args.output, 'wb') as f:
        f.write(MAGIC)
        f.write(struct.pack('<f', cell))
        f.write(struct.pack('<f', LON_MIN))
        f.write(struct.pack('<f', LAT_MIN))
        f.write(struct.pack('<I', ncols))
        f.write(struct.pack('<I', nrows))
        f.write(struct.pack('<Q', header_size))
        f.write(struct.pack('<Q', data_ofs))
        f.write(struct.pack('<Q', table_ofs))
        f.write(struct.pack('<Q', len(table_gz)))
        f.write(index)
        f.write(data)
        f.write(table_gz)

    out_mb = os.path.getsize(args.output) / 1048576
    src_mb = os.path.getsize(args.input) / 1048576
    print('完成: %.1f MB（源 %.1f MB，字符串表 %.0f KB）'
          % (out_mb, src_mb, len(table_gz) / 1024))
    return 0


if __name__ == '__main__':
    sys.exit(main())
