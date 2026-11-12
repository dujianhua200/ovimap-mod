/// DXF 版本枚举与 HEADER `$ACADVER` 取值。
///
/// - [DxfVersion.r12]   → `AC1009`（R12，**默认**；极广兼容）。仅支持 ACI 色 `62`
///   与线型 `6`，多段线为经典 `POLYLINE/VERTEX/SEQEND`，建筑填充为 `SOLID` 三角近似；
///   无 `370/420/LWPOLYLINE/HATCH`。已用 ezdxf 严格打开验证通过。
/// - [DxfVersion.r2000] → `AC1015`（R2000，可选；支持图层线宽 `370`、真彩 `420`、
///   `LWPOLYLINE`、`HATCH`）。
///
/// ⚠️ **历史教训（务必保留）**：曾把「R12 结构的文件贴上 `AC1015` 标签」直接产出，
/// 文件本身非法——不同 CAD 容错程度不同，于是用户「碰运气能打开」，被强行打开时
/// CAD 会静默丢弃解析不了的实体（建筑填充 HATCH 首当其冲），表现为「经常打开失败 /
/// 没有建筑轮廓」。**R2000 不是换个版本号，而是必须补齐 R2000 必需结构**：
/// `$HANDSEED` + 每个实体句柄（组码 `5`）+ `100 AcDb*` 子类标记 + `OBJECTS` 段 +
/// `CLASSES` 段 + TABLES/BLOCKS 记录句柄。本仓库的 R2000 分支已按此补齐，
/// 并由 `DxfStructureValidator` 与 `tool/validate_dxf.py`（ezdxf 严格打开）双重把关。
enum DxfVersion { r12, r2000 }

/// 版本 → HEADER `$ACADVER` 字符串。
String acadVerOf(DxfVersion v) => switch (v) {
      DxfVersion.r12 => 'AC1009',
      DxfVersion.r2000 => 'AC1015',
    };
