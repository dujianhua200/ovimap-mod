/// 图层规范表（T1）：集中定义 DXf 图层的名称 / ACI 色 / 真彩色 / 线宽 / 线型。
///
/// 关键约束：
/// - `lineWeight`（1/100mm，组码 `370`）与 `trueColor`（24bit 真彩，组码 `420`）
///   **仅在 R2000 写出**；R12 只写 `62`(ACI) + `6`(线型)，否则老读取器会拒。
/// - `business == true` 为业务/图框层（行为保持不变）；底图图层见 [basemap]。
class DxfLayerSpec {
  /// 图层名（写入组码 `2`）。
  final String name;

  /// ACI 索引色（组码 `62`），R12 与 R2000 均写。
  final int aci;

  /// 24bit 真彩色（组码 `420`），仅 R2000 写；null 表示不写。
  final int? trueColor;

  /// 线宽，单位 1/100mm（组码 `370`），仅 R2000 写；-3 表示默认。
  final int lineWeight;

  /// 线型（组码 `6`）。
  final String lineType;

  /// 是否业务/图框层（true）还是底图参照层（false）。
  final bool business;

  const DxfLayerSpec({
    required this.name,
    required this.aci,
    this.trueColor,
    this.lineWeight = -3,
    this.lineType = 'CONTINUOUS',
    this.business = false,
  });

  /// 返回替换 ACI 色后的副本（竣工图杆路/管廊改红）。
  DxfLayerSpec withAci(int newAci) => DxfLayerSpec(
        name: name,
        aci: newAci,
        trueColor: trueColor,
        lineWeight: lineWeight,
        lineType: lineType,
        business: business,
      );
}

/// 全量图层规范 + 底图图层集合。
class DxfLayers {
  DxfLayers._();

  /// 真彩色常量（24bit RGB）。
  static const int cGanLu = 0xFFC000; // 琥珀
  static const int cGuanLang = 0x00B0F0; // 青蓝
  static const int cPeiXianTu = 0x000000; // 黑
  static const int cZhuangHao = 0xFF00FF; // 品红
  static const int cBiaoQian = 0xFFFF00; // 黄
  static const int cJuLi = 0x000000; // 黑
  static const int cFrame = 0x000000; // 黑
  static const int cDaoLuBian = 0xC8C8C8; // 浅灰（道路双线描边）
  static const int cDaoLuZhong = 0x7F8C8D; // 灰（道路中心线，实体色另覆盖）
  static const int cDaoLu = 0x595959; // 深灰（道路名注记）
  static const int cJianZhu = 0xB0B0B0; // 浅灰（建筑轮廓）
  static const int cDianLi = 0x2A62E8; // 蓝偏紫（电力线：醒目、不与杆路混淆）
  static const int cShuiXi = 0xC4823B; // 土黄蓝（水系沟渠）
  static const int cJianZhuFill = 0xEFEFEF; // 更浅灰（建筑填充）
  static const int cDiMing = 0x2E7D32; // 绿（地名）

  /// 图层规范表（顺序即写出顺序）。
  static const List<DxfLayerSpec> all = <DxfLayerSpec>[
    // —— 业务层（既有，行为不变）——
    DxfLayerSpec(
        name: 'GanLu',
        aci: 3,
        trueColor: cGanLu,
        lineWeight: 35,
        business: true),
    DxfLayerSpec(
        name: 'GuanLang',
        aci: 5,
        trueColor: cGuanLang,
        lineWeight: 50,
        business: true),
    DxfLayerSpec(
        name: 'PeiXianTu',
        aci: 7,
        trueColor: cPeiXianTu,
        lineWeight: 30,
        business: true),
    DxfLayerSpec(
        name: 'ZhuangHao',
        aci: 6,
        trueColor: cZhuangHao,
        lineWeight: 18,
        business: true),
    DxfLayerSpec(
        name: 'BiaoQian',
        aci: 2,
        trueColor: cBiaoQian,
        lineWeight: 18,
        business: true),
    DxfLayerSpec(
        name: 'JuLi',
        aci: 7,
        trueColor: cJuLi,
        lineWeight: 18,
        business: true),
    // —— 图框层 ——
    DxfLayerSpec(
        name: 'BeiFangZhen',
        aci: 7,
        trueColor: cFrame,
        lineWeight: 35,
        business: true),
    DxfLayerSpec(
        name: 'TuQian',
        aci: 7,
        trueColor: cFrame,
        lineWeight: 35,
        business: true),
    // —— 底图层（本次新增 / 调整）——
    DxfLayerSpec(
        name: 'DaoLuBian',
        aci: 250,
        trueColor: cDaoLuBian,
        lineWeight: 20),
    DxfLayerSpec(
        name: 'DaoLuZhong',
        aci: 8,
        trueColor: cDaoLuZhong,
        lineWeight: 15),
    DxfLayerSpec(name: 'DaoLu', aci: 7, trueColor: cDaoLu, lineWeight: 18),
    DxfLayerSpec(name: 'JianZhu', aci: 8, trueColor: cJianZhu, lineWeight: 13),
    DxfLayerSpec(
        name: 'JianZhuFill',
        aci: 252,
        trueColor: cJianZhuFill,
        lineWeight: -3),
    DxfLayerSpec(name: 'DiMing', aci: 3, trueColor: cDiMing, lineWeight: 18),
  ];

  /// 底图参照层集合（供图层细分开关与渲染分流）。
  static const Set<String> basemap = <String>{
    'DaoLuBian',
    'DaoLuZhong',
    'DaoLu',
    'JianZhu',
    'JianZhuFill',
    'DiMing',
  };

  /// 业务/图框层图层名（既有层，行为不变）。
  static List<String> businessNames() =>
      all.where((e) => e.business).map((e) => e.name).toList();

  /// 底图图层名。
  static List<String> basemapNames() =>
      all.where((e) => !e.business).map((e) => e.name).toList();

  /// 按需应用竣工红（杆路/管廊 ACI 改 1）后的图层列表。
  static List<DxfLayerSpec> resolve({bool completionRed = false}) {
    if (!completionRed) return all;
    return [
      for (final s in all)
        if (s.name == 'GanLu' || s.name == 'GuanLang')
          s.withAci(1)
        else
          s,
    ];
  }

  /// 单层查询（找不到返回 null）。
  static DxfLayerSpec? byName(String name) {
    for (final s in all) {
      if (s.name == name) return s;
    }
    return null;
  }
}
