#!/usr/bin/env python3
"""把高德矢量路网 GeoJSON 简化后打包进 assets。

输入 data/amap_vec/xinyang_amap_vec.geojson（全量，约 21 万条 / 83MB）
输出 assets/buildings/xinyang_roads.geojson.gz（简化 + 确定性 gzip）

简化用 Douglas-Peucker，容差按米算（经纬度按当地纬度换算）。
1.5m 容差约保留 78% 的点、压缩后约 11MB；对 CAD 出图（最小线宽 0.15mm、
1:500 出图即 7.5cm 实距）来说远小于可见误差，而体积只有全量的 80%。
"""
import argparse
import gzip
import io
import json
import math

DEFAULT_INPUT = 'data/amap_vec/xinyang_amap_vec.geojson'
DEFAULT_OUTPUT = 'assets/buildings/xinyang_roads.geojson.gz'


def simplify(pts, tol):
    """Douglas-Peucker（迭代实现，避免深递归）。tol 单位米。"""
    if tol <= 0 or len(pts) <= 2:
        return pts
    k = math.cos(math.radians(pts[0][1])) * 111320.0
    ax_all = [p[0] * k for p in pts]
    ay_all = [p[1] * 110540.0 for p in pts]
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        ax, ay = ax_all[a], ay_all[a]
        bx, by = ax_all[b], ay_all[b]
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        best, bi = -1.0, -1
        for i in range(a + 1, b):
            px, py = ax_all[i], ay_all[i]
            if l2 == 0.0:
                d = math.hypot(px - ax, py - ay)
            else:
                t = ((px - ax) * dx + (py - ay) * dy) / l2
                t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
                d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if d > best:
                best, bi = d, i
        if best > tol:
            keep[bi] = True
            stack.append((a, bi))
            stack.append((bi, b))
    return [p for p, v in zip(pts, keep) if v]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-i', '--input', default=DEFAULT_INPUT)
    ap.add_argument('-o', '--output', default=DEFAULT_OUTPUT)
    ap.add_argument('--tol', type=float, default=1.5, help='简化容差（米），0 表示不简化')
    ap.add_argument('--keep-props', default='highway,name,source,amap_mainkey')
    args = ap.parse_args()

    with open(args.input, encoding='utf-8') as fh:
        src = json.load(fh)
    keep_props = [p for p in args.keep_props.split(',') if p]
    out = []
    n_in = n_out = 0
    for feat in src['features']:
        geom = feat.get('geometry') or {}
        if geom.get('type') != 'LineString':
            continue
        pts = [tuple(p) for p in geom['coordinates']]
        n_in += len(pts)
        pts = simplify(pts, args.tol)
        n_out += len(pts)
        if len(pts) < 2:
            continue
        props = {k: feat['properties'][k] for k in keep_props
                 if k in feat.get('properties', {})}
        out.append({
            'type': 'Feature',
            'properties': props,
            'geometry': {'type': 'LineString',
                         'coordinates': [[round(a, 6), round(b, 6)] for a, b in pts]},
        })

    body = json.dumps({'type': 'FeatureCollection', 'features': out},
                      ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    buf = io.BytesIO()
    with gzip.GzipFile(filename='', fileobj=buf, mode='wb', compresslevel=9, mtime=0) as g:
        g.write(body)
    packed = buf.getvalue()
    with open(args.output, 'wb') as fh:
        fh.write(packed)
    print('输入 %s' % args.input)
    print('输出 %s' % args.output)
    print('要素 %d  点 %d→%d（%.0f%%） 原始 %.1fMB  gz %.1fMB'
          % (len(out), n_in, n_out, 100.0 * n_out / max(1, n_in),
             len(body) / 1e6, len(packed) / 1e6))


if __name__ == '__main__':
    main()
