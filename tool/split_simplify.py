#!/usr/bin/env python3
"""把大 GeoJSON 简化 + 按网格分块，便于按片区导入手机。

简化策略：
  1) 坐标精度 6→5 位小数（≈1.1m，出图参照足够）
  2) 几何再简化（Douglas-Peucker，容差按米→度换算）
  3) 按网格切块（默认 0.05°≈5km），每块独立 GeoJSON
"""
import json
import math
import os
import sys
from collections import defaultdict

SRC = sys.argv[1] if len(sys.argv) > 1 else \
    '/Users/dujianhua200/Desktop/信阳矢量/浉河区_已下载部分.geojson'
OUTDIR = sys.argv[2] if len(sys.argv) > 2 else \
    '/Users/dujianhua200/Desktop/信阳矢量/分块/'
GRID = float(sys.argv[3]) if len(sys.argv) > 3 else 0.05   # 度
TOL_M = float(sys.argv[4]) if len(sys.argv) > 4 else 3.0   # 简化容差（米）

os.makedirs(OUTDIR, exist_ok=True)
LAT_M = 110540.0
LON_M = 111320.0


def simplify(pts, tol_deg):
    """Douglas-Peucker（迭代版，避免深递归）。"""
    if len(pts) <= 3:
        return pts
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        ax, ay = pts[i]
        bx, by = pts[j]
        dx, dy = bx - ax, by - ay
        norm = math.hypot(dx, dy)
        best, bi = -1.0, -1
        for k in range(i + 1, j):
            px, py = pts[k]
            if norm < 1e-12:
                d = math.hypot(px - ax, py - ay)
            else:
                d = abs(dy * px - dx * py + bx * ay - by * ax) / norm
            if d > best:
                best, bi = d, k
        if best > tol_deg and bi > 0:
            keep[bi] = True
            stack.append((i, bi))
            stack.append((bi, j))
    return [p for p, k in zip(pts, keep) if k]


def rnd(pt):
    return [round(pt[0], 5), round(pt[1], 5)]


def main():
    print(f'读取 {SRC} …', flush=True)
    d = json.load(open(SRC, encoding='utf-8'))
    feats = d['features']
    print(f'要素 {len(feats)}', flush=True)

    tol_lat = TOL_M / LAT_M
    buckets = defaultdict(list)
    kept_b = kept_r = dropped = 0

    for f in feats:
        g = f['geometry']
        kind = f['properties'].get('k', 'b')
        if kind == 'b':
            ring = g['coordinates'][0]
            lat0 = sum(p[1] for p in ring) / len(ring)
            tol = tol_lat
            s = simplify(ring, tol)
            if len(s) < 3:
                dropped += 1
                continue
            coords = [rnd(p) for p in s]
            if coords[0] != coords[-1]:
                coords.append(coords[0])
            geom = {'type': 'Polygon', 'coordinates': [coords]}
            cx = sum(p[0] for p in coords) / len(coords)
            cy = sum(p[1] for p in coords) / len(coords)
            kept_b += 1
        else:
            line = g['coordinates']
            tol = tol_lat
            s = simplify(line, tol)
            if len(s) < 2:
                dropped += 1
                continue
            coords = [rnd(p) for p in s]
            geom = {'type': 'LineString', 'coordinates': coords}
            cx = coords[len(coords) // 2][0]
            cy = coords[len(coords) // 2][1]
            kept_r += 1
        gx = int(cx // GRID)
        gy = int(cy // GRID)
        buckets[(gx, gy)].append({'type': 'Feature', 'geometry': geom,
                                  'properties': {'k': kind}})

    total_mb = 0
    print(f'分块数 {len(buckets)}，写出…', flush=True)
    for (gx, gy), fs in buckets.items():
        lon0 = gx * GRID
        lat0 = gy * GRID
        name = f'{lat0:.2f}_{lon0:.2f}.geojson'
        p = os.path.join(OUTDIR, name)
        json.dump({'type': 'FeatureCollection', 'features': fs},
                  open(p, 'w', encoding='utf-8'),
                  ensure_ascii=False, separators=(',', ':'))
        mb = os.path.getsize(p) / 1048576
        total_mb += mb

    print(f'简化后：建筑 {kept_b} / 道路 {kept_r} / 丢弃 {dropped}')
    print(f'分块 {len(buckets)} 个文件，合计 {total_mb:.1f} MB → {OUTDIR}')
    sizes = sorted(os.path.getsize(os.path.join(OUTDIR, f))
                   for f in os.listdir(OUTDIR))
    if sizes:
        print(f'单块体积：最小 {sizes[0]/1048576:.2f} MB  中位 {sizes[len(sizes)//2]/1048576:.2f} MB  最大 {sizes[-1]/1048576:.2f} MB')


if __name__ == '__main__':
    main()
