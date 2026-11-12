import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../geo/geo_util.dart';
import '../../state/app_state.dart';
import '../../sync/sync_controller.dart';
import '../../sync/sync_models.dart';
import '../dialogs.dart';
import '../../ui/design_tokens.dart';

/// 桌面底部状态栏（架构文档 §3.2 / T11 / T17，高度 26）。
///
/// 左起：设备名 · 同步状态 · 最后同步时间 · **鼠标经纬度** · 视图中心 · 图源 ·
/// 缩放 · 选中数；最右端固定显示坐标系。
///
/// 字段口径对齐奥维互动地图桌面版：奥维状态栏就是「鼠标指针处经纬度 + 当前地图
/// 显示级别 + 当前坐标系」。本栏把「鼠标处」与「视图中心」两个字段分列，
/// 因为出图时两者用途不同 —— 前者用来读点，后者用来核对构图。
///
/// 同步区取自 [SyncController]（可为 null：未接入同步 → 「本地模式」）。
class StatusBar extends StatelessWidget {
  const StatusBar({
    super.key,
    required this.st,
    required this.centerText,
    required this.zoom,
    required this.selectedCount,
    this.mouseGeo,
    this.sync,
  });

  final AppState st;
  final String centerText;
  final double zoom;
  final int selectedCount;

  /// 鼠标所在经纬度（WGS-84）。鼠标移出地图或尚未进入时为 null。
  ///
  /// 用 [ValueListenableBuilder] 局部监听而非整壳 `setState`：悬停回调在鼠标
  /// 移动时每帧触发，若走本组件的入参（父级 setState）会把地图一起重建，
  /// 直接拖垮滚轮缩放与拖拽平移的手感。
  final ValueNotifier<LatLng?>? mouseGeo;

  /// 云同步编排器（可为 null）。
  final SyncController? sync;

  static final String _device = _resolveDevice();

  static String _resolveDevice() {
    try {
      final env = Platform.environment;
      final n = env['COMPUTERNAME'] ?? env['HOSTNAME'] ?? env['USERNAME'];
      if (n != null && n.trim().isNotEmpty) return n.trim();
    } catch (_) {}
    return '本机';
  }

  /// 把 WGS-84 悬停点换算成当前显示基准并格式化（与「视图中心」同一口径）。
  String _mouseText(LatLng? g) {
    if (g == null) return '—';
    final d = st.toDisplay(g.latitude, g.longitude);
    return GeoUtil.formatCoord(d[0], d[1], st.coordFmt);
  }

  @override
  Widget build(BuildContext context) {
    final sc = sync;
    // 全部取自可空快照（无 `?? throw` getter），未接入同步时退化为「本地模式」。
    final configured = sc?.configured ?? false;
    final status = sc?.aggregateStatus;
    final statusText =
        configured ? (status?.label ?? '仅本地') : '本地模式';
    final statusIcon = configured
        ? (status == SyncStatus.synced
            ? Icons.cloud_done_outlined
            : status == SyncStatus.conflict
                ? Icons.cloud_off
                : Icons.cloud_upload_outlined)
        : Icons.cloud_off;
    final statusColor = configured ? Color(status?.argb ?? 0xFF9E9E9E) : kTextSub;
    final syncTime = configured ? (sc?.lastSyncText ?? '—') : '—';
    final device = configured && (sc?.deviceName.isNotEmpty ?? false)
        ? sc!.deviceName
        : _device;

    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: TokC.toolbar,
        border: Border(top: BorderSide(color: TokC.divider)),
      ),
      // 窄窗口下字段会排不下（实测 776px 宽就溢出 79px，在 1024 最小宽度附近
      // 一旦选中点变多、同步态变长同样会溢出）。故左侧信息区做成**横向可滚动**、
      // 坐标系钉在右端常显 —— 比整栏裁剪（信息直接消失）和硬挤（文字压成一团）都稳。
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // 反向：让滚动条停在起点，字段顺序与阅读顺序一致。
              reverse: false,
              child: Row(
                children: [
                  _item(Icons.computer, device),
                  _divider(),
                  _item(statusIcon, statusText, color: statusColor),
                  _item(null, '最后同步：$syncTime'),
                  if (configured && (sc?.pendingCount ?? 0) > 0) ...[
                    _divider(),
                    _item(Icons.cloud_upload_outlined, '待上传 ${sc!.pendingCount}',
                        color: TokC.warn),
                  ],
                  _divider(),
                  // 鼠标处经纬度（奥维口径）：鼠标未进入地图时显示「—」。
                  if (mouseGeo != null)
                    ValueListenableBuilder<LatLng?>(
                      valueListenable: mouseGeo!,
                      builder: (ctx, g, _) =>
                          _item(Icons.mouse_outlined, '鼠标 ${_mouseText(g)}'),
                    )
                  else
                    _item(Icons.mouse_outlined, '鼠标 —'),
                  _divider(),
                  _item(Icons.my_location, '中心 $centerText'),
                  _divider(),
                  _item(Icons.layers_outlined, st.curSource.name),
                  _divider(),
                  _item(null, '缩放 ${zoom.toStringAsFixed(1)}'),
                  if (selectedCount > 0) ...[
                    _divider(),
                    _item(Icons.check_circle_outline, '已选 $selectedCount 点',
                        color: kAccent),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text('坐标系 ${GeoUtil.fmtName(st.coordFmt)}',
              style: const TextStyle(color: kTextSub, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _item(IconData? icon, String text, {Color color = kTextSub}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
            ],
            Text(text,
                style: TextStyle(color: color, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      );

  Widget _divider() =>
      Container(width: 1, height: 12, color: TokC.divider);
}
