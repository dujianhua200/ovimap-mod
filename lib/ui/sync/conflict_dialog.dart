import 'package:flutter/material.dart';

import '../../sync/sync_models.dart';
import '../dialogs.dart';
import '../../ui/design_tokens.dart';

/// 冲突三选一对话框（架构文档 §4.6 / PRD §3.3 / T17）。
///
/// **不自动覆盖**：让用户明确选择「保留云端 / 保留本机 / 另存冲突副本」，
/// 且**默认选中「另存冲突副本」**（保守优于激进）。
///
/// 返回用户选择；关闭/取消返回 `null`（调用方视为不改动）。
Future<ConflictChoice?> showConflictDialog(
  BuildContext context,
  ConflictInfo info,
) async {
  var choice = ConflictChoice.saveCopy; // 默认推荐项
  return showDialog<ConflictChoice>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) => AlertDialog(
        backgroundColor: kPanelBg,
        title: const Text('同步冲突',
            style: TextStyle(color: kTextMain, fontSize: 16)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '本工程在【${_dev(info.serverDeviceName)}】和【${_dev(info.localDeviceName)}】'
                '都被修改过，为避免丢失改动，请选择保留方式：',
                style: const TextStyle(
                    color: kTextMain, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 10),
              _side('云端', info.serverRev, info.serverUpdatedAt,
                  info.serverDeviceName, TokC.ok),
              const SizedBox(height: 4),
              _side('本机', info.localRev, info.localUpdatedAt,
                  info.localDeviceName, TokC.accent),
              const SizedBox(height: 12),
              _choice(
                value: ConflictChoice.keepCloud,
                group: choice,
                onTap: (v) => setSt(() => choice = v),
                title: '保留云端版本',
                subtitle: '丢弃本机改动，下载云端覆盖本机',
              ),
              _choice(
                value: ConflictChoice.keepLocal,
                group: choice,
                onTap: (v) => setSt(() => choice = v),
                title: '保留本机版本',
                subtitle: '用本机覆盖云端（服务端 rev+1）',
              ),
              _choice(
                value: ConflictChoice.saveCopy,
                group: choice,
                onTap: (v) => setSt(() => choice = v),
                title: '另存冲突副本（推荐）',
                subtitle: '本机改动存为新工程，云端版本保留 — 两边都不丢',
              ),
            ],
          ),
        ),
        actions: [
          darkTextBtn('稍后处理', () => Navigator.pop(ctx), color: kTextSub),
          darkTextBtn('确定', () => Navigator.pop(ctx, choice)),
        ],
      ),
    ),
  );
}

String _dev(String name) => name.trim().isEmpty ? '另一台设备' : name.trim();

String _fmtTime(int ms) {
  if (ms <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String p2(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${p2(d.month)}-${p2(d.day)} ${p2(d.hour)}:${p2(d.minute)}';
}

Widget _side(String who, int rev, int updatedAt, String device, Color color) =>
    Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '$who：rev $rev · ${_fmtTime(updatedAt)}'
            '${device.trim().isEmpty ? '' : ' · ${device.trim()}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: kTextSub, fontSize: 12),
          ),
        ),
      ],
    );

/// 自绘单选项（避免 `RadioListTile.groupValue` 在新版 Flutter 的弃用告警）。
Widget _choice({
  required ConflictChoice value,
  required ConflictChoice group,
  required void Function(ConflictChoice) onTap,
  required String title,
  required String subtitle,
}) {
  final selected = value == group;
  return InkWell(
    onTap: () => onTap(value),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            size: 18,
            color: selected ? kAccent : kTextSub,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: selected ? kAccent : kTextMain,
                        fontSize: 13.5)),
                Text(subtitle,
                    style: const TextStyle(color: kTextSub, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
