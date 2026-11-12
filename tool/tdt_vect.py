#!/usr/bin/env python3
"""天地图矢量瓦片 → 矢量 GeoJSON（建筑面 / 道路线）。

原理：天地图 vec_w 瓦片是渲染后的栅格图，建筑=浅色填充+灰描边，
道路=白色带+彩色描边。按颜色分离 → 形态学修补 → 轮廓提取 → 经纬度转换。

用法：
  python tdt_vect.py <z> <x0> <y0> <x1> <y1> <out.geojson> [--survey]
    例：python tdt_vect.py 17 107069 53169 107072 53172 out.geojson
"""
import json
import math
import os
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import cv2
import numpy as np

KEY = '361a1ac3927595e13b295fa9cbb77974'
LAYER = 'vec'          # 矢量底图（含建筑/道路/绿地）
TILE = 256
CACHE = '/tmp/tdt_tiles'
os.makedirs(CACHE, exist_ok=True)


# ---------------- 瓦片下载 ----------------
def tile_url(z, x, y, layer=LAYER):
    return (f'https://t{((x + y) % 8)}.tianditu.gov.cn/{layer}_w/wmts?'
            f'SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER={layer}'
            f'&STYLE=default&TILEMATRIXSET=w&FORMAT=tiles'
            f'&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&tk={KEY}')


def fetch_tile(args):
    z, x, y, layer = args
    p = f'{CACHE}/{layer}_{z}_{x}_{y}.png'
    if os.path.exists(p) and os.path.getsize(p) > 100:
        return p, True
    for attempt in range(3):
        try:
            req = urllib.request.Request(tile_url(z, x, y, layer),
                                         headers={'User-Agent': 'ovimap-vect/1.0'})
            data = urllib.request.urlopen(req, timeout=20).read()
            if len(data) < 100:
                raise RuntimeError('tiny response')
            with open(p, 'wb') as f:
                f.write(data)
            return p, False
        except Exception:
            time.sleep(0.8 * (attempt + 1))
    return p, None


# ---------------- 坐标换算 ----------------
def px_to_lonlat(z, x, y, px, py):
    n = 2 ** z
    lon = (x + px / TILE) / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y + py / TILE) / n))))
    return lon, lat


# ---------------- 图像分析：判定各要素的颜色 ----------------
def classify_colors(img):
    """返回 (建筑填充色, 背景色, 描边灰, 道路白, 绿) 的参考值（按图内统计自适应）。"""
    pix = img.reshape(-1, 3).astype(np.int16)
    # 背景：出现最多的颜色
    vals, counts = np.unique(pix, axis=0, return_counts=True)
    bg = vals[counts.argmax()]
    return bg


def build_masks(img, bg):
    """构建建筑 / 道路 / 绿地 mask。"""
    a = img.astype(np.int16)
    # 与背景的距离
    dbg = np.abs(a - bg).sum(axis=2)
    is_bg = dbg <= 12                     # 背景（含轻微抗锯齿）

    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    mx = a.max(axis=2)
    mn = a.min(axis=2)
    sat = mx - mn                          # 饱和度（彩色的 sat 大）

    green = (g > r + 8) & (g > b + 8)                        # 绿地/水
    # 描边：灰（低饱和）且比背景暗
    dark_gray = (sat <= 14) & (mx < 243) & (~is_bg)
    # 道路：白色（高亮低饱和）
    white = (sat <= 12) & (mx >= 246)
    # 建筑填充：介于背景与白之间、略偏暖（r>=b），且非背景
    bldg_fill = (~is_bg) & (~white) & (~dark_gray) & (~green) & (sat <= 18)

    return {'bg': is_bg, 'green': green, 'edge': dark_gray, 'white': white,
            'fill': bldg_fill}


