"""紧凑放大渲染 + 中文字体，确认图块几何与文字都对。"""

import sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager
import ezdxf
from ezdxf.addons.drawing import RenderContext, Frontend
from ezdxf.addons.drawing.matplotlib import MatplotlibBackend

# 注册系统里的中文字体（Windows: 宋体/微软雅黑），否则中文全是方框
for name in ('SimSun', 'Microsoft YaHei', 'SimHei', 'Noto Sans CJK SC'):
    try:
        font_manager.findfont(name, fallback_to_default=False)
        plt.rcParams['font.sans-serif'] = [name]
        plt.rcParams['font.family'] = 'sans-serif'
        print('font:', name)
        break
    except Exception:
        continue


def render(path, out_png, x0, x1, y0, y1, title=''):
    doc = ezdxf.readfile(path)
    msp = doc.modelspace()
    fig = plt.figure(figsize=(15, 11), dpi=130)
    ax = fig.add_axes([0.02, 0.02, 0.96, 0.94])
    ctx = RenderContext(doc)
    backend = MatplotlibBackend(ax)
    Frontend(ctx, backend).draw_layout(msp, finalize=False)
    ax.set_xlim(x0, x1)
    ax.set_ylim(y0, y1)
    ax.set_facecolor('#0d1117')
    ax.set_title(title, fontsize=10, color='#ddd')
    fig.savefig(out_png, dpi=130, facecolor='#0d1117')
    plt.close(fig)
    print('WROTE', out_png)


if __name__ == '__main__':
    render(sys.argv[1], sys.argv[2],
           *(float(v) for v in sys.argv[3:7]),
           sys.argv[7] if len(sys.argv) > 7 else '')
