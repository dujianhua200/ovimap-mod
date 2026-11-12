#!/usr/bin/env python3
"""信阳全域 · 天地图矢量化（分县输出 GeoJSON）。

按区县逐个处理：下载 z=17 瓦片 → 矢量化建筑/道路 → 输出 GeoJSON。
支持断点续跑（瓦片与结果均缓存）。

用法：python xy_all.py [县名...]        不传=全部
"""
import json
import math
import os
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, ProcessPoolExecutor

import cv2
import numpy as np

sys.path.insert(0, '/tmp')
from tdt_vect import vectorize, px_to_lonlat, tile_url

KEY = '361a1ac3927595e13b295fa9cbb77974'
Z = 17
TILE_CACHE = '/tmp/tdt_tiles'
OUT_DIR = '/Users/dujianhua200/Desktop/信阳矢量/'
os.makedirs(TILE_CACHE, exist_ok=True)
os.makedirs(OUT_DIR, exist_ok=True)

# 信阳 2 区 8 县（bbox = lat0, lon0, lat1, lon1）
COUNTIES = {
    '浉河区': (31.85, 113.85, 32.35, 114.20),
    '平桥区': (32.00, 113.95, 32.50, 114.45),
    '罗山县': (31.75, 114.15, 32.25, 114.65),
    '光山县': (31.75, 114.35, 32.25, 115.10),
    '新县':   (31.35, 114.55, 31.90, 115.25),
    '商城县': (31.35, 115.15, 31.95, 115.80),
    '固始县': (31.85, 115.35, 32.65, 116.05),
    '潢川县': (32.00, 114.85, 32.50, 115.50),
    '淮滨县': (32.25, 115.00, 32.70, 115.70),
    '息县':   (32.15, 114.30, 32.70, 115.10),
}


def tile_xy(z, lat, lon):
    n = 2 ** z
    x = int((lon + 180) / 360 * n)
    y = int((1 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat)))
             / math.pi) / 2 * n)
    return x, y


def tile_range(z, bbox):
    lat0, lon0, lat1, lon1 = bbox
    x0, y1 = tile_xy(z, lat0, lon0)
    x1, y0 = tile_xy(z, lat1, lon1)
    return x0, x1, y0, y1


def fetch(args):
    z, x, y = args
    p = f'{TILE_CACHE}/vec_{z}_{x}_{y}.png'
    if os.path.exists(p) and os.path.getsize(p) > 100:
        return True
    for a in range(3):
        try:
            req = urllib.request.Request(tile_url(z, x, y),
                                         headers={'User-Agent': 'ovimap-vect/1.0'})
            d = urllib.request.urlopen(req, timeout=20).read()
            if len(d) < 100:
                raise RuntimeError('tiny')
            with open(p, 'wb') as f:
                f.write(d)
            return True
        except Exception:
            time.sleep(0.5 * (a + 1))
    return False


def process_tile(args):
    z, x, y = args
    p = f'{TILE_CACHE}/vec_{z}_{x}_{y}.png'
    if not (os.path.exists(p) and os.path.getsize(p) > 100):
        return [], []
    img = cv2.imread(p, cv2.IMREAD_COLOR)
    if img is None:
        return [], []
    try:
        return vectorize(img, z, x, y)
    except Exception:
        return [], []


def run_county(name, bbox, workers=12):
    out = f'{OUT_DIR}{name}.geojson'
    if os.path.exists(out):
        print(f'[跳过] {name} 已存在 {os.path.getsize(out)/1048576:.1f}MB', flush=True)
        return
    x0, x1, y0, y1 = tile_range(Z, bbox)
    tiles = [(Z, x, y) for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)]
    t0 = time.time()
    print(f'[{name}] {len(tiles)} 张瓦片，开始下载…', flush=True)
    ok = 0
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for i, r in enumerate(ex.map(fetch, tiles)):
            if r:
                ok += 1
            if (i + 1) % 2000 == 0:
                el = time.time() - t0
                print(f'  下载 {i+1}/{len(tiles)}  成功{ok}  {el:.0f}s '
                      f'(预计还需 {el/(i+1)*(len(tiles)-i-1):.0f}s)', flush=True)
    print(f'[{name}] 下载完成 {ok}/{len(tiles)}，{time.time()-t0:.0f}s。开始矢量化…', flush=True)

    feats = []
    nb = nr = 0
    with ProcessPoolExecutor(max_workers=8) as ex:
        for i, (bs, rs) in enumerate(ex.map(process_tile, tiles, chunksize=64)):
            for ring in bs:
                feats.append({'type': 'Feature',
                              'geometry': {'type': 'Polygon', 'coordinates': [ring]},
                              'properties': {'k': 'b'}})
                nb += 1
            for line in rs:
                feats.append({'type': 'Feature',
                              'geometry': {'type': 'LineString', 'coordinates': line},
                              'properties': {'k': 'r'}})
                nr += 1
            if (i + 1) % 5000 == 0:
                print(f'  矢量化 {i+1}/{len(tiles)}  建筑{nb} 道路{nr}', flush=True)

    with open(out, 'w', encoding='utf-8') as f:
        json.dump({'type': 'FeatureCollection', 'features': feats}, f,
                  ensure_ascii=False, separators=(',', ':'))
    print(f'[{name}] ✓ 完成：建筑 {nb} / 道路 {nr} → {out} '
          f'({os.path.getsize(out)/1048576:.1f} MB) 总耗时 {time.time()-t0:.0f}s', flush=True)


if __name__ == '__main__':
    names = sys.argv[1:] or list(COUNTIES.keys())
    # 小县先跑，快速出结果
    for n in names:
        run_county(n, COUNTIES[n])