# ---------------- 矢量化 ----------------
def vectorize(img, z, x, y, min_area_px=14, simplify_px=0.9):
    """从单张天地图 vec 瓦片提取建筑多边形与道路线。

    实测定标（z=18 城区瓦片，65536 像素）：
      · 背景 238,244,245（占比 43%），建筑填充 243,250,249（20%），两者亮度仅差 4~7
        → 绝对阈值不可分，必须用"与背景的差异"（建筑 diff≈15）
      · 建筑描边 = 灰（低饱和、暗于背景）占比 10.9%
      · 道路 = **纯白**（R,G,B ≥ 246）占比 1.45% + 少量黄色描边（0.64%）

    故：**建筑 = 灰描边围合的内部连通域**；**道路 = 纯白区域骨架线**。
    """
    a = img.astype(np.int16)
    mx = a.max(axis=2); mn = a.min(axis=2)
    sat = mx - mn
    # 非建筑要素：绿色植被 + 蓝色水体（实测水体 B 通道明显高于 R，曾被误判为建筑）
    # ⚠️ cv2.imread 默认 BGR：ch0=Blue, ch1=Green, ch2=Red
    blue, grn, red = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    green = ((grn > blue + 8) & (grn > red + 8)) | \
            ((blue > red + 12) & (blue > grn + 4))   # 植被 | 水体

    # ---- 建筑：灰描边 → 围合区域 ----
    bg = classify_colors(img)
    diff = np.abs(a - bg).sum(axis=2)
    edge = ((sat <= 22) & (diff > 20) & (mx < 244) & (~green)).astype(np.uint8)
    edge = cv2.morphologyEx(edge, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    edge = cv2.dilate(edge, np.ones((2, 2), np.uint8), iterations=1)  # 加粗，确保闭合成环

    inv = (edge == 0).astype(np.uint8)
    inv = cv2.morphologyEx(inv, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))
    n, lab = cv2.connectedComponents(inv, connectivity=4)
    h, w = inv.shape
    border = set(lab[0, :].tolist()) | set(lab[-1, :].tolist()) | \
             set(lab[:, 0].tolist()) | set(lab[:, -1].tolist())

    buildings = []
    for i in range(1, n):
        if i in border:
            continue                       # 与边界连通 = 外部背景，不是建筑
        m = (lab == i).astype(np.uint8)
        area = int(m.sum())
        if area < min_area_px:
            continue                        # 太小：文字笔画/碎屑
        x_, y_, w_, h_ = cv2.boundingRect(m)
        if w_ >= w - 2 or h_ >= h - 2:
            continue
        # 太小或极度狭长 → 噪声
        if max(w_, h_) < 4:
            continue
        if max(w_, h_) / float(max(1, min(w_, h_))) > 12:
            continue
        cnts, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        if not cnts:
            continue
        c = max(cnts, key=cv2.contourArea)
        ap = cv2.approxPolyDP(c, simplify_px, True)
        if len(ap) < 3 or len(ap) > 80:
            continue
        ring = [px_to_lonlat(z, x, y, float(p[0][0]), float(p[0][1])) for p in ap]
        buildings.append(ring)

    # ---- 补充：描边过浅而漏掉的建筑（用"填充色差异"+连通域再提一轮）----
    fg = ((diff > 9) & (~green)).astype(np.uint8)
    # 排除已提取建筑（含其描边，稍微膨胀以去重）
    done = np.zeros_like(fg)
    for i in range(1, n):
        if i in border:
            continue
        m = (lab == i).astype(np.uint8)
        if m.sum() >= min_area_px:
            done |= m
    done = cv2.dilate(done, np.ones((5, 5), np.uint8), iterations=1)
    white_all = ((mx >= 246) & (sat <= 14) & (~green)).astype(np.uint8)
    rest = (fg & (~done) & (~white_all)).astype(np.uint8)
    rest = cv2.morphologyEx(rest, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))
    sep2 = cv2.erode(rest, np.ones((2, 2), np.uint8), iterations=1)
    n2, lab2, st2, _ = cv2.connectedComponentsWithStats(sep2, 8)
    for i in range(1, n2):
        area = int(st2[i, cv2.CC_STAT_AREA])
        if area < min_area_px:
            continue
        bw = int(st2[i, cv2.CC_STAT_WIDTH]); bh = int(st2[i, cv2.CC_STAT_HEIGHT])
        if bw >= w - 2 or bh >= h - 2 or max(bw, bh) < 4:
            continue
        fr = area / float(bw * bh + 1e-6)
        if fr < 0.35:                      # 形状不规整 → 文字/碎屑
            continue
        if max(bw, bh) / float(max(1, min(bw, bh))) > 12:
            continue
        m = (lab2 == i).astype(np.uint8)
        m = cv2.dilate(m, np.ones((2, 2), np.uint8), iterations=1)
        cnts2, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        if not cnts2:
            continue
        c2 = max(cnts2, key=cv2.contourArea)
        ap2 = cv2.approxPolyDP(c2, simplify_px, True)
        if len(ap2) < 3 or len(ap2) > 80:
            continue
        buildings.append([px_to_lonlat(z, x, y, float(p[0][0]), float(p[0][1])) for p in ap2])

    # ---- 道路：纯白 → 骨架线 ----
    white = ((mx >= 246) & (sat <= 14) & (~green)).astype(np.uint8)
    white = cv2.morphologyEx(white, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    roads = []
    if white.sum() > 0:
        try:
            thin = cv2.ximgproc.thinning(white * 255)
        except Exception:
            thin = white * 255
        if thin is not None and thin.max() > 0:
            rc, _ = cv2.findContours((thin > 0).astype(np.uint8),
                                     cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
            for c in rc:
                if len(c) < 6:
                    continue
                pts = [px_to_lonlat(z, x, y, float(p[0][0]), float(p[0][1])) for p in c]
                roads.append(pts)

    return buildings, roads


# ---------------- 主流程 ----------------
def main():
    z = int(sys.argv[1]); x0 = int(sys.argv[2]); y0 = int(sys.argv[3])
    x1 = int(sys.argv[4]); y1 = int(sys.argv[5]); out = sys.argv[6]
    survey = '--survey' in sys.argv

    tiles = [(z, x, y, LAYER) for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)]
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(fetch_tile, tiles))
    ok = sum(1 for _, cached in results if cached is not None)
    print(f'下载/缓存 {len(tiles)} 张瓦片，可用 {ok}，耗时 {time.time()-t0:.1f}s', flush=True)

    feats = []
    nb = nr = 0
    for (zz, xx, yy, _), (path, cached) in zip(tiles, results):
        if cached is None or not os.path.exists(path):
            continue
        img = cv2.imread(path, cv2.IMREAD_COLOR)
        if img is None:
            continue
        b, r = vectorize(img, zz, xx, yy)
        for ring in b:
            feats.append({'type': 'Feature',
                          'geometry': {'type': 'Polygon', 'coordinates': [ring]},
                          'properties': {'kind': 'building'}})
            nb += 1
        for line in r:
            feats.append({'type': 'Feature',
                          'geometry': {'type': 'LineString', 'coordinates': line},
                          'properties': {'kind': 'road'}})
            nr += 1
    with open(out, 'w', encoding='utf-8') as f:
        json.dump({'type': 'FeatureCollection', 'features': feats}, f,
                  ensure_ascii=False, separators=(',', ':'))
    mb = os.path.getsize(out) / 1048576
    print(f'建筑 {nb} / 道路 {nr}  →  {out}  ({mb:.2f} MB)  总耗时 {time.time()-t0:.1f}s')
    if survey:
        # 单瓦片要素数分布，用于估算全域
        print(f'  单瓦片均值：建筑 {nb/len(tiles):.1f} 道路 {nr/len(tiles):.1f}')


if __name__ == '__main__':
    main()
