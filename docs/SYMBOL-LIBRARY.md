# 图例库接入（lispblock.dxf）：设计与实现说明

> 面向：接手这套代码的人 / 下一轮改符号的人。
> 一句话：**软件导出 DXF 时，符号直接用用户 CAD 图例里的原始图块**，
> 不再用"椭圆 / 矩形 / 三角 + 文字"去近似。

---

## 1. 用户诉求 → 实现口径

| 用户原话 | 实现 |
|---|---|
| "名字就是图块的名字，比如 新建水泥杆" | `LabelType.name` 取图例里紧邻该块的**文字**（`ENTITIES` 段 TEXT/MTEXT） |
| "图标ID就是图块的编号，比如 gl001" | `LabelType.id` = DXF 的**块名**（`BLOCKS` 段 `BLOCK` 的组码 2） |
| "把 DXF 文件直接打包到软件里面" | 资产 `assets/dxf/lispblock.dxf`，登记在 `pubspec.yaml` |
| "软件导出 DXF 文件的时候调用 lispblock.dxf 里面的图例" | 导出时按需写出 `BLOCK` 定义 + `INSERT` 引用，见 §4 |

---

## 2. 为什么不能"直接抄块定义"

用户的 `lispblock.dxf` 是 **AC1021（2007）** 保存的，里面大量使用：

```
LWPOLYLINE / HATCH / SPLINE / ELLIPSE / MTEXT / REGION
```

而本项目默认导出 **R12（AC1009）**。R12 根本没有这些实体类型——
把 2007 的实体表原样抄进 R12 文件，就是"结构贴上 R12 标签"的非法文件，
AutoCAD 会**静默丢弃**解析不了的实体（这正是本项目历史上栽过的坑）。

所以中间必须有一层**归一化（降维）**：

| 源实体 | 归一化为 | 说明 |
|---|---|---|
| `LWPOLYLINE` + 凸度 `42` | `POLYLINE` 折线（凸度段采样成圆弧） | **必须展开凸度**，见 §3.1 |
| `HATCH` | 边界折线（**不导出填充**） | R12 无 HATCH；边界足够表达轮廓 |
| `SPLINE` | de Boor 求值 → 折线 | 退化为控制多边形也比画不出来强 |
| `ELLIPSE` | 参数采样 → 折线 | |
| `ARC / CIRCLE` | 原样保留 | R12 认得 |
| `MTEXT / ATTDEF` | 单行 `TEXT`（洗掉 `\fSimSun;` `\P` `{}` `%%c`） | |
| 嵌套 `INSERT` | 递归内联（含基点/缩放/旋转/平移） | 带循环引用保护 |

归一化后**只剩 R12 也认识的实体**，两个版本共用同一份几何。

---

## 3. 解析器踩过的三个真坑（回归测试已锁定）

### 3.1 凸度（bulge）不展开 → 圆变成一条横线

`gl001`（新建水泥杆）在源文件里是：

```
LWPOLYLINE  90=2  70=1
  10 -1.575   20 0.0   42 1.0      ← 顶点 1，凸度 1.0
  10  1.575   20 0.0   42 1.0      ← 顶点 2，凸度 1.0
```

**两个顶点 + bulge=1.0 = 上下两个半圆 = 整圆**。
只取 `10/20`（忽略 `42`）就得到一条直径直线——"新建水泥杆"变成一根横杠。

> 回归：`test/lispblock_symbols_test.dart` →「LWPOLYLINE 凸度必须展开成圆弧」

### 3.2 HATCH 边界吃到种子点 → 边界多一条斜杠

`HATCH` 里 `10/20` 出现三次语义：

1. HATCH **头部**：图案基点；
2. **边界顶点**（真正的轮廓）；
3. **尾部种子点**（`98` 之后，填充的"生长点"）。

`tags[10]` 一把抓会把 1 和 3 都当顶点。必须先过 `91`（路径数），
再按 `93`（顶点数）读，遇到 `97/98/91` 就停。

