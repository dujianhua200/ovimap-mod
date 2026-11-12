import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'dialogs.dart';
import 'export_center.dart';
import 'route_tools.dart';

/// ⋯工具 面板：低频业务，分「成果与资料 / 专业工具」两组。
///
/// 杆路点表、杆路轨迹核查的实现在 `home_page`（其私有装配），
/// 通过回调注入，避免把大段 UI 逻辑外提。
Future<void> showToolsMenu(
  BuildContext context,
  AppState st, {
  required Future<void> Function() onPoleTable,
  required Future<void> Function() onTrackCheck,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: kPanelBg,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          sheetGroupTitle('成果与资料'),
          sheetTile(context, '导出成果（当前草稿 / 配线）',
              () => openExportCenter(context, st)),
          sheetTile(context, '导入 KML 到当前项目',
              () => showKmlImportDialog(context, st)),
          sheetTile(context, '杆路点表（定位/属性/查长度）', onPoleTable),
          sheetTile(context, '竣工资料一键成册（ZIP 交结算）',
              () => showArchiveBookDialog(context, st)),
          sheetGroupTitle('专业工具'),
          sheetTile(context, '采集设置（杆路自动编号）',
              () => showCollectionSettings(context, st)),
          sheetTile(context, '工程模板（架空/管道/箱体配线）',
              () => showTemplateDialog(context, st)),
          sheetTile(context, '杆路轨迹核查（查漏杆/错位）', onTrackCheck),
          sheetTile(context, '拓扑连线指引', () => showTopoGuide(context)),
        ],
      ),
    ),
  );
}
