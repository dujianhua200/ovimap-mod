"""把导出的 DXF 渲染成 PNG，肉眼确认图例库图块真的画出来了。

ezdxf 的 addons.drawing 用 matplotlib 后端渲染，不依赖 AutoCAD。
"""

import sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import ezdxf
from ezdxf.addons.drawing import RenderContext, Frontend
from ezdxf.addons.drawing.matplotlib import MatplotlibBackend


def render(path, out_png, title):
    doc = ezdxf.readfile(path)
    msp = doc.modelspace()
    fig = plt.figure(figsize=(16, 10), dpi=110)
    ax = fig.add_axes([0, 0, 1, 1])
    ctx = RenderContext(doc)
    backend = MatplotlibBackend(ax)
    Frontend(ctx, backend).draw_layout(msp, finalize=True)
    ax.set_title(title, fontsize=9)
    fig.savefig(out_png, dpi=110)
    plt.close(fig)
    print('WROTE', out_png)


if __name__ == '__main__':
    render(sys.argv[1], sys.argv[2],
           sys.argv[3] if len(sys.argv) > 3 else '')
