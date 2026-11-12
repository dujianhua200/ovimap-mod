import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../geo/geo_util.dart';
import '../state/app_state.dart';
import '../sync/sync_controller.dart';
import 'dialogs.dart';
import 'sync/sync_panel.dart';
import 'design_tokens.dart';

/// ⚙设置 面板：低频维护项集中收纳
/// （地图 / 同步 / 存储 / 采集 / 高级 / 关于）。
///
/// 离线下载、存储清理依赖 `home_page` 的地图控制器与瓦片 provider，
/// 通过回调注入。
Future<void> showSettingsMenu(
  BuildContext context,
  AppState st, {
  required Future<void> Function() onOffline,
  required Future<void> Function() onStorageCleanup,
}) {
  // 同步编排器以可空方式取得（未接入同步 → 面板退化为本地模式）。
  final sync = context.read<SyncController?>();
  return showModalBottomSheet(
    context: context,
    backgroundColor: kPanelBg,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          sheetGroupTitle('地图'),
          sheetTile(context, '坐标格式：${GeoUtil.fmtName(st.coordFmt)}',
              () => st.setCoordFmt(st.coordFmt + 1)),
          sheetTile(context, '图源 / 图层', () => showSourceDialog(context, st)),
          sheetTile(context, '天地图 Key 设置',
              () => showTiandituKeyDialog(context, st)),
          sheetTile(context, '高德 Key 设置（搜索/地名优先）',
              () => showAmapKeyDialog(context, st)),
          sheetTile(context, 'Overpass 端点（底图数据源）',
              () => showOverpassEndpointsDialog(context, st)),
          sheetTile(context, '离线地图（出行前预下载）', onOffline),
          sheetGroupTitle('云同步'),
          sheetTile(
              context,
              '同步面板（状态 / 立即同步）',
              () => showSyncPanel(context, sync, st)),
          sheetTile(
              context, '同步设置（令牌 / 服务器 / 设备名）',
              () => showSyncSettingsDialog(context, sync)),
          sheetGroupTitle('存储'),
          sheetTile(context, '存储清理（图源缓存 + 未引用照片）', onStorageCleanup),
          sheetGroupTitle('采集'),
          sheetTile(context, '杆路自动编号',
              () => showCollectionSettings(context, st)),
          sheetGroupTitle('高级'),
          sheetTile(context, '恢复出厂地图设置（二次确认）',
              () => _confirmReset(context, st)),
          sheetGroupTitle('关于'),
          sheetTile(context, '坐标系说明', () => showDatumHelp(context, st)),
          sheetTile(context, '关于 滑洲云图', () => showAbout(context)),
        ],
      ),
    ),
  );
}

/// 恢复出厂地图设置：危险且一次性，加二次确认。
Future<void> _confirmReset(BuildContext context, AppState st) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kPanelBg,
      title: const Text('恢复出厂地图设置？',
          style: TextStyle(color: kTextMain, fontSize: 16)),
      content: const Text('将把坐标格式、图源、注记层恢复为默认；不影响已保存的收藏与草稿。',
          style: TextStyle(color: kTextMain, fontSize: 13)),
      actions: [
        darkTextBtn('取消', () => Navigator.pop(ctx, false), color: kTextSub),
        darkTextBtn('恢复', () {
          st.resetMapSettings();
          Navigator.pop(ctx, true);
        }, color: TokC.danger),
      ],
    ),
  );
  if (ok == true && context.mounted) toast(context, '已恢复出厂地图设置');
}