> 回归：`test/lispblock_symbols_test.dart` →「HATCH 边界不能吃到种子点」

### 3.3 CRLF → 整份文件解析出 0 个块

`text.split('\n')` 在 CRLF 文件上会给每个值留下尾部 `\r`，
于是 `'SECTION\r' != 'SECTION'`，扫描器直接空转返回 0 个块（**静默失败**，
最难查）。`_toPairs` 必须 `replaceAll('\r','')`。

> 回归：`test/lispblock_symbols_test.dart` →「CRLF 文件也要能解析」

---

## 4. 导出链路

```
labels ──► 收集用到的块编号（usedCatalogBlocks）
              │
              ▼
        _appendBlocksSection()
          ├─ 内置近似块（HZ_OVAL / HZ_BOX / HZ_TRI / HZ_POLE）
          └─ _appendCatalogBlocks()  ← 只为**用到的**图例块写 BLOCK
                 · 块名 = 块编号（gl001）
                 · 基点 = 块几何中心（组码 10/20）
                 · 几何 = 归一化图元 - 中心
              ▼
        ENTITIES 段：INSERT 块编号（缩放进图比例）
              ▼
        图例栏（TuQian 层）：同样 INSERT 真块
```

**只写用到的块**：整份图例 89 个块、近 2 万行，全部塞进去会让每个 DXF
平白变大且难读。实测 5 个点的图：7.9KB（R12）/ 14.8KB（R2000）。

**块名即编号**：图纸拿到 CAD 里 explode、重新插块，仍是用户那套符号体系。

---

## 5. 验收（不是"字符串自证"）

| 手段 | 位置 | 验的是什么 |
|---|---|---|
| Dart 结构校验器 | `lib/export/dxf_validate.dart` | 段序/实体自洽/R12 禁项 |
| **ezdxf 严格打开** | `tool/validate_lispblock.py` | 第三方引擎能否真读 |
| 逐块渲染成 PNG | `tool/render_blocks_grid.py` | 几何**长得对不对**（肉眼） |
| 整表渲染 | `tool/render_dxf_png.py` | 版式/图例/图纸整体 |
| 单测 | `test/lispblock_symbols_test.dart`（14 例） | 解析/目录/导出口径 |
| UI 单测 | `test/lispblock_ui_test.dart`（5 例） | 资源包装载 + 符号库可选可画 |

实测结果：

```
lispblock_r12.dxf    ver=AC1009  blocks=9  inserts={HZ_BOX:1, gl001:3, gx005_x:2, lx001:2}  OK
lispblock_r2000.dxf  ver=AC1015  blocks=9  inserts={HZ_BOX:1, gl001:3, gx005_x:2, lx001:2}  OK
catalog_sheet.dxf    ver=AC1009  blocks=86 inserts=80（全量符号对照表）              OK
```

---

## 6. 怎么换图例

1. 用新的 `lispblock.dxf` 覆盖 `assets/dxf/lispblock.dxf`；
2. `flutter pub get`（资源清单会重算）；
3. 重新构建。

**不用改代码**。解析器认的是 DXF 结构，不是某个固定块名。
若新图例里块的排布方式变了（比如名字在符号右侧而非左侧），
只需调 `dxf_block_parser.dart` 的 `_readLegend` 配对规则。

---

## 7. 已知边界

- **R12 无填充**：图例块里的 HATCH 只留边界，不还原实心填充。
  要实心效果需导出 R2000（`DxfVersion.r2000` 分支已支持 HATCH 结构，
  但符号几何仍走归一化——这是刻意的：一套几何两版本共用，避免漂移）。
- **ATTDEF（属性定义）不导出**：属性块（如 `TK_A1_001` 图框）在符号场景
  没有意义，跳过。
- **非等比缩放**：块内圆在非等比插入时退化为折线椭圆（R12 无 ELLIPSE）。
- **符号库只收点符号**：`maxSide > 60mm`（标题栏）或长条（`接图符号` 56.8×2.5）
  不进符号库——它们是图纸元素，不是点符号。
