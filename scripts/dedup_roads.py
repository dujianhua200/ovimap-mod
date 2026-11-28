#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""高德矢量路网几何去重（v3.40）。

## 为什么需要

高德 z14 矢量瓦片按瓦片范围裁剪：一条跨瓦片边界的路，会同时出现在相邻两片里，
两片各自的裁剪位置不同，所以同一段路会得到**两套略有差异的顶点**——
端点相差中位 7.7 米、P90 31.8 米（实测 3418 对）。抓取阶段用
`edge_key`（首末点四舍五入到 1e-5°）去重，对这种差异无效，
于是导出到 DXF 里同一条马路画了两遍，看着"乱七八糟"。

## 做法

按优先级排序后**增量**建索引：优先保留 有路名 > 等级高（mainkey 小）> 更长 的那条，
每条路只在"已保留"的集合里找重合对象，命中即丢弃。这样

- 不会误删真正的并行路（双幅路、辅路间距通常 15m 以上，容差只有 8m）；
- 保留的那条一定是信息量最大的（路名不因去重丢失）；
- 增量索引避免了 20 万条全对全比较。

重合判据（两条路 a 与 b）：
1. 外包框相交（加容差）；
2. a 的采样点中 ≥ OVERLAP 比例落在 b 的顶点 TOL 米内，**且反向亦然**（双向覆盖，
   避免"一条长路吃掉一堆只挨着它的短支路"）。

## 用法

    python3 scripts/dedup_roads.py \
        -i data/amap_vec/xinyang_amap_vec.geojson \
        -o data/amap_vec/xinyang_amap_vec_dedup.geojson \
        --report /tmp/dedup_report.txt
