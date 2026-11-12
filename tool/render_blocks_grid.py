"""逐块渲染：把每个图例块单独放到一张大图上，肉眼核对几何。

这样能区分两类问题：
  - 解析器把块读坏了（几何缺失/错位）；
  - 只是整图缩放小、看着像空框。
"""

import sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import ezdxf


def main(path, out_png, names):
    doc = ezdxf.readfile(path)
    n = len(names)
    cols = min(4, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols, figsize=(4 * cols, 4 * rows), dpi=110)
    axes = axes.flatten() if n > 1 else [axes]
    for ax, name in zip(axes, names):
        blk = doc.blocks.get(name)
        if blk is None:
            ax.set_title('%s MISSING' % name, color='red')
            continue
        count = 0
        for e in blk:
            t = e.dxftype()
            try:
                if t == 'LINE':
                    ax.plot([e.dxf.start.x, e.dxf.end.x],
                            [e.dxf.start.y, e.dxf.end.y], 'w-', lw=1.2)
                elif t == 'CIRCLE':
                    c = e.dxf.center
                    ax.add_patch(plt.Circle((c.x, c.y), e.dxf.radius,
                                            fill=False, color='w', lw=1.2))
                elif t == 'ARC':
                    c = e.dxf.center
                    th = range(int(e.dxf.start_angle), int(e.dxf.end_angle) + 1)
                    import numpy as np
                    ang = np.radians(list(th))
                    ax.plot(c.x + e.dxf.radius * np.cos(ang),
                            c.y + e.dxf.radius * np.sin(ang), 'w-', lw=1.2)
                elif t == 'POLYLINE':
                    pts = [(v.dxf.location.x, v.dxf.location.y) for v in e.vertices]
                    if e.is_closed:
                        pts.append(pts[0])
                    ax.plot([p[0] for p in pts], [p[1] for p in pts], 'w-', lw=1.2)
                elif t == 'TEXT':
                    p = e.dxf.insert
                    ax.text(p.x, p.y, e.dxf.text, color='#7fd', fontsize=8,
                            ha='center', va='center')
                count += 1
            except Exception as exc:  # noqa: BLE001
                ax.text(0.5, 0.5, 'ERR %s' % exc, transform=ax.transAxes,
                        color='r', fontsize=7)
        ax.set_aspect('equal')
        ax.set_title('%s (%d ents)' % (name, count), fontsize=9, color='#ddd')
        ax.grid(True, alpha=0.2)
        ax.set_facecolor('#101418')
    for ax in axes[n:]:
        ax.axis('off')
    fig.tight_layout()
    fig.savefig(out_png, dpi=110, facecolor='#101418')
    print('WROTE', out_png)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
