/// 典型工程模板：预置默认符号与敷设方式，新建工程一键套用。
///
/// 模板只提供"默认值"，**不改变** [MapLabel] 既有字段语义：
/// 套用后仅影响此后新增点的 `segKind / segCable / slackM` 与当前符号，
/// 不回溯修改已有点。默认值可持久化（prefs 键 `tplId`）。
class ProjectTemplate {
  final String id;

  /// 模板显示名（架空光缆 / 管道光缆 / 箱体配线）。
  final String name;

  /// 默认符号 id（对应 [LabelType.id]）。
  final String defTypeId;

  /// 默认敷设方式：0=默认，1=架空，2=埋地，3=管道。
  final int defSegKind;

  /// 默认光缆型号（可空）。
  final String defSegCable;

  /// 默认接头盘留（米，0=不填）。
  final double defSlackM;

  const ProjectTemplate({
    required this.id,
    required this.name,
    required this.defTypeId,
    required this.defSegKind,
    this.defSegCable = '',
    this.defSlackM = 0,
  });

  /// 预置模板：架空光缆 / 管道光缆 / 箱体配线。
  static const List<ProjectTemplate> presets = [
    ProjectTemplate(
        id: 'aerial',
        name: '架空光缆',
        defTypeId: 'concrete',
        defSegKind: 1),
    ProjectTemplate(
        id: 'duct', name: '管道光缆', defTypeId: 'pipe', defSegKind: 3),
    ProjectTemplate(
        id: 'box', name: '箱体配线', defTypeId: 'fiberbox', defSegKind: 0),
  ];

  /// 按 id 查找预置模板；未命中返回 null。
  static ProjectTemplate? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final t in presets) {
      if (t.id == id) return t;
    }
    return null;
  }
}