"""
import argparse
import json
import math
import os
import sys
import time

# 重合容差（米）。8m 的依据：跨瓦片同一条路的顶点偏差中位 7.7m、P90 31.8m，
# 取 8m 能吃掉绝大多数重复；而双向车道/主辅路间距通常 ≥15m，不会被误合并。
TOL_M = 8.0
# 双向覆盖率门槛。低于这个值说明只是"部分重叠"（如同一路口的两条支路），不应丢弃。
OVERLAP = 0.80
# 采样步长（米）：稠密采样，避免长路只有两个端点、判据失效。
SAMPLE_STEP_M = 12.0
# 候选网格边长（度）。0.0005° ≈ 55m（纬度）/ 47m（信阳经度）。
CELL_DEG = 0.0005
# 每条路最多采样点数，防止个别超长路拖慢比较。
MAX_SAMPLES = 400

# 等级优先级：mainkey 越小越重要（20001 高速 … 20009 四级路）。
# 用于"两条重复路保谁"，不是绘图等级。
_KIND_RANK = {20001: 0, 20002: 1, 20003: 2, 20004: 3,
              20007: 4, 20008: 5, 20016: 5, 20009: 6, 20018: 7}


def _kilometers_per_degree(lat):
    return math.cos(math.radians(lat)) * 111320.0, 110540.0


def path_len_m(pts):
    if len(pts) < 2:
        return 0.0
    kx, ky = _kilometers_per_degree(pts[0][1])
    total = 0.0
    for i in range(len(pts) - 1):
        total += math.hypot((pts[i + 1][0] - pts[i][0]) * kx,
                            (pts[i + 1][1] - pts[i][1]) * ky)
    return total


def densify(pts, step=SAMPLE_STEP_M, cap=MAX_SAMPLES):
    """按固定米级步长重采样，返回用于比较的点列（含首末点）。"""
    if len(pts) < 2:
        return list(pts)
    kx, ky = _kilometers_per_degree(pts[0][1])
    total = path_len_m(pts)
    n = max(1, min(cap, int(total / step)))
    out = []
    # 沿折线等距取样
    seg_len = []
    for i in range(len(pts) - 1):
        seg_len.append(math.hypot((pts[i + 1][0] - pts[i][0]) * kx,
                                  (pts[i + 1][1] - pts[i][1]) * ky))
    acc = 0.0
    target = 0.0
    idx = 0
    for j in range(n + 1):
        target = total * j / n
        while idx < len(seg_len) - 1 and acc + seg_len[idx] < target:
            acc += seg_len[idx]
            idx += 1
        if seg_len[idx] <= 1e-9:
            out.append(pts[idx])
            continue
        t = (target - acc) / seg_len[idx]
        t = min(1.0, max(0.0, t))
        out.append((pts[idx][0] + (pts[idx + 1][0] - pts[idx][0]) * t,
                    pts[idx][1] + (pts[idx + 1][1] - pts[idx][1]) * t))
    return out


def bbox_of(pts):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def cell_of(lon, lat):
    return int(math.floor(lon / CELL_DEG)), int(math.floor(lat / CELL_DEG))


# ---------------------------------------------------------------------------
# 线段索引：把一条路的所有线段按 CELL_SEG 网格登记，
# 供"点到折线"距离查询。用点对点太苛刻——跨瓦片两份拷贝既然顶点不同，
# 沿路方向就有相位差，点对点会假性不重合（实测 8m/12m 采样时 0.79，
# 差一点没到门槛，而肉眼这明明是同一路）。
# ---------------------------------------------------------------------------
CELL_SEG = 0.0002   # ≈22m


class SegIndex:
    """单条路的线段网格索引（坐标单位为度，距离判定按米换算）。"""

    __slots__ = ('g', 'kx', 'ky')

    def __init__(self, pts):
        self.kx, self.ky = _kilometers_per_degree(pts[0][1])
        g = {}
        for i in range(len(pts) - 1):
            a = pts[i]
            b = pts[i + 1]
            x0, y0 = cell_of(a[0], a[1])
            x1, y1 = cell_of(b[0], b[1])
            if x1 < x0:
                x0, x1 = x1, x0
            if y1 < y0:
                y0, y1 = y1, y0
            # 长线段会跨很多格，逐格登记（跨格数受格边长限制，最坏几百格）
            for cx in range(x0, x1 + 1):
                for cy in range(y0, y1 + 1):
                    g.setdefault((cx, cy), []).append((a, b))
        self.g = g

    def distance_m(self, lon, lat, tol):
        """点到折线的最短距离；超过 tol 米直接返回 tol（不必精确）。"""
        cx, cy = cell_of(lon, lat)
        best = tol
        r = int(math.ceil(tol / (CELL_SEG * self.ky))) + 1
        kx, ky = self.kx, self.ky
        for gx in range(cx - r, cx + r + 1):
            for gy in range(cy - r, cy + r + 1):
                segs = self.g.get((gx, gy))
                if not segs:
                    continue
                for (ax, ay), (bx, by) in segs:
                    px = (lon - ax) * kx
                    py = (lat - ay) * ky
                    dx = (bx - ax) * kx
                    dy = (by - ay) * ky
                    dd = dx * dx + dy * dy
                    if dd <= 1e-12:
                        d = math.hypot(px, py)
                    else:
                        t = (px * dx + py * dy) / dd
                        if t < 0.0:
                            t = 0.0
                        elif t > 1.0:
                            t = 1.0
                        d = math.hypot(px - dx * t, py - dy * t)
                    if d < best:
                        best = d
                        if best <= 1e-9:
                            return 0.0
        return best


def covered_ratio(samples, seg_index, tol=TOL_M):
    """samples 中有多少比例落在 seg_index 表示的那条折线 tol 米内。

    注意判据是 **严格小于** tol：`distance_m` 在真实距离 >= tol 时
    返回的正是 tol（提前截断以提速），用 <= 会把"差得远"误当成"命中"。
    """
    hit = 0
    for lo, la in samples:
        if seg_index.distance_m(lo, la, tol) < tol:
            hit += 1
    return hit / len(samples) if samples else 0.0


def is_duplicate(a, b, sa, sb):
    """a/b 是否为同一条路的两份拷贝。sa/sb 是重采样点列。"""
    ax0, ay0, ax1, ay1 = a['bbox']
    bx0, by0, bx1, by1 = b['bbox']
    kx, ky = a['k']
    if bx0 > ax1 + TOL_M / kx or bx1 < ax0 - TOL_M / kx:
        return False
    if by0 > ay1 + TOL_M / ky or by1 < ay0 - TOL_M / ky:
        return False
    if a['segs'] is None:
        a['segs'] = SegIndex(a['verts'])
    if b['segs'] is None:
        b['segs'] = SegIndex(b['verts'])
    r1 = covered_ratio(sa, b['segs'])
    if r1 < OVERLAP:
        return False
    r2 = covered_ratio(sb, a['segs'])
    return r2 >= OVERLAP


def priority_key(feat, rec):
    """排序：有路名 > 等级高 > 更长。数值小的先处理（即保留）。"""
    props = feat.get('properties') or {}
    has_name = 0 if (props.get('name') or '').strip() else 1
    mk = props.get('amap_mainkey')
    kind = _KIND_RANK.get(mk, 9) if isinstance(mk, int) else 9
    return (has_name, kind, -rec['len'])


def main():
    global TOL_M, OVERLAP
    ap = argparse.ArgumentParser()
    ap.add_argument('-i', '--input', default='data/amap_vec/xinyang_amap_vec.geojson')
    ap.add_argument('-o', '--output', default='data/amap_vec/xinyang_amap_vec_dedup.geojson')
    ap.add_argument('--tol', type=float, default=TOL_M, help='重合容差（米），默认 8')
    ap.add_argument('--overlap', type=float, default=OVERLAP, help='双向覆盖率门槛，默认 0.80')
    ap.add_argument('--report', default='', help='把统计写到该文件')
    args = ap.parse_args()

    TOL_M = args.tol
    OVERLAP = args.overlap

    t0 = time.time()
    with open(args.input, encoding='utf-8') as f:
        src = json.load(f)
    feats = src['features']
    sys.stderr.write('读入 %d 条路\n' % len(feats))

    recs = []
    for i, f in enumerate(feats):
        g = f.get('geometry') or {}
        if g.get('type') != 'LineString':
            continue
        pts = g.get('coordinates') or []
        if len(pts) < 2:
            continue
        recs.append({
            'idx': i,
            'verts': pts,
            'bbox': bbox_of(pts),
            'len': path_len_m(pts),
            'k': _kilometers_per_degree(pts[0][1]),
            'samples': None,
            'segs': None,
        })
    sys.stderr.write('参与去重 %d 条（%.1fs）\n' % (len(recs), time.time() - t0))

    order = sorted(range(len(recs)), key=lambda j: priority_key(feats[recs[j]['idx']], recs[j]))

    grid = {}          # (cx,cy) -> [rec index]（只登记已保留的路）
    kept = []          # 保留的 rec 下标
    dropped = []       # (被丢的 rec 下标, 保留的 rec 下标)
    t1 = time.time()
    for n, j in enumerate(order):
        rec = recs[j]
        if rec['samples'] is None:
            rec['samples'] = densify(rec['verts'])
        # 候选：本路覆盖到的所有格子里的已保留路
        cand = set()
        for lo, la in rec['samples']:
            cx, cy = cell_of(lo, la)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    lst = grid.get((cx + dx, cy + dy))
                    if lst:
                        cand.update(lst)
        dup_of = None
        for c in cand:
            other = recs[c]
            if other['samples'] is None:
                other['samples'] = densify(other['verts'])
            if is_duplicate(rec, other, rec['samples'], other['samples']):
                dup_of = c
                break
        if dup_of is not None:
            dropped.append((j, dup_of))
            continue
        kept.append(j)
        for lo, la in rec['samples']:
            grid.setdefault(cell_of(lo, la), []).append(j)
        if (n + 1) % 20000 == 0:
            el = time.time() - t1
            sys.stderr.write('  %d/%d (%.0f%%) %.0fs 保留 %d 丢弃 %d\n'
                             % (n + 1, len(order), 100.0 * (n + 1) / len(order),
                                el, len(kept), len(dropped)))

    # 丢弃的若有路名而保留的没有，把名字补过去（去重不应丢信息）
    name_fix = 0
    for d, k in dropped:
        dp = feats[recs[d]['idx']].get('properties') or {}
        kp = feats[recs[k]['idx']].get('properties') or {}
        dn = (dp.get('name') or '').strip()
        if dn and not (kp.get('name') or '').strip():
            kp['name'] = dn
            name_fix += 1

    kept_idx = sorted(recs[j]['idx'] for j in kept)
    out_feats = [feats[i] for i in kept_idx]
    sys.stderr.write('保留 %d / 丢弃 %d / 补名 %d（耗时 %.0fs）\n'
                     % (len(out_feats), len(dropped), name_fix, time.time() - t0))

    src['features'] = out_feats
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    tmp = args.output + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(src, f, ensure_ascii=False)
    os.replace(tmp, args.output)

    kept_len = sum(recs[j]['len'] for j in kept)
    drop_len = sum(recs[j]['len'] for j in (d for d, _ in dropped))
    rep = [
        '输入 %d 条 / %.0f km' % (len(feats), sum(r['len'] for r in recs) / 1000.0),
        '输出 %d 条 / %.0f km' % (len(out_feats), kept_len / 1000.0),
        '丢弃 %d 条 / %.0f km（占 %.2f%% 长度）'
        % (len(dropped), drop_len / 1000.0, 100.0 * drop_len / max(1.0, kept_len + drop_len)),
        '补名 %d 条' % name_fix,
        '容差 %.1fm / 双向覆盖 >=%.2f / 采样 %.0fm' % (TOL_M, OVERLAP, SAMPLE_STEP_M),
    ]
    text = '\n'.join(rep)
    sys.stderr.write(text + '\n')
    if args.report:
        with open(args.report, 'w', encoding='utf-8') as f:
            f.write(text + '\n')


if __name__ == '__main__':
    main()
