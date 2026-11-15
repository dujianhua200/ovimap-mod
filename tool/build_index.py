"""build_index.py v3：分块 + 每块独立 gzip。

## 关键设计
先前两版的问题：
  v1 float64 → 155 MB（太大）
  v2 float32 → 81 MB（仍比 gz 56.9 MB 大）

v3：**每个网格块单独 gzip**。查询时只解压命中的那几个块
（一般 1~25 块，每块几十 KB），解压量从 57MB 降到几百 KB。

格式（.ovbld v3）：
  HEADER   magic(8) cell(4) lonMin(4) latMin(4) nCols(4) nRows(4)
           indexOfs(8) dataOfs(8)
  INDEX    nCells × (uint64 offset, uint32 compLen, uint32 rawLen)
  DATA     各块 gzip 流首尾相接

块内（解压后）：
  uint32 nRings
  nRings × ( uint32 nPts, nPts × (float32 dLon, float32 dLat) )
  坐标是相对该格左下角的偏移。
"""
import gzip
import json
import math
import os
import struct

SRC = r'C:\work\ovimap\assets\buildings\xinyang.geojson.gz'
OUT = r'C:\work\ovimap\assets\buildings\xinyang.ovbld'

CELL = 0.02
LON_MIN, LON_MAX = 113.60, 115.70
LAT_MIN, LAT_MAX = 31.10, 32.80
# magic 必须**严格 8 字节**（Dart 端按固定偏移读）。
# 踩过的坑：
#   · b'OVBLD\x03\x01\x00\x00' → 字面量里 \x00 被后续字符吞掉，只有 7 字节
#   · b'OVBLD' 是 5 字节（不是 4！）→ 加 4 字节版本变成 9 字节
# 正确：4 字节标识 + 4 字节版本 = 8。
MAGIC = b'OVBL' + bytes([3, 1, 0, 0])
assert len(MAGIC) == 8, 'magic 必须 8 字节，实际 %d' % len(MAGIC)


def main():
    print('读取', SRC)
    with gzip.open(SRC, 'rt', encoding='utf-8') as f:
        feats = json.load(f).get('features', [])
    print('  %d 个要素' % len(feats))

    ncols = int(math.ceil((LON_MAX - LON_MIN) / CELL))
    nrows = int(math.ceil((LAT_MAX - LAT_MIN) / CELL))
    print(' 网格 %d x %d = %d' % (ncols, nrows, ncols * nrows))

    cells = {}
    for feat in feats:
        g = feat.get('geometry') or {}
        t = g.get('type')
        c = g.get('coordinates')
        if t == 'Polygon':
            polys = [c] if c else []
        elif t == 'MultiPolygon':
            polys = c if c else []
        else:
            continue
        for poly in polys:
            if not poly:
                continue
            ring = poly[0]
            if len(ring) < 4:
                continue
            lon = sum(p[0] for p in ring) / len(ring)
            lat = sum(p[1] for p in ring) / len(ring)
            if not (LON_MIN <= lon <= LON_MAX and LAT_MIN <= lat <= LAT_MAX):
                continue
            ci = min(max(int((lon - LON_MIN) / CELL), 0), ncols - 1)
            cj = min(max(int((lat - LAT_MIN) / CELL), 0), nrows - 1)
            cells.setdefault(cj * ncols + ci, []).append(ring)

    nrings = sum(len(v) for v in cells.values())
    print('  有效环 %d / 非空格 %d' % (nrings, len(cells)))

    # 编码 + 逐块 gzip
    print('编码并压缩…')
    blocks = {}
    for idx, rings in cells.items():
        cj, ci = divmod(idx, ncols)
        ox = LON_MIN + ci * CELL
        oy = LAT_MIN + cj * CELL
        raw = bytearray()
        raw += struct.pack('<I', len(rings))
        for ring in rings:
            raw += struct.pack('<I', len(ring))
            for p in ring:
                raw += struct.pack('<ff', p[0] - ox, p[1] - oy)
        blocks[idx] = gzip.compress(bytes(raw), 6)

    header_size = len(MAGIC) + 4 * 5 + 8 * 2
    n_cells = ncols * nrows
    index_size = n_cells * 16
    data_ofs = header_size + index_size

    index = bytearray()
    data = bytearray()
    off = 0
    for i in range(n_cells):
        b = blocks.get(i)
        if b:
            raw_len = struct.unpack('<I', gzip.decompress(b)[:4])[0]
            index += struct.pack('<QII', off, len(b), raw_len)
            data += b
            off += len(b)
        else:
            index += struct.pack('<QII', 0, 0, 0)

    with open(OUT, 'wb') as f:
        f.write(MAGIC)
        f.write(struct.pack('<f', CELL))
        f.write(struct.pack('<f', LON_MIN))
        f.write(struct.pack('<f', LAT_MIN))
        f.write(struct.pack('<I', ncols))
        f.write(struct.pack('<I', nrows))
        f.write(struct.pack('<Q', header_size))
        f.write(struct.pack('<Q', data_ofs))
        f.write(index)
        f.write(data)

    print('完成: %.1f MB（geojson.gz %.1f MB）'
          % (os.path.getsize(OUT) / 1048576,
             os.path.getsize(SRC) / 1048576))


if __name__ == '__main__':
    main()
