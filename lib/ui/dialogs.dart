import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../export/basemap.dart';
import '../export/basemap_file_import.dart';
import '../export/csv.dart';
import '../geo/geo_convert.dart';
import '../export/dxf.dart';
import '../export/dxf_version.dart';
import '../export/kml.dart';
import '../export/local_basemap.dart';
import '../export/overpass.dart';
import '../export/topo.dart';
import '../export/topo_png.dart';
import '../geo/geo_util.dart';
import '../models/map_label.dart';
import '../services/export_saver.dart';
import '../services/photos.dart';
import '../services/platform_caps.dart';
import '../services/tile_cache.dart';
import '../state/app_state.dart';
import 'design_tokens.dart';
import 'desktop/source_panel.dart';

// ================= 通用样式 =================

// 颜色真源已迁到 `design_tokens.dart`（TokC）。下面这些名字保留为**编译期转发
// 别名**：历史调用点（散布在几十个文件里）一行都不用改，但值只有一份，
// 以后调整配色只改令牌文件一处。
const Color kPanelBg = TokC.panel;
const Color kBarBg = TokC.bar;
const Color kAccent = TokC.accent;
const Color kGreen = TokC.ok;
const Color kTextMain = TokC.textMain;
const Color kTextSub = TokC.textSub;

/// 常驻侧栏底色（不透明，避免侧栏透出地图）。
const Color kPanelSolidBg = TokC.panelSolid;

/// 浮起卡片 / 列表项底色。
const Color kCardBg = TokC.card;

/// 输入框填充底色。
const Color kFieldBg = TokC.field;

/// 危险操作色（删除、体检 error）。
const Color kDanger = TokC.danger;

/// 警示色（竣工模式、体检 warn、超限）。
const Color kWarn = TokC.warn;

/// 提示 / 占位文字色。
const Color kTextHint = TokC.textHint;

InputDecoration dec(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: kTextHint, fontSize: TokFs.body),
      filled: true,
      fillColor: kFieldBg,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(TokR.m),
        borderSide: BorderSide.none,
      ),
    );

Future<void> showDarkDialog(
  BuildContext context, {
  required String title,
  Widget? content,
  List<Widget>? actions,
  bool barrierDismissible = true,
  double? width, // null = 沿用 Flutter 默认；传入则固定该宽度（不撑满整窗）
  double maxHeightFactor = 0.8, // 指定 width 时，内容区最高占视口比例
}) {
  // 默认调用方（不传 width）完全保持旧行为：title/content/actions 走 AlertDialog 默认槽位，
  // 不改 insetPadding / contentPadding / constraints，视觉不变。只有传 width 的新面板才收口。
  if (width == null) {
    return showDialog(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) => AlertDialog(
        backgroundColor: kPanelBg,
        title: Text(title,
            style: const TextStyle(color: kTextMain, fontSize: 16)),
        content: content,
        actions: actions,
      ),
    );
  }

  // 传 width 时：本 Flutter 版本的 AlertDialog 会按视口把对话框撑满（仅用 SizedBox 包 content
  // 无法收口），故直接约束对话框自身：min==max==width 锁定宽度，maxHeight 限制高度（内容可滚动）。
  // insetPadding 保留默认（不贴边）。默认分支不传 constraints，旧对话框视觉完全不变。
  final vh = MediaQuery.of(context).size.height;
  return showDialog(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => AlertDialog(
      backgroundColor: kPanelBg,
      title: Text(title,
          style: const TextStyle(color: kTextMain, fontSize: 16)),
      content: content,
      actions: actions,
      constraints: BoxConstraints(
        minWidth: width,
        maxWidth: width,
        maxHeight: vh * maxHeightFactor,
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
    ),
  );
}

Widget darkTextBtn(String text, VoidCallback onTap, {Color color = kAccent}) =>
    TextButton(
      onPressed: onTap,
      child: Text(text, style: TextStyle(color: color)),
    );

/// 底部弹出面板统一风格的条目：点按先关面板再执行。
/// 由原 `home_page` 私有 `_sheetTile` 提升为公有，供 `tools_menu` / `settings_menu` 复用。
Widget sheetTile(BuildContext context, String text, VoidCallback onTap) =>
    ListTile(
      dense: true,
      onTap: () {
        Navigator.pop(context);
        onTap();
      },
      title: Text(text,
          style: const TextStyle(color: kTextMain, fontSize: 13.5)),
    );

/// 面板分组标题（如"成果与资料""地图"）。
Widget sheetGroupTitle(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text, style: const TextStyle(color: kTextSub, fontSize: 12)),
    );

/// 段标注自动补距离：委托 [GeoUtil.segDistText]（米、整数不留 ".0"）。
///
/// 这里曾经自己调 `fmtSegLen` 再手动去尾 —— 与地图段标、DXF 标注是两套实现，
/// 一到 ≥1km 的长杆档就会分叉（一处 "1.05km"、一处 "1050"）。规则已收敛到
/// [GeoUtil.segDistText]，本函数只作既有调用点的兼容壳。
String _segAutoDistText(double d) => GeoUtil.segDistText(d);

/// 段标注敷设前缀快捷键：埋/管/吊/架/钉/槽/桥/顶棚/暗/竖 + 数字（如 管45.3）
/// 点击 = 把前缀替换到距离数字前面：
/// - 输入框已有数字 → 保留数字（换前缀直接点）；
/// - 输入框无数字 → 用 [autoDist]（当前段到上一点的自动距离，按 [_segAutoDistText]
///   口径，去掉 ".0" 毛刺）自动补上数字，实现"42 → 埋42"；
/// - 拿不到距离（[autoDist] 为 null，如首点无上一点）则退化为只填前缀。
Widget segPrefixChips(TextEditingController ctl, {double? autoDist}) {
  return Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final p in const [
        '埋', '管', '吊', '架', '钉', '槽', '桥', '顶棚', '暗', '竖',
      ])
        ActionChip(
          label: Text(p,
              style: const TextStyle(color: kTextMain, fontSize: 12.5)),
          backgroundColor: TokC.field,
          side: BorderSide.none,
          visualDensity: VisualDensity.compact,
          onPressed: () {
            final m = RegExp(r'[0-9][0-9.]*').firstMatch(ctl.text);
            final num = m?.group(0);
            final digit = num ??
                (autoDist == null ? null : _segAutoDistText(autoDist));
            ctl.text = p + (digit ?? '');
          },
        ),
      ActionChip(
        label: const Text('清除',
            style: TextStyle(color: kTextSub, fontSize: 12)),
        backgroundColor: TokC.field,
        side: BorderSide.none,
        visualDensity: VisualDensity.compact,
        onPressed: () => ctl.text = '',
      ),
    ],
  );
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(milliseconds: 1800),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 120),
    ));
}

/// 盘留数字显示：整数不带小数点，否则保留 1 位。
String _fmtSlack(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// 交付生成文件给用户（导出统一出口）。
///
/// 桌面（Windows）=「另存为」对话框；移动端 = 系统分享。具体分支收敛在
/// [ExportSaver.saveOrShare]，此处仅作旧调用点的兼容包装（签名不变）。
Future<void> shareFile(BuildContext context, File f) async {
  await ExportSaver.saveOrShare(context, f);
}

// ================= 标签属性 =================

/// 标签属性编辑（名称/备注/段标注/距离/敷设方式/管孔/分光比）。
Future<void> showLabelProperties(
  BuildContext context,
  AppState st,
  MapLabel label, {
  String title = '标签属性',
  String sourceCid = '',
}) async {
  final nameCtl = TextEditingController(text: label.name);
  final noteCtl = TextEditingController(text: label.note);
  final segLabelCtl = TextEditingController(text: label.distLabel);
  final distCtl = TextEditingController(
      text: label.distanceM != null ? label.distanceM!.toStringAsFixed(1) : '');
  final holesCtl =
      TextEditingController(text: label.holes > 0 ? '${label.holes}' : '');
  final usedCtl = TextEditingController(
      text: label.usedHoles > 0 ? '${label.usedHoles}' : '');
  final ratioCtl = TextEditingController(text: label.splitterRatio);
  final slackCtl = TextEditingController(
      text: label.slackM > 0 ? _fmtSlack(label.slackM) : '');
  final segCableCtl = TextEditingController(text: label.segCable);
  var segKind = label.segKind;
  // 段标注 chip 自动补距离：取同线组上一链点的段距（与地图渲染口径一致）。
  final _prevChain = st.previousChainLabel(label);
  final _segAutoDist = _prevChain == null
      ? null
      : (label.distanceM ??
          GeoUtil.haversine(
              _prevChain.lat, _prevChain.lon, label.lat, label.lon));
  final isWell = ['manhole', 'handwell', 'pipe'].contains(label.typeId);
  final isTopoBox = label.type.isTopoNode;
  var photos = List<String>.from(label.photoPaths);

  await showDarkDialog(
    context,
    title: title,
    content: StatefulBuilder(
      builder: (ctx, setSt) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
                controller: nameCtl,
                style: const TextStyle(color: kTextMain, fontSize: 14),
                decoration: dec('标签名称')),
            const SizedBox(height: 8),
            TextField(
                controller: noteCtl,
                style: const TextStyle(color: kTextMain, fontSize: 14),
                decoration: dec('备注')),
            _photoStripSection(context, st, label, photos, setSt),
            if (label.seq > 1) ...[
              const SizedBox(height: 8),
              TextField(
                  controller: segLabelCtl,
                  style: const TextStyle(color: kTextMain, fontSize: 14),
                  decoration: dec('本段标注（如：埋42.5 / 架38，留空自动显示距离）')),
              const SizedBox(height: 6),
              segPrefixChips(segLabelCtl, autoDist: _segAutoDist),
              const SizedBox(height: 8),
              TextField(
                  controller: distCtl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(color: kTextMain, fontSize: 14),
                  decoration: dec('到上一点距离（米，留空自动）')),
              const SizedBox(height: 8),
              TextField(
                  controller: slackCtl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(color: kTextMain, fontSize: 14),
                  decoration: dec('本段接头盘留（米，结算用量=丈量+盘留）')),
              const SizedBox(height: 8),
              TextField(
                  controller: segCableCtl,
                  style: const TextStyle(color: kTextMain, fontSize: 14),
                  decoration: dec('本段光缆型号（如 48芯GYTS，沿线标注并计入材料统计）')),
              const SizedBox(height: 8),
              const Text('本段敷设方式（决定连线颜色）',
                  style: TextStyle(color: kTextSub, fontSize: 11)),
              Row(
                children: [
                  for (final kv in const {
                    0: '默认',
                    1: '架空',
                    2: '埋地',
                    3: '管道'
                  }.entries)
                    Expanded(
                      child: RadioListTile<int>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(kv.value,
                            style: const TextStyle(
                                color: kTextMain, fontSize: 12)),
                        value: kv.key,
                        groupValue: segKind,
                        activeColor: kAccent,
                        onChanged: (v) => setSt(() => segKind = v!),
                      ),
                    ),
                ],
              ),
            ],
            if (isWell) ...[
              const SizedBox(height: 8),
              const Text('管孔（可选）',
                  style: TextStyle(color: kTextSub, fontSize: 11)),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: holesCtl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: kTextMain, fontSize: 14),
                        decoration: dec('总孔数（如 12）'))),
                const SizedBox(width: 8),
                Expanded(
                    child: TextField(
                        controller: usedCtl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: kTextMain, fontSize: 14),
                        decoration: dec('已占用孔数（如 4）'))),
              ]),
            ],
            if (isTopoBox) ...[
              const SizedBox(height: 8),
              const Text('光分路器分光比（可选，如 1:8 / 1:16 / 1:32）',
                  style: TextStyle(color: kTextSub, fontSize: 11)),
              const SizedBox(height: 4),
              TextField(
                  controller: ratioCtl,
                  style: const TextStyle(color: kTextMain, fontSize: 14),
                  decoration: dec('分光比')),
            ],
          ],
        ),
      ),
    ),
    actions: [
      // 续画分支 / 拖动点位仅对草稿（编辑态）有效；收藏工程里的点点开即可改名/备注/拍照。
      if ((st.mode == AppMode.edit || st.mode == AppMode.view) &&
          sourceCid.isEmpty) ...[
        if (label.typeId != 'text' && label.typeId != 'track')
          darkTextBtn('从此点续画分支', () {
            Navigator.pop(context);
            st.setMode(AppMode.edit);
            st.startRouteFrom(label);
            toast(context,
                '已从「${label.name.isEmpty ? label.type.name : label.name}」开始新分支杆路，继续点地图绘制');
          }, color: kGreen),
        darkTextBtn('拖动点位', () {
          Navigator.pop(context);
          st.draggingLabelId = label.id;
          st.refreshUi();
          toast(context,
              '拖动模式：在地图上点一下，把「${label.name.isEmpty ? label.type.name : label.name}」移到那里');
        }),
      ],
      if (st.hasFix && st.curLat != null && st.curLon != null)
        darkTextBtn('移到当前定位', () {
          label.lat = st.curLat!;
          label.lon = st.curLon!;
          if (sourceCid.isEmpty) {
            st.updateLabel(label);
          } else {
            st.updateOverlayLabel(sourceCid, label);
          }
          Navigator.pop(context);
          toast(context, '已把「${label.name.isEmpty ? label.type.name : label.name}」移到当前定位位置');
        }, color: kGreen),
      darkTextBtn('删除点', () {
        Navigator.pop(context);
        if (sourceCid.isEmpty) {
          st.removeLabel(label);
        } else {
          st.removeOverlayLabel(sourceCid, label);
        }
      }, color: TokC.danger),
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('保存', () {
        label.name = nameCtl.text.trim();
        label.note = noteCtl.text.trim();
        label.segKind = segKind;
        label.splitterRatio = ratioCtl.text.trim();
        label.distLabel = segLabelCtl.text.trim();
        final d = double.tryParse(distCtl.text.trim());
        label.distanceM = (d != null && d > 0) ? d : null;
        final sk = double.tryParse(slackCtl.text.trim());
        label.slackM = (sk != null && sk > 0) ? sk : 0;
        label.segCable = segCableCtl.text.trim();
        label.holes = int.tryParse(holesCtl.text.trim()) ?? 0;
        label.usedHoles = int.tryParse(usedCtl.text.trim()) ?? 0;
        Navigator.pop(context);
        if (sourceCid.isEmpty) {
          st.updateLabel(label);
        } else {
          st.updateOverlayLabel(sourceCid, label);
        }
      }),
    ],
  );
}

// ---- 现场取证照片（奥维标签附件式） ----

/// 属性对话框内的照片缩略图条：拍照/相册挂接，点击看大图，长按删除。
Widget _photoStripSection(BuildContext context, AppState st, MapLabel label,
    List<String> photos, void Function(void Function()) setSt) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 8),
      Text('现场取证照片${photos.isEmpty ? '' : ' ${photos.length} 张'}（点缩略图看大图，长按删除）',
          style: const TextStyle(color: kTextSub, fontSize: 11)),
      const SizedBox(height: 6),
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: photos.isEmpty
              ? const Text('尚无照片，可拍照或从相册挂接',
                  style: TextStyle(color: Color(0xFF78828E), fontSize: 12))
              : SizedBox(
                  height: 68,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: photos.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (c, i) => GestureDetector(
                      onTap: () => _showPhotoViewer(context, photos[i]),
                      onLongPress: () async {
                        final del = await showDialog<bool>(
                          context: context,
                          builder: (dctx) => AlertDialog(
                            backgroundColor: kPanelBg,
                            title: const Text('删除照片？',
                                style: TextStyle(
                                    color: kTextMain, fontSize: 15)),
                            content: Text('将同时删除照片文件，不可恢复。',
                                style: const TextStyle(
                                    color: kTextSub, fontSize: 12)),
                            actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(dctx, false),
                                  child: const Text('取消')),
                              TextButton(
                                  onPressed: () => Navigator.pop(dctx, true),
                                  child: const Text('删除',
                                      style: TextStyle(
                                          color: TokC.danger))),
                            ],
                          ),
                        );
                        if (del != true) return;
                        await PhotoService.deleteFile(photos[i]);
                        photos.removeAt(i);
                        label.photoPaths = List<String>.from(photos);
                        st.updateLabel(label);
                        setSt(() {});
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: FutureBuilder<String>(
                          future: PhotoService.absPath(photos[i]),
                          builder: (c, snap) => snap.hasData
                              ? Image.file(File(snap.data!),
                                  width: 64,
                                  height: 64,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                      width: 64,
                                      height: 64,
                                      color: TokC.field,
                                      child: const Icon(Icons.broken_image,
                                          color: kTextSub, size: 20)))
                              : Container(
                                  width: 64,
                                  height: 64,
                                  color: TokC.field),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        IconButton(
          // 桌面无相机：入口降级为「选择图片文件」。
          tooltip: PlatformCaps.hasCamera ? '拍照取证' : '选择图片文件',
          icon: Icon(PlatformCaps.hasCamera ? Icons.photo_camera : Icons.folder_open,
              color: kAccent, size: 22),
          onPressed: () => _pickAndAttachPhoto(
              context, st, label, photos, ImageSource.camera, setSt),
        ),
        IconButton(
          tooltip: '从相册选择',
          icon: const Icon(Icons.photo_library, color: kAccent, size: 22),
          onPressed: () => _pickAndAttachPhoto(
              context, st, label, photos, ImageSource.gallery, setSt),
        ),
      ]),
    ],
  );
}

Future<void> _pickAndAttachPhoto(
    BuildContext context,
    AppState st,
    MapLabel label,
    List<String> photos,
    ImageSource src,
    void Function(void Function()) setSt) async {
  try {
    String? path;
    if (src == ImageSource.camera && !PlatformCaps.hasCamera) {
      // 桌面无相机：降级为「选择图片文件」（file_picker），仍走 PhotoService.importFile。
      final picked = await FilePicker.platform.pickFiles(type: FileType.image);
      if (picked == null || picked.files.isEmpty) return; // 用户取消：静默返回
      final f = picked.files.first;
      path = f.path;
      if ((path == null || path.isEmpty) && f.bytes != null) {
        // 少数平台只给内存字节：落临时文件后走同一条拷贝链路。
        final tmp = File('${Directory.systemTemp.path}/${f.name}');
        await tmp.writeAsBytes(f.bytes!, flush: true);
        path = tmp.path;
      }
    } else {
      final f = await ImagePicker()
          .pickImage(source: src, maxWidth: 2560, imageQuality: 85);
      path = f?.path;
    }
    if (path == null || path.isEmpty) return;
    final rel = await PhotoService.importFile(label.id, path);
    if (rel == null) {
      if (context.mounted) toast(context, '照片保存失败');
      return;
    }
    photos.add(rel);
    label.photoPaths = List<String>.from(photos);
    st.updateLabel(label); // 即时落盘，不等「保存」
    setSt(() {});
  } catch (e) {
    if (context.mounted) toast(context, '获取照片失败：$e');
  }
}

/// 照片大图查看（双指缩放/平移）。
Future<void> _showPhotoViewer(BuildContext context, String relName) async {
  final abs = await PhotoService.absPath(relName);
  if (!context.mounted) return;
  await showDarkDialog(
    context,
    title: '取证照片',
    content: SizedBox(
      height: 340,
      child: InteractiveViewer(
        maxScale: 4,
        child: Center(
          child: Image.file(File(abs),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Text('照片文件不存在',
                  style: TextStyle(color: kTextSub))),
        ),
      ),
    ),
    actions: [
      darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
    ],
  );
}

/// 竣工距离确认（竣工模式每落一点弹出）。
/// 段距基准 = 同线组上的上一杆（previousChainLabel），
/// 中间插的箱体/文字不会干扰段距计算。
Future<void> showCompletionSegment(
    BuildContext context, AppState st, MapLabel endPoint) async {
  final prev = st.previousChainLabel(endPoint);
  final calculated = prev == null
      ? 0.0
      : GeoUtil.haversine(prev.lat, prev.lon, endPoint.lat, endPoint.lon);
  final prevName = prev == null
      ? '（起点）'
      : (prev.name.trim().isNotEmpty ? prev.name.trim() : prev.type.name);
  final distCtl =
      TextEditingController(text: calculated.toStringAsFixed(1));
  final segLabelCtl =
      TextEditingController(text: endPoint.distLabel.trim());
  final slackCtl = TextEditingController(
      text: endPoint.slackM > 0 ? _fmtSlack(endPoint.slackM) : '');
  final nameCtl = TextEditingController();
  final noteCtl = TextEditingController();
  var segKind = endPoint.segKind;

  await showDarkDialog(
    context,
    title: '竣工距离确认',
    barrierDismissible: false,
    content: StatefulBuilder(
      builder: (ctx, setSt) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
        Text('$calculated 米',
            style: const TextStyle(
                color: Color(0xFF9CCC65),
                fontSize: 30,
                fontWeight: FontWeight.bold)),
        Text('上一杆：$prevName · 上式为地图计算值，可改为钢尺/测距轮实测值',
            style: const TextStyle(color: kTextSub, fontSize: 11)),
        const SizedBox(height: 12),
        TextField(
            controller: distCtl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(color: kTextMain, fontSize: 15),
            decoration: dec('距离（米）')),
        const SizedBox(height: 8),
        TextField(
            controller: segLabelCtl,
            style: const TextStyle(color: kTextMain, fontSize: 14),
            decoration: dec('本段标注（点下方快捷：埋42 / 吊38 / 钉25…）')),
        const SizedBox(height: 6),
        segPrefixChips(segLabelCtl, autoDist: prev == null ? null : calculated),
        const SizedBox(height: 8),
        TextField(
            controller: slackCtl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(color: kTextMain, fontSize: 14),
            decoration: dec('本段接头盘留（米，结算用量=丈量+盘留）')),
        const SizedBox(height: 8),
        const Text('本段敷设方式（决定连线颜色）',
            style: TextStyle(color: kTextSub, fontSize: 11)),
        Row(
          children: [
            for (final kv in const {0: '默认', 1: '架空', 2: '埋地', 3: '管道'}.entries)
              Expanded(
                child: RadioListTile<int>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(kv.value,
                      style:
                          const TextStyle(color: kTextMain, fontSize: 12)),
                  value: kv.key,
                  groupValue: segKind,
                  activeColor: kAccent,
                  onChanged: (v) => setSt(() => segKind = v ?? 0),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
            controller: nameCtl,
            style: const TextStyle(color: kTextMain, fontSize: 14),
            decoration: dec('终点名称（可选）')),
        const SizedBox(height: 8),
        TextField(
            controller: noteCtl,
            style: const TextStyle(color: kTextMain, fontSize: 14),
            decoration: dec('终点备注（可选）')),
      ],
      ),
    ),
    ),
    actions: [
      darkTextBtn('删除终点', () {
        st.removeLabel(endPoint);
        Navigator.pop(context);
      }, color: TokC.danger),
      darkTextBtn('确定', () {
        final v = double.tryParse(distCtl.text.trim());
        if (v == null || v <= 0) {
          toast(context, '请输入大于 0 的距离');
          return;
        }
        endPoint.distanceM = v;
        endPoint.distLabel = segLabelCtl.text.trim();
        final sk = double.tryParse(slackCtl.text.trim());
        endPoint.slackM = (sk != null && sk > 0) ? sk : 0;
        endPoint.segKind = segKind;
        endPoint.name = nameCtl.text.trim();
        endPoint.note = noteCtl.text.trim();
        Navigator.pop(context);
        st.updateLabel(endPoint);
      }),
    ],
  );
}

/// 文字标注落点后立即输入内容。
Future<void> showTextPrompt(
    BuildContext context, AppState st, MapLabel label) async {
  final ctl = TextEditingController();
  await showDarkDialog(
    context,
    title: '文字标注',
    content: TextField(
        controller: ctl,
        autofocus: true,
        style: const TextStyle(color: kTextMain, fontSize: 14),
        decoration: dec('输入标注文字（如：这里转角、预留2孔）')),
    actions: [
      darkTextBtn('删除', () {
        st.removeLabel(label);
        Navigator.pop(context);
      }, color: TokC.danger),
      darkTextBtn('确定', () {
        label.name = ctl.text.trim();
        if (label.name.isEmpty) {
          st.removeLabel(label);
        } else {
          st.updateLabel(label);
        }
        Navigator.pop(context);
      }),
    ],
  );
}

// ================= 保存收藏 =================

Future<void> showFinishDialog(BuildContext context, AppState st) async {
  if (st.labels.isEmpty) {
    toast(context, '草稿为空，无需保存');
    return;
  }
  final nameCtl = TextEditingController(text: st.projectName);
  var folder = st.folderId;
  final folders = st.folders;

  await showDarkDialog(
    context,
    title: '保存收藏',
    content: StatefulBuilder(
      builder: (ctx, setSt) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
              controller: nameCtl,
              autofocus: st.projectName.isEmpty,
              style: const TextStyle(color: kTextMain, fontSize: 14),
              decoration: dec('项目名称')),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: folders.any((f) => f.id == folder) ? folder : '',
            dropdownColor: TokC.field,
            isExpanded: true,
            style: const TextStyle(color: kTextMain, fontSize: 13),
            decoration: dec('所属文件夹'),
            items: [
              for (final f in folders)
                DropdownMenuItem(value: f.id, child: Text(f.name)),
            ],
            onChanged: (v) => setSt(() => folder = v ?? ''),
          ),
          const SizedBox(height: 10),
          Text('共 ${st.labels.length} 个点 · ${st.editModeName == 'completion' ? '竣工模式' : '设计模式'}',
              style: const TextStyle(color: kTextSub, fontSize: 12)),
        ],
      ),
    ),
    actions: [
      darkTextBtn('新建文件夹', () async {
        final fCtl = TextEditingController();
        var done = false; // 与左栏 _addFolder 同口径：回车/按钮只许建一次
        Future<void> submit() async {
          if (done) return;
          done = true;
          Navigator.pop(context);
          final f = await st.store.addFolder(fCtl.text.trim());
          await st.refreshCollections();
          if (context.mounted) {
            // 重新打开保存对话框并选中新文件夹
            st.folderId = f.id;
            showFinishDialog(context, st);
          }
        }

        await showDarkDialog(context,
            title: '新建文件夹',
            content: TextField(
                controller: fCtl,
                autofocus: true,
                onSubmitted: (_) => submit(),
                style: const TextStyle(color: kTextMain),
                decoration: dec('文件夹名称')),
            actions: [
              darkTextBtn('取消', () => Navigator.pop(context),
                  color: kTextSub),
              darkTextBtn('创建', () => submit(), color: kGreen),
            ]);
      }, color: kGreen),
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('保存', () async {
        st.projectName = nameCtl.text.trim();
        st.folderId = folder;
        Navigator.pop(context);
        try {
          await st.finishCollection();
          if (context.mounted) toast(context, '已保存到收藏');
        } catch (e) {
          if (context.mounted) toast(context, '保存失败：$e');
        }
      }, color: kGreen),
    ],
  );
}

// ================= 导出 =================

Future<void> showExportDialog(BuildContext context, List<MapLabel> labels,
    String name,
    {String segPrefix = ''}) async {
  if (labels.isEmpty) {
    toast(context, '没有可导出的数据');
    return;
  }

  await showDarkDialog(
    context,
    title: '导出成果',
    content: StatefulBuilder(
      builder: (ctx, setSt) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _exportTile('📐 DXF 路由图（CAD 可直接打开）', () async {
              Navigator.pop(context);
              await showDxfOptions(context, labels, name, segPrefix: segPrefix);
            }),
            _exportTile('🌍 KML（谷歌地球 / 奥维）', () async {
              Navigator.pop(context);
              try {
                final f = await KmlExporter.export(name, labels);
                if (context.mounted) shareFile(context, f);
              } catch (e) {
                if (context.mounted) toast(context, '导出失败：$e');
              }
            }),
            _exportTile('📋 杆点坐标 CSV（Excel）', () async {
              Navigator.pop(context);
              try {
                final f = await CsvExporter.exportPoles(name, labels);
                if (context.mounted) shareFile(context, f);
              } catch (e) {
                if (context.mounted) toast(context, '导出失败：$e');
              }
            }),
            _exportTile('🔌 芯线占用表 CSV（含校验）', () async {
              Navigator.pop(context);
              try {
                final (f, warns) =
                    await CsvExporter.exportCoreTable(name, labels);
                if (context.mounted) {
                  toast(context,
                      warns > 0 ? '导出完成，发现 $warns 条告警' : '导出完成，校验全部通过');
                  shareFile(context, f);
                }
              } catch (e) {
                if (context.mounted) toast(context, '$e');
              }
            }),
            _exportTile('🖼 配线拓扑图 PNG', () async {
              Navigator.pop(context);
              try {
                final f = await TopoPngExporter.render(labels, name, 1400);
                if (context.mounted) shareFile(context, f);
              } catch (e) {
                if (context.mounted) toast(context, '$e');
              }
            }),
            _exportTile('📊 材料统计表 CSV（分类数量/分段长度/盘留）', () async {
              Navigator.pop(context);
              try {
                final f = await CsvExporter.exportMaterialStats(name, labels);
                if (context.mounted) shareFile(context, f);
              } catch (e) {
                if (context.mounted) toast(context, '$e');
              }
            }),
            _exportTile('🧾 工程量清单 CSV（451 号文口径）', () async {
              Navigator.pop(context);
              try {
                final f = await CsvExporter.exportBoq(name, labels);
                if (context.mounted) shareFile(context, f);
              } catch (e) {
                if (context.mounted) toast(context, '$e');
              }
            }),
          ],
        ),
      ),
    ),
    actions: [darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub)],
  );
}

Widget _exportTile(String title, VoidCallback onTap) => InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: TokC.field,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Expanded(
              child: Text(title,
                  style: const TextStyle(color: kTextMain, fontSize: 13))),
          const Icon(Icons.chevron_right, color: kTextSub, size: 18),
        ]),
      ),
    );

Future<void> showDxfOptions(BuildContext context, List<MapLabel> labels,
    String name,
    {String segPrefix = ''}) async {
  // 选项记忆：下次导出默认沿用上次勾选
  final prefs = await SharedPreferences.getInstance();
  bool opt(String k, bool def) => prefs.getBool(k) ?? def;
  var symbols = opt('dxfSymbols', true);
  var surroundings = opt('dxfSurroundings', true);
  var stakes = opt('dxfStakes', true);
  var legend = opt('dxfLegend', true);
  var redline = opt('dxfRedline', false);
  var straightened = opt('dxfStraightened', false);
  // —— 本次新增 ——
  // 默认 **R12**（已用 ezdxf 严格打开验证；最广兼容）。R2000 可选且同样结构合法。
  var version = (prefs.getString('dxfVersion') ?? 'r12') == 'r2000'
      ? DxfVersion.r2000
      : DxfVersion.r12;
  var layerRoads = opt('dxfLayerRoads', true);
  var layerBldOutline = opt('dxfLayerBldOutline', true);
  var layerBldFill = opt('dxfLayerBldFill', false); // 建筑填充默认关
  var minorRoadNames = opt('dxfMinorRoadNames', false); // 小路也标路名默认关
  var layerPlaces = opt('dxfLayerPlaces', true);
  var tdtFallback = opt('dxfTdtFallback', true);
  var refreshBasemap = false;
  // 本地开源矢量底图（离线）：一次导入、项目级长期复用。
  final localStore = await LocalBasemapStore.open();
  var hasLocal = localStore.exists();
  BasemapData? localBm = hasLocal ? await localStore.load() : null;
  if (localBm == null) hasLocal = false;
  final localMeta = localStore.meta();
  var useLocal = hasLocal && opt('dxfUseLocal', true);
  // 底图外扩范围：预设档位 + 自定义。
  // 自定义值直接恢复（不再强制回落到默认档）；不在预设档位里时
  // UI 显示为「自定义(xxx)」并选中。
  const rangeOptions = <double>[30, 50, 100, 200, 300, 500, 880];
  // 默认 **沿线 50m**（线路设计口径：用户明确"轨迹附近 50 米就好"）。
  // 原默认 880m → 100m → 现在 50m；用户手选过的值仍按记忆走。
  var rangeM = prefs.getDouble('dxfRangeM') ?? 50;
  final corridorCtl =
      TextEditingController(text: prefs.getString('dxfCorridor') ?? '0');

  // —— 搜索/兜底 key（导出与"底图检测"共用同一份，口径一致）——
  // 天地图 key：用户自定义优先，未配置则用内置兜底（单一来源）
  final userKey = prefs.getString(AppState.prefTdtKey)?.trim() ?? '';
  final tdtKey = userKey.isEmpty ? AppState.builtinTdtKey : userKey;
  // 高德 key：用户自定义优先，未配置则用内置兜底（开箱即用，搜索/地名兜底优选高德）
  final userAmapKey = prefs.getString(AppState.prefAmapKey)?.trim() ?? '';
  final amapKey = userAmapKey.isEmpty ? AppState.builtinAmapKey : userAmapKey;
  // Overpass 端点（底图数据源）：用户自定义优先、内置兜底；留空=全走内置境外镜像
  final overpassEndpoints =
      prefs.getString(AppState.prefOverpassEndpoints)?.trim() ?? '';
  // 高德/天地图检索 POI 实测为 GCJ-02；按用户设置决定是否纠偏（默认开）
  final convertGcj =
      prefs.getString(AppState.prefTdtCoordSys) != AppState.tdtCoordWgs84;

  // —— 导出前"底图抓到了什么"（R1-3）——
  // 用户反馈"导出来没东西却不知道为什么"：这里在**导出前**把三数据集的
  // 抓取结果（含失败原因）直接摊开，并提供「重试抓取」入口。
  BasemapFetchReport? probeReport;
  String probeError = '';
  bool probing = false;
  bool probeStarted = false;
  bool dialogOpen = true;

  Future<void> runProbe(
      {required bool refresh, required StateSetter refreshUi}) async {
    if (probing) return;
    probing = true;
    probeError = '';
    refreshUi(() {});
    try {
      final data = await BasemapFetcher.fetchFor(
        labels,
        rangeM: rangeM,
        tdtKey: tdtKey,
        amapKey: amapKey,
        overpassEndpoints: overpassEndpoints,
        useTdt: tdtFallback,
        convertGcj: convertGcj,
        refresh: refresh,
      );
      probeReport = data.report;
    } catch (e) {
      probeError = '$e';
    }
    probing = false;
    if (dialogOpen) refreshUi(() {});
  }

  /// 底图抓取结果卡片（导出前可见 + 重试入口）。
  Widget probeCard(StateSetter refreshUi) {
    const small = TextStyle(color: kTextSub, fontSize: 11);
    final children = <Widget>[];
    if (probing) {
      children.add(const Row(children: [
        SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 8),
        Text('正在抓取底图…', style: small),
      ]));
    } else if (probeError.isNotEmpty) {
      children.add(Text('底图检测失败：$probeError',
          style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 11)));
    } else if (probeReport != null) {
      final rep = probeReport!;
      final bad = !rep.hasVector;
      children.add(Text(
        '底图：${rep.summaryLine}',
        style: TextStyle(
            color: bad ? const Color(0xFFFF8A80) : kGreen, fontSize: 11.5),
      ));
      for (final s in rep.statusLines()) {
        children.add(Padding(
            padding: const EdgeInsets.only(top: 2), child: Text('· $s', style: small)));
      }
      if (bad) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            rep.anyEmptyAnswer
                ? '数据源返回空（疑似底图镜像故障，不是您的范围问题）：'
                    '请点「重试抓取（忽略缓存）」换镜像再取一次。'
                : '道路与建筑均为空：本次导出不会有矢量底图。'
                    '如需地形/建筑请放大范围或改用「导入 GeoJSON 底图」。',
            style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 11),
          ),
        ));
      }
    } else {
      children.add(const Text('底图：未检测（点「检测底图」先看抓取结果再导出）',
          style: small));
    }
    children.add(const SizedBox(height: 2));
    children.add(Row(children: [
      TextButton(
        onPressed: probing
            ? null
            : () => runProbe(refresh: false, refreshUi: refreshUi),
        child: const Text('检测底图',
            style: TextStyle(color: kAccent, fontSize: 12.5)),
      ),
      TextButton(
        onPressed:
            probing ? null : () => runProbe(refresh: true, refreshUi: refreshUi),
        child: const Text('重试抓取（忽略缓存）',
            style: TextStyle(color: kAccent, fontSize: 12.5)),
      ),
    ]));
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  Widget subOption(String title, bool value, ValueChanged<bool> onChanged) =>
      CheckboxListTile(
        dense: true,
        contentPadding: const EdgeInsets.only(left: 16),
        title: Text(title,
            style: const TextStyle(color: kTextMain, fontSize: 12.5)),
        value: value,
        activeColor: kAccent,
        onChanged: (v) => onChanged(v ?? false),
      );

  await showDarkDialog(
    context,
    title: 'DXF 导出选项',
    content: StatefulBuilder(
      builder: (ctx, setSt) {
        // 打开即自动检测一次（缓存命中几乎瞬时，未命中也不阻塞导出操作）。
        if (surroundings && !probeStarted) {
          probeStarted = true;
          Future<void>.microtask(
              () => runProbe(refresh: false, refreshUi: setSt));
        }
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('输出符号块（杆/井/箱按图例）',
                style: TextStyle(color: kTextMain, fontSize: 13)),
            value: symbols,
            activeColor: kAccent,
            onChanged: (v) => setSt(() => symbols = v ?? true),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('杆路里程桩号（K0+000，竣工核对快）',
                style: TextStyle(color: kTextMain, fontSize: 13)),
            value: stakes,
            activeColor: kAccent,
            onChanged: (v) => setSt(() => stakes = v ?? true),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('图例栏自动生成（图框内左下角）',
                style: TextStyle(color: kTextMain, fontSize: 13)),
            value: legend,
            activeColor: kAccent,
            onChanged: (v) => setSt(() => legend = v ?? true),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('竣工图红色描边（杆路/管廊红色）',
                style: TextStyle(color: kTextMain, fontSize: 13)),
            value: redline,
            activeColor: kAccent,
            onChanged: (v) => setSt(() => redline = v ?? false),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('附加拉直沿线配线图（长杆路分幅）',
                style: TextStyle(color: kTextMain, fontSize: 13)),
            value: straightened,
            activeColor: kAccent,
            onChanged: (v) => setSt(() => straightened = v ?? false),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('管廊双线（输入走廊宽度米，0=单中心线）',
                style: TextStyle(color: kTextMain, fontSize: 13)),
            value: (double.tryParse(corridorCtl.text.trim()) ?? 0) > 0,
            activeColor: kAccent,
            onChanged: (v) => setSt(
                () => corridorCtl.text = v == true ? '2' : '0'),
          ),
          TextField(
              controller: corridorCtl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: kTextMain, fontSize: 14),
              decoration: dec('走廊宽度（米），如 2')),
          const Divider(color: TokC.divider),
          // —————— DXF 版本 ——————
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('R2000 专业格式（图层线宽/真彩/建筑填充 HATCH；默认 R12 最广兼容）',
                style: TextStyle(color: kTextMain, fontSize: 13)),
            value: version == DxfVersion.r2000,
            activeColor: kAccent,
            onChanged: (v) => setSt(() =>
                version = (v ?? false) ? DxfVersion.r2000 : DxfVersion.r12),
          ),
          if (version == DxfVersion.r2000)
            const Padding(
              padding: EdgeInsets.only(left: 16, bottom: 2),
              child: Text('提示：部分老 CAD 打开 R2000 可能提示"修复"；不确定就用 R12。',
                  style: TextStyle(color: kTextSub, fontSize: 11)),
            ),
          const Divider(color: TokC.divider),
          // —————— 底图数据源与图层 ——————
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('自动添加周边底图矢量（建筑轮廓/道路/地名，联网·首次后离线复用）',
                style: TextStyle(color: kTextMain, fontSize: 13)),
            value: surroundings,
            activeColor: kAccent,
            onChanged: (v) => setSt(() => surroundings = v ?? false),
          ),
          if (surroundings) ...[
            subOption('道路（分级双线描边 + 居中路名）', layerRoads,
                (v) => setSt(() => layerRoads = v)),
            subOption('建筑轮廓', layerBldOutline,
                (v) => setSt(() => layerBldOutline = v)),
            subOption('建筑填充（默认关，R2000=HATCH / R12=SOLID）', layerBldFill,
                (v) => setSt(() => layerBldFill = v)),
            subOption('小路也标路名（service/other，默认关）', minorRoadNames,
                (v) => setSt(() => minorRoadNames = v)),
            subOption('地名 / 小区名', layerPlaces,
                (v) => setSt(() => layerPlaces = v)),
            subOption('天地图地名兜底（OSM 缺名时补）', tdtFallback,
                (v) => setSt(() => tdtFallback = v)),
            subOption('刷新底图（忽略缓存，重新联网抓取）', refreshBasemap,
                (v) => setSt(() => refreshBasemap = v)),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 16, top: 6, bottom: 2),
                child: Text('底图范围（线路外扩）',
                    style: TextStyle(color: kTextSub, fontSize: 11)),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 4),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final r in rangeOptions)
                      ChoiceChip(
                        label: Text('${r.toInt()}m',
                            style: const TextStyle(fontSize: 12)),
                        selected: rangeM == r,
                        onSelected: (_) => setSt(() => rangeM = r),
                      ),
                    ChoiceChip(
                      label: Text(
                          rangeOptions.contains(rangeM)
                              ? '自定义…'
                              : '自定义(${rangeM.toInt()}m)',
                          style: TextStyle(
                              fontSize: 12,
                              color: rangeOptions.contains(rangeM)
                                  ? null
                                  : kAccent)),
                      selected: !rangeOptions.contains(rangeM),
                      onSelected: (_) async {
                        final v = await _promptCustomRange(context, rangeM);
                        if (v == null) return;
                        // 确认即持久化：下次打开直接恢复自定义值
                        await prefs.setDouble('dxfRangeM', v);
                        setSt(() => rangeM = v);
                      },
                    ),
                  ],
                ),
              ),
            ),
            // 底图数据源（Overpass 端点）提示：让用户导出前一眼看到走的哪条路
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
                child: Text(
                    '底图数据源（Overpass）：'
                    '${OverpassEndpoints.resolve(overpassEndpoints).length} 个端点'
                    '${overpassEndpoints.trim().isEmpty ? '（全内置·境外，可能较慢；可在设置里填自建反代）' : '（自定义优先）'}',
                    style: const TextStyle(color: kTextSub, fontSize: 10.5)),
              ),
            ),
            // R1-3：导出前把底图抓取结果摊开（含失败原因 + 重试入口）
            if (surroundings) probeCard(setSt),
            const Divider(color: TokC.divider),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
                child: Text('本地开源矢量底图（离线，无网也能出图）',
                    style: TextStyle(color: kTextSub, fontSize: 11)),
              ),
            ),
            if (hasLocal)
              subOption('优先使用已导入的本地底图', useLocal,
                  (v) => setSt(() => useLocal = v)),
            if (hasLocal)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 2),
                  child: Text(
                      '已导入：道路 ${localBm?.roads.length ?? 0} · 建筑 ${localBm?.buildings.length ?? 0} · 地名 ${localBm?.places.length ?? 0}'
                      '${(localMeta['sourceName'] as String?)?.isNotEmpty == true ? '（${localMeta['sourceName']}）' : ''}',
                      style: const TextStyle(color: kGreen, fontSize: 11)),
                ),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 2),
                  child: Text('未导入：可导入自行下载的开源数据（GeoJSON：Polygon=建筑 / LineString=道路 / Point=地名）',
                      style: TextStyle(color: kTextSub, fontSize: 11)),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(children: [
                  TextButton(
                    onPressed: () async {
                      final bm = await _showImportGeoJsonDialog(context);
                      if (bm == null) return;
                      localBm = bm;
                      hasLocal = true;
                      useLocal = true;
                      setSt(() {});
                    },
                    child: const Text('导入 GeoJSON 底图…',
                        style: TextStyle(color: kAccent, fontSize: 12.5)),
                  ),
                  if (hasLocal)
                    TextButton(
                      onPressed: () async {
                        final s = await LocalBasemapStore.open();
                        await s.clear();
                        localBm = null;
                        hasLocal = false;
                        useLocal = false;
                        setSt(() {});
                      },
                      child: const Text('清除本地底图',
                          style: TextStyle(color: kTextSub, fontSize: 12.5)),
                    ),
                ]),
              ),
            ),
          ],
          const Text('坐标系：以第一个点为原点的本地平面（米）',
              style: TextStyle(color: kTextSub, fontSize: 11)),
        ],
        ),
      );
      },
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('导出', () async {
        Navigator.pop(context);
        // 记住本次勾选，下次默认沿用
        prefs.setBool('dxfSymbols', symbols);
        prefs.setBool('dxfSurroundings', surroundings);
        prefs.setBool('dxfStakes', stakes);
        prefs.setBool('dxfLegend', legend);
        prefs.setBool('dxfRedline', redline);
        prefs.setBool('dxfStraightened', straightened);
        prefs.setString('dxfCorridor', corridorCtl.text.trim());
        prefs.setString(
            'dxfVersion', version == DxfVersion.r12 ? 'r12' : 'r2000');
        prefs.setBool('dxfLayerRoads', layerRoads);
        prefs.setBool('dxfLayerBldOutline', layerBldOutline);
        prefs.setBool('dxfLayerBldFill', layerBldFill);
        prefs.setBool('dxfMinorRoadNames', minorRoadNames);
        prefs.setBool('dxfLayerPlaces', layerPlaces);
        prefs.setBool('dxfTdtFallback', tdtFallback);
        prefs.setBool('dxfUseLocal', useLocal);
        prefs.setDouble('dxfRangeM', rangeM);
        toast(context, '正在生成 DXF…');
        try {
          final corridor =
              double.tryParse(corridorCtl.text.trim()) ?? 0;
          final r = await DxfExporter.export(
            name: name,
            labels: labels,
            includeLabelSymbols: symbols,
            corridorWidth: corridor,
            includeSurroundings: surroundings,
            showStakes: stakes,
            showLegend: legend,
            completionRed: redline,
            straightenedWiring: straightened,
            version: version,
            rangeM: rangeM,
            layerRoads: layerRoads,
            layerBuildingOutline: layerBldOutline,
            buildingFill: layerBldFill,
            showMinorRoadNames: minorRoadNames,
            layerPlaces: layerPlaces,
            segPrefix: segPrefix,
            placesTdtFallback: tdtFallback,
            tdtKey: tdtKey,
            // 高德 key（用户自配）：有则地名兜底优先用高德，无则回落天地图
            amapKey: amapKey,
            // Overpass 端点（用户自建反代优先、内置兜底）：留空=全走内置
            overpassEndpoints: overpassEndpoints,
            convertGcj: convertGcj,
            refreshBasemap: refreshBasemap,
            // 本地开源矢量底图（离线优先）；未勾选则走缓存/联网抓取。
            localBasemap: (surroundings && useLocal) ? localBm : null,
          );
          if (context.mounted) {
            // 非致命警告 / 底图三态结构化说明（文件仍正常分享）
            if (r.warnings.isNotEmpty) {
              toast(context, r.warnings.join('\n'));
            }
            shareFile(context, r.file);
          }
        } catch (e) {
          if (context.mounted) toast(context, '导出失败：$e');
        }
      }),
    ],
  );
  // 对话框已关闭：底图检测若仍在跑，不再回调 setSt（避免对已卸载节点刷新）
  dialogOpen = false;
}

/// R1：自定义底图外扩范围（米，限 20~5000）。
/// 合法输入确认后返回该值（调用方负责持久化）；取消返回 null；
/// 非法输入 toast 提示且弹窗保留，返回 null。
Future<double?> _promptCustomRange(BuildContext context, double current) async {
  final ctl = TextEditingController(text: current.toStringAsFixed(0));
  double? confirmed;
  await showDarkDialog(
    context,
    title: '自定义底图范围（米）',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*(\.\d*)?$')),
          ],
          style: const TextStyle(color: kTextMain, fontSize: 14),
          decoration: dec('20 ~ 5000 米，如 150'),
        ),
        const SizedBox(height: 6),
        const Text('导出矢量底图时按杆路线路外扩该范围（20~5000 米）。',
            style: TextStyle(color: kTextSub, fontSize: 11)),
      ],
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('确定', () {
        final v = double.tryParse(ctl.text.trim());
        if (v == null || v < 20 || v > 5000) {
          toast(context, '请输入 20~5000 之间的范围（米）');
          return;
        }
        confirmed = v;
        Navigator.pop(context);
      }),
    ],
  );
  return confirmed;
}

// ================= 图源管理 =================

/// 图源 / 图层对话框入口。实现已整体迁移到 `desktop/source_panel.dart` 的
/// `showSourcePanel`（定宽 480 的紧凑面板），此处仅做薄委托，保持既有调用方
/// （toolbar / home_page / settings_menu / menu_model）无感。
Future<void> showSourceDialog(BuildContext context, AppState st) async {
  await showSourcePanel(context, st);
}

Future<void> showAddCustomSource(BuildContext context, AppState st) async {
  final nameCtl = TextEditingController();
  final urlCtl = TextEditingController();
  final zoomCtl = TextEditingController(text: '18');
  var datumSel = 0;
  var overlay = false;

  await showDarkDialog(
    context,
    title: '添加自定义图源',
    content: StatefulBuilder(
      builder: (ctx, setSt) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameCtl,
                style: const TextStyle(color: kTextMain, fontSize: 14),
                decoration: dec('名称（如：公司内网卫星图）')),
            const SizedBox(height: 8),
            TextField(
                controller: urlCtl,
                style: const TextStyle(color: kTextMain, fontSize: 12),
                decoration: dec(
                    'URL 模板，如 https://host/tile/{z}/{x}/{y}.png')),
            const SizedBox(height: 8),
            TextField(
                controller: zoomCtl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: kTextMain, fontSize: 14),
                decoration: dec('最大缩放级别（如 18）')),
            const SizedBox(height: 8),
            const Text('瓦片坐标系（选错会偏移 300-500 米）',
                style: TextStyle(color: kTextSub, fontSize: 11)),
            Row(
              children: [
                for (final kv in const {0: 'WGS-84', 1: 'GCJ-02', 2: 'BD-09'}.entries)
                  Expanded(
                    child: RadioListTile<int>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(kv.value,
                          style:
                              const TextStyle(color: kTextMain, fontSize: 12)),
                      value: kv.key,
                      groupValue: datumSel,
                      activeColor: kAccent,
                      onChanged: (v) => setSt(() => datumSel = v!),
                    ),
                  ),
              ],
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('作为透明注记叠加层',
                  style: TextStyle(color: kTextMain, fontSize: 13)),
              value: overlay,
              activeColor: kAccent,
              onChanged: (v) => setSt(() => overlay = v ?? false),
            ),
          ],
        ),
      ),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('添加', () {
        if (nameCtl.text.trim().isEmpty || urlCtl.text.trim().isEmpty) {
          toast(context, '名称与 URL 不能为空');
          return;
        }
        st.addCustomSource(
          nameCtl.text.trim(),
          urlCtl.text.trim(),
          datumSel,
          int.tryParse(zoomCtl.text.trim()) ?? 18,
          overlay: overlay,
        );
        Navigator.pop(context);
        toast(context, '已添加并切换');
        st.applySource(st.customSources.last);
      }),
    ],
  );
}

// ================= 离线下载 =================

Future<void> showOfflineDialog(BuildContext context, AppState st,
    MapController controller, CacheTileProvider provider) async {
  final cam = controller.camera;
  var targetZoom = cam.zoom.round() + 1;
  if (targetZoom > st.curSource.maxZoom) targetZoom = st.curSource.maxZoom;

  int estimate(double z) => OfflineDownload.instance
      .estimateTiles(cam.visibleBounds, z.round());

  await showDarkDialog(
    context,
    title: '离线区域下载',
    content: StatefulBuilder(
      builder: (ctx, setSt) {
        final est = estimate(targetZoom.toDouble());
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('下载「当前屏幕范围」的瓦片，之后无网络也能看',
                style: TextStyle(color: kTextSub, fontSize: 12)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('下载至级别 ',
                    style: TextStyle(color: kTextMain, fontSize: 13)),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: targetZoom > 3
                      ? () => setSt(() => targetZoom--)
                      : null,
                  icon: const Icon(Icons.remove_circle_outline,
                      color: kAccent),
                ),
                Text('$targetZoom',
                    style: const TextStyle(
                        color: kTextMain,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: targetZoom < st.curSource.maxZoom
                      ? () => setSt(() => targetZoom++)
                      : null,
                  icon:
                      const Icon(Icons.add_circle_outline, color: kAccent),
                ),
              ],
            ),
            Text(
                est > 6000
                    ? '约 $est 张瓦片（过多，请放大地图或降低级别）'
                    : '约 $est 张瓦片',
                style: TextStyle(
                    color: est > 6000
                        ? const Color(0xFFFF8A80)
                        : kTextSub,
                    fontSize: 12)),
          ],
        );
      },
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('开始下载', () {
        Navigator.pop(context);
        _runOffline(context, st, provider, cam.visibleBounds, targetZoom);
      }),
    ],
  );
}

Future<void> _runOffline(BuildContext context, AppState st,
    CacheTileProvider provider, LatLngBounds bounds, int zoom) async {
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _OfflineProgressDialog(
      provider: provider,
      bounds: bounds,
      zoom: zoom,
    ),
  );
}

class _OfflineProgressDialog extends StatefulWidget {
  final CacheTileProvider provider;
  final LatLngBounds bounds;
  final int zoom;
  const _OfflineProgressDialog({
    required this.provider,
    required this.bounds,
    required this.zoom,
  });

  @override
  State<_OfflineProgressDialog> createState() => _OfflineProgressDialogState();
}

class _OfflineProgressDialogState extends State<_OfflineProgressDialog> {
  int done = 0;
  int total = 1;
  int fresh = 0;
  bool finished = false;
  String? error;

  @override
  void initState() {
    super.initState();
    OfflineDownload.instance.cancel(); // 复位取消标志
    _start();
  }

  Future<void> _start() async {
    try {
      await OfflineDownload.instance.download(
        provider: widget.provider,
        boundsDisp: widget.bounds,
        targetZoom: widget.zoom,
        onProgress: (d, t, f) {
          if (!mounted) return;
          setState(() {
            done = d;
            total = t;
            fresh = f;
          });
        },
      );
      if (!mounted) return;
      setState(() => finished = true);
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = '$e';
        finished = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kPanelBg,
      title: Text(finished ? '离线下载完成' : '正在下载离线瓦片',
          style: const TextStyle(color: kTextMain, fontSize: 15)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        LinearProgressIndicator(
            value: total == 0 ? 0 : done / total, color: kAccent),
        const SizedBox(height: 10),
        Text(
            error ??
                (finished
                    ? '共 $total 张，新下载 $fresh 张'
                    : '$done / $total（新下载 $fresh 张）'),
            style: const TextStyle(color: kTextSub, fontSize: 12)),
      ]),
      actions: finished
          ? [darkTextBtn('关闭', () => Navigator.pop(context))]
          : [
              darkTextBtn('取消下载', () {
                OfflineDownload.instance.cancel();
              }, color: TokC.danger),
            ],
    );
  }
}

// ================= 采集设置 =================

Future<void> showCollectionSettings(BuildContext context, AppState st) async {
  final prefixCtl = TextEditingController(text: st.numPrefix);
  final segPrefixCtl = TextEditingController(text: st.segPrefix);
  var autoNum = st.autoNumber;

  await showDarkDialog(
    context,
    title: '采集设置',
    content: StatefulBuilder(
      builder: (ctx, setSt) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('杆路自动编号（落点自动命名 GK-1、GK-2…）',
                style: TextStyle(color: kTextMain, fontSize: 13)),
            value: autoNum,
            activeColor: kAccent,
            onChanged: (v) => setSt(() => autoNum = v ?? false),
          ),
          TextField(
              controller: prefixCtl,
              style: const TextStyle(color: kTextMain, fontSize: 14),
              decoration: dec('编号前缀（默认 GK）')),
          const SizedBox(height: 10),
          TextField(
              controller: segPrefixCtl,
              style: const TextStyle(color: kTextMain, fontSize: 14),
              decoration: dec('段标前缀（如 埋／架，留空则只显示数字）')),
        ],
      ),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('保存', () {
        st.setAutoNumber(autoNum, prefixCtl.text);
        st.setSegPrefix(segPrefixCtl.text);
        Navigator.pop(context);
        toast(context, '已保存设置');
      }),
    ],
  );
}

Future<void> showTiandituKeyDialog(BuildContext context, AppState st) async {
  final ctl = TextEditingController(text: st.prefs.getString(AppState.prefTdtKey) ?? '');
  var coordSys = st.tdtCoordSys;
  await showDarkDialog(
    context,
    title: '天地图 Key',
    content: StatefulBuilder(
      builder: (ctx, setSt) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
              controller: ctl,
              style: const TextStyle(color: kTextMain, fontSize: 12),
              decoration: dec('天地图开发者 key（留空隐藏天地图源）')),
          const SizedBox(height: 12),
          const Text('天地图地名坐标系',
              style: TextStyle(color: kTextSub, fontSize: 12)),
          // 天地图检索 POI 实测为 GCJ-02 火星坐标（瓦片才是 WGS84），
          // 默认自动纠偏；测绘用户可关掉对照原始返回坐标。
          RadioListTile<String>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('GCJ-02 火星坐标（自动纠偏为 WGS-84）',
                style: TextStyle(color: kTextMain, fontSize: 13)),
            value: AppState.tdtCoordGcj02,
            groupValue: coordSys,
            activeColor: kAccent,
            onChanged: (v) =>
                setSt(() => coordSys = v ?? AppState.tdtCoordGcj02),
          ),
          RadioListTile<String>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('WGS-84（不转换，保留原始返回坐标）',
                style: TextStyle(color: kTextMain, fontSize: 13)),
            value: AppState.tdtCoordWgs84,
            groupValue: coordSys,
            activeColor: kAccent,
            onChanged: (v) =>
                setSt(() => coordSys = v ?? AppState.tdtCoordGcj02),
          ),
        ],
      ),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('保存', () {
        st.setTiandituKey(ctl.text);
        st.setTdtCoordSys(coordSys);
        Navigator.pop(context);
        toast(context, '已保存，图源列表已更新');
      }),
    ],
  );
}

/// 高德 Key 设置（第二十批新增）。
///
/// 高德**有内置 key（开箱即用）**：未填写时搜索与 DXF 地名兜底自动使用内置 key
/// （`AppState.builtinAmapKey`）。若用户有自己的「Web 服务」类型 key，可在
/// [https://console.amap.com] 申请后填入覆盖内置值；「清空」即恢复使用内置 key。
Future<void> showAmapKeyDialog(BuildContext context, AppState st) async {
  final ctl = TextEditingController(text: st.userAmapKey);
  await showDarkDialog(
    context,
    title: '高德 Key',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
            controller: ctl,
            style: const TextStyle(color: kTextMain, fontSize: 12),
            decoration: dec('高德 Web 服务 key（留空=用内置 key）')),
        const SizedBox(height: 8),
        const Text(
          '默认已内置高德 key，开箱即用地名搜索/兜底即优选高德，无需填写。\n'
          '如需用自己的 key：申请 https://console.amap.com → 应用管理 → 创建新应用 '
          '→ 添加 Key → 服务平台选「Web 服务」，填入后覆盖内置值。\n'
          '高德返回为 GCJ-02 火星坐标，本 app 自动纠偏为 WGS-84 后落图。',
          style: TextStyle(color: kTextSub, fontSize: 11),
        ),
      ],
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('清空', () {
        st.setAmapKey('');
        Navigator.pop(context);
        toast(context, '已清空，恢复使用内置高德 Key');
      }, color: kTextSub),
      darkTextBtn('保存', () {
        st.setAmapKey(ctl.text);
        Navigator.pop(context);
        toast(context, ctl.text.trim().isEmpty
            ? '已清空，恢复使用内置高德 Key'
            : '已保存，搜索与底图地名优先使用高德');
      }),
    ],
  );
}

/// Overpass 端点（底图数据源）设置。
///
/// 背景：底图的道路/建筑来自 OSM Overpass，内置镜像**全在境外**，抓取慢且不稳。
/// 用户可用 Cloudflare Worker / 自建服务器架一个反代，把地址填在这里 →
/// 底图抓取会**优先走自建反代**，内置镜像退居兜底。支持换行 / 逗号 / 分号分隔。
///
/// **校验策略（整体拦截）**：保存时若存在不以 `http://` / `https://` 开头的非法项，
/// 弹窗保留并给出中文提示，**不写入任何内容**。理由：面向非程序员，若静默丢弃
/// 手误写成 `ovp.xxx.com`（漏了协议头）的地址，用户会以为"填好了却没生效"，
/// 反而更困惑；整体拦截能逼用户当场改对。
Future<void> showOverpassEndpointsDialog(BuildContext context, AppState st) async {
  final ctl = TextEditingController(text: st.overpassEndpoints);
  final custom = OverpassEndpoints.splitCustom(st.overpassEndpoints).toSet();
  final effective = OverpassEndpoints.resolve(st.overpassEndpoints);
  await showDarkDialog(
    context,
    title: 'Overpass 端点（底图数据源）',
    content: StatefulBuilder(
      builder: (ctx, setSt) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctl,
              minLines: 2,
              maxLines: 5,
              keyboardType: TextInputType.url,
              style: const TextStyle(color: kTextMain, fontSize: 12),
              decoration: dec('每行一个（或用逗号/分号分隔），如：\n'
                  'https://ovp.你的域名.com/'),
            ),
            const SizedBox(height: 8),
            const Text(
              '留空则使用内置的公共镜像（均为境外，可能较慢）。\n'
              '如你自建了反代（Cloudflare Worker / 自建服务器），把地址填在这里会优先使用。\n'
              '例：https://ovp.你的域名.com/\n'
              '地址必须以 http:// 或 https:// 开头。',
              style: TextStyle(color: kTextSub, fontSize: 11),
            ),
            const SizedBox(height: 10),
            Text('当前生效端点：${effective.length} 个（自定义在前，绿色=你的反代）',
                style: const TextStyle(color: kTextSub, fontSize: 11)),
            const SizedBox(height: 4),
            for (var i = 0; i < effective.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '${i + 1}. ${effective[i]}',
                  style: TextStyle(
                      color: custom.contains(effective[i]) ? kGreen : kTextSub,
                      fontSize: 10.5),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('清空（恢复内置）', () {
        st.setOverpassEndpoints('');
        Navigator.pop(context);
        toast(context, '已清空，恢复使用内置 Overpass 镜像');
      }, color: kTextSub),
      darkTextBtn('保存', () {
        final items = OverpassEndpoints.splitCustom(ctl.text);
        final invalid = items
            .where((e) => !OverpassEndpoints.isValidEndpoint(e))
            .toList();
        if (invalid.isNotEmpty) {
          // 整体拦截：保留弹窗、不写入，提示哪几项非法
          toast(context,
              '地址需以 http:// 或 https:// 开头，请检查：${invalid.join('、')}');
          return;
        }
        st.setOverpassEndpoints(ctl.text);
        Navigator.pop(context);
        toast(
            context,
            items.isEmpty
                ? '已清空，恢复使用内置 Overpass 镜像'
                : '已保存 ${items.length} 个自定义端点，底图抓取将优先使用');
      }),
    ],
  );
}

// ================= 说明类 =================

Future<void> showDatumHelp(BuildContext context, AppState st) => showDarkDialog(
      context,
      title: '坐标系说明',
      content: Text(
        '本图当前按 ${GeoConvert.datumName(st.datum)} 显示。\n\n'
        '· GPS 原始坐标为 WGS-84；国内卫星/街道图通常带 GCJ-02 偏移。\n'
        '· 所有采集数据一律以 WGS-84 保存，显示时自动纠偏，导出不受影响。\n'
        '· 切换图源时坐标系随图源自动设置；自定义源请在添加时选择。',
        style: const TextStyle(color: kTextMain, fontSize: 13),
      ),
      actions: [darkTextBtn('知道了', () => Navigator.pop(context))],
    );

Future<void> showAbout(BuildContext context) => showDarkDialog(
      context,
      title: '滑洲云图 3.0',
      content: const Text(
        '面向通信工程勘察设计与竣工测量的地图工具。\n\n'
        '· 设计/竣工双模式 · 符号库对齐联通线路图例\n'
        '· 定位航向箭头跟随手机方向 · 重名工程自动续号不覆盖\n'
        '· 收藏树 · 测距测面 · 轨迹记录 · 离线下载\n'
        '· DXF / KML / CSV / 配线图导出 · 拓扑芯线校验',
        style: TextStyle(color: kTextMain, fontSize: 13),
      ),
      actions: [darkTextBtn('关闭', () => Navigator.pop(context))],
    );

Future<void> showTopoGuide(BuildContext context) => showDarkDialog(
      context,
      title: '拓扑连线怎么用',
      content: SingleChildScrollView(
        child: Text(
          '1. 画杆路：正常放置水泥杆/人孔等，自动连线。\n\n'
          '2. 放箱体：光交、分光器箱、分纤盒、ONU箱、机房、基站、引上是独立点，'
          '不会打断杆路线，画完杆路后单独放置即可。\n\n'
          '3. 保存项目后：收藏夹项目右侧点「⚡拓扑」。\n\n'
          '4. 连线：点起点箱体（如光交）→ 点终点箱体（如分光箱）→ 选光缆规格'
          '（6芯/12芯/24芯/48芯…）→ 保存；重复直到全部连完。可「撤销连线」。\n\n'
          '5. 出图：导出里选 DXF（路由图+配线图同图框）/ 配线拓扑图 PNG / 芯线占用表。\n\n'
          '6. 分支杆路：采集中长按任一已存点 →「从此点续画新杆路」。\n\n'
          '编号规则：有名称用你的名称；没名称按类型自动编号（光交-1、分纤盒-2…）。',
          style: const TextStyle(color: kTextMain, fontSize: 12.5, height: 1.4),
        ),
      ),
      actions: [darkTextBtn('知道了', () => Navigator.pop(context))],
    );

/// 拓扑连线后选择光缆规格。
Future<void> showCableDialog(
    BuildContext context, AppState st, MapLabel target) async {
  final ctl = TextEditingController(text: target.cableSpec);
  await showDarkDialog(
    context,
    title: '选择连接光缆',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in const ['6芯', '12芯', '24芯', '48芯', '96芯', '144芯'])
              ActionChip(
                label: Text(c, style: const TextStyle(color: kTextMain, fontSize: 12)),
                backgroundColor: TokC.field,
                side: BorderSide.none,
                onPressed: () => ctl.text = c,
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
            controller: ctl,
            style: const TextStyle(color: kTextMain, fontSize: 14),
            decoration: dec('光缆规格（如：架空48芯GYTS-01）')),
      ],
    ),
    actions: [
      darkTextBtn('跳过', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('保存', () {
        target.cableSpec = ctl.text.trim();
        target.cableCores = Topology.parseCores(target.cableSpec);
        st.store.saveCollectionLabels(st.topoCid, st.topoColl);
        Navigator.pop(context);
      }),
    ],
  );
}

/// 续画杆路确认。
Future<void> showContinueRouteDialog(
    BuildContext context, AppState st, MapLabel near) async {
  final nm = near.name.trim().isNotEmpty ? near.name.trim() : near.type.name;
  await showDarkDialog(
    context,
    title: '从 [$nm] 续画杆路？',
    content: const Text(
      '会以此点为起点新建一条杆路线组，之后点地图就是画第二条杆路（分支/另一侧），两点自动连到该起点。',
      style: TextStyle(color: kTextMain, fontSize: 13),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('开始续画', () {
        st.startRouteFrom(near);
        Navigator.pop(context);
        toast(context, '已从此点开始新杆路，继续点地图绘制');
      }),
    ],
  );
}

/// 浏览模式长按上下文卡。
Future<void> showContextCard(BuildContext context, AppState st,
    double dispLat, double dispLon) async {
  final w = st.toWgs(dispLat, dispLon);
  await showDarkDialog(
    context,
    title: '位置操作',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'WGS-84：${w[0].toStringAsFixed(6)}, ${w[1].toStringAsFixed(6)}\n'
          '${GeoConvert.datumName(st.datum)}：${dispLat.toStringAsFixed(6)}, ${dispLon.toStringAsFixed(6)}',
          style: const TextStyle(color: kTextMain, fontSize: 13),
        ),
        const SizedBox(height: 6),
        // 现场高程（Open-Meteo 免 key，按坐标缓存；设计/竣工估塔高、抄平都用得上）
        FutureBuilder<double?>(
          future: fetchElevation(w[0], w[1]),
          builder: (c, snap) {
            String txt;
            if (snap.connectionState != ConnectionState.done) {
              txt = '高程：查询中…';
            } else if (snap.hasData) {
              txt = '高程：约 ${snap.data!.toStringAsFixed(0)} 米';
            } else {
              txt = '高程：查询失败（网络原因）';
            }
            return Text(txt,
                style: const TextStyle(
                    color: Color(0xFF9CCC65), fontSize: 12.5));
          },
        ),
      ],
    ),
    actions: [
      darkTextBtn('复制坐标', () {
        Navigator.pop(context);
        // 剪贴板
        _copyToClipboard('${w[0].toStringAsFixed(6)},${w[1].toStringAsFixed(6)}');
        toast(context, '已复制 WGS-84 坐标');
      }),
      darkTextBtn('在此放「${st.curType.name}」', () {
        Navigator.pop(context);
        st.setMode(AppMode.edit);
        st.addLabelAtWgs(w[0], w[1]);
      }),
      darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
    ],
  );
}

// ---- 高程查询（Open-Meteo Elevation API，免 key；结果按坐标缓存） ----

final Map<String, double> _elevCache = {};

Future<double?> fetchElevation(double lat, double lon) async {
  final key = '${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}';
  if (_elevCache.containsKey(key)) return _elevCache[key];
  try {
    final r = await http
        .get(Uri.parse(
            'https://api.open-meteo.com/v1/elevation?latitude=$lat&longitude=$lon'))
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return null;
    final arr = jsonDecode(r.body)['elevation'];
    if (arr is List && arr.isNotEmpty) {
      final v = (arr.first as num).toDouble();
      _elevCache[key] = v;
      return v;
    }
  } catch (_) {}
  return null;
}

void _copyToClipboard(String text) {
  Clipboard.setData(ClipboardData(text: text));
}

/// KML 导入（奥维式双向闭环）：粘贴 KML 全文或从剪贴板读取，
/// 解析预览确认后导入当前草稿；误导入可用「撤销」一键回退。
Future<void> showKmlImportDialog(BuildContext context, AppState st) async {
  final ctl = TextEditingController();
  await showDarkDialog(
    context,
    title: '导入 KML 到当前项目',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
            '支持 .kml 文本（Point 单点 / LineString 连线）；KMZ 为 zip 包，请先解压出 .kml 再导。坐标按 WGS-84 处理。',
            style: TextStyle(color: kTextSub, fontSize: 11)),
        const SizedBox(height: 8),
        TextField(
          controller: ctl,
          maxLines: 6,
          style: const TextStyle(
              color: kTextMain, fontSize: 11, fontFamily: 'monospace'),
          decoration: dec('粘贴 KML 全文，或点下方「读取剪贴板」'),
        ),
      ],
    ),
    actions: [
      darkTextBtn('读取剪贴板', () async {
        final data = await Clipboard.getData('text/plain');
        final t = data?.text ?? '';
        if (t.trim().isEmpty) {
          if (context.mounted) toast(context, '剪贴板为空');
          return;
        }
        ctl.text = t;
        if (context.mounted) toast(context, '已读入剪贴板内容，点「解析并导入」');
      }),
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('解析并导入', () {
        if (ctl.text.trim().isEmpty) {
          toast(context, '请先粘贴 KML 文本');
          return;
        }
        final summary = st.importKmlText(ctl.text);
        Navigator.pop(context);
        toast(context,
            summary == null ? '解析失败：未找到有效的 KML 要素' : '已导入 $summary（可点「撤销」回退）');
      }),
    ],
  );
}

/// 导入本地开源矢量底图（GeoJSON）：**从文件选择**（系统选择器 SAF）或**粘贴/剪贴板**，
/// 解析后交给 DXF 导出离线复用。
///
/// **两种入口并存**：
/// - 「从文件选择…」用系统文件选择器（`file_picker`）直接选本地 `.geojson/.json`，
///   适合大文件（如整市十余 MB 底图）——粘贴方式对这类文件不现实；
///   SAF 走系统选择器**不需要任何存储权限**（Android 11+ 分区存储友好）。
/// - 「粘贴/剪贴板」沿用既有零依赖交互（同 [showKmlImportDialog]），小样本/快速调试更方便。
///
/// 两条入口最终都走**同一条落盘路径**（[GeoJsonImporter.parse] → [LocalBasemapStore.save]），
/// 口径完全一致。
///
/// 返回解析成功的 [BasemapData]（取消/失败返回 null）。
Future<BasemapData?> _showImportGeoJsonDialog(BuildContext context) async {
  final ctl = TextEditingController();
  BasemapData? result;

  // 现状：当前是否已导入 + 元信息（要素数/来源/导入时间），让用户决定是否覆盖。
  final curStore = await LocalBasemapStore.open();
  final curMeta = curStore.meta();
  final hasCur = curStore.exists() && curMeta.isNotEmpty;
  if (!context.mounted) return null;

  await showDarkDialog(
    context,
    title: '导入本地开源矢量底图（GeoJSON）',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
            '两种方式任选：点「从文件选择…」用系统选择器选本地 .geojson/.json；'
            '或把 GeoJSON 全文粘贴到下方。Polygon=建筑、LineString=道路、Point=地名，'
            '坐标按 WGS-84（[经度, 纬度]）。导入后写入项目目录，无网也能出带底图的图。',
            style: TextStyle(color: kTextSub, fontSize: 11)),
        if (hasCur) ...[
          const SizedBox(height: 6),
          Text(
              '当前已导入：道路 ${curMeta['roads'] ?? 0} · 建筑 ${curMeta['buildings'] ?? 0} · '
              '地名 ${curMeta['places'] ?? 0}'
              '${(curMeta['sourceName'] as String?)?.isNotEmpty == true ? '（${curMeta['sourceName']}）' : ''}'
              '${_fmtMetaTime(curMeta['savedAt'])}',
              style: const TextStyle(color: kGreen, fontSize: 11)),
        ],
        const SizedBox(height: 8),
        TextField(
          controller: ctl,
          maxLines: 8,
          style: const TextStyle(
              color: kTextMain, fontSize: 11, fontFamily: 'monospace'),
          decoration: dec('粘贴 GeoJSON 全文，或点下方「读取剪贴板」；也可点「从文件选择…」'),
        ),
      ],
    ),
    actions: [
      darkTextBtn('从文件选择…', () async {
        // —— 系统文件选择器（SAF）：过滤 .geojson/.json，且不申请任何存储权限 ——
        FilePickerResult? picked;
        try {
          picked = await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: const ['geojson', 'json'],
            // 大文件只取路径，避免 withData 把整份数据在内存里多拷贝一层。
            withData: false,
          );
        } catch (e) {
          if (context.mounted) toast(context, '打开文件选择器失败：$e');
          return;
        }
        // 用户取消：picked == null → 静默返回，**不报错**。
        if (picked == null || picked.files.isEmpty) return;
        final f = picked.files.first;
        try {
          final BasemapData bm;
          final path = f.path;
          if (path != null && path.isNotEmpty) {
            bm = await BasemapFileImporter.importFromPath(path,
                sourceName: f.name);
          } else if (f.bytes != null) {
            // 少数平台只给 content://（无本地路径）：回退读字节解码。
            bm = await BasemapFileImporter.importFromBytes(f.bytes!,
                sourceName: f.name);
          } else {
            if (context.mounted) toast(context, '读取失败：无法获取所选文件的内容');
            return;
          }
          result = bm;
          if (context.mounted) Navigator.pop(context);
          if (context.mounted) {
            toast(context,
                '已导入：道路 ${bm.roads.length} · 建筑 ${bm.buildings.length} · 地名 ${bm.places.length}（项目级离线复用）');
          }
        } on FormatException catch (e) {
          if (context.mounted) toast(context, '所选文件不是有效的 GeoJSON：${e.message}');
        } on BasemapImportException catch (e) {
          if (context.mounted) toast(context, e.message);
        } catch (e) {
          if (context.mounted) toast(context, '导入失败：$e');
        }
      }, color: kGreen),
      darkTextBtn('读取剪贴板', () async {
        final data = await Clipboard.getData('text/plain');
        final t = data?.text ?? '';
        if (t.trim().isEmpty) {
          if (context.mounted) toast(context, '剪贴板为空');
          return;
        }
        ctl.text = t;
        if (context.mounted) toast(context, '已读入剪贴板内容，点「解析并导入」');
      }),
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('解析并导入', () async {
        final raw = ctl.text.trim();
        if (raw.isEmpty) {
          toast(context, '请先粘贴 GeoJSON 文本');
          return;
        }
        final BasemapData bm;
        try {
          bm = GeoJsonImporter.parse(raw);
        } catch (e) {
          toast(context, '解析失败：$e');
          return;
        }
        try {
          await BasemapFileImporter.importFromText(raw,
              sourceName: 'imported.geojson');
        } catch (e) {
          if (context.mounted) toast(context, '保存失败：$e');
          return;
        }
        result = bm;
        if (context.mounted) Navigator.pop(context);
        if (context.mounted) {
          toast(context,
              '已导入：道路 ${bm.roads.length} · 建筑 ${bm.buildings.length} · 地名 ${bm.places.length}（项目级离线复用）');
        }
      }),
    ],
  );
  return result;
}

/// 把本地底图元信息里的 `savedAt`（毫秒时间戳）格式化为「（YYYY-MM-DD HH:MM 导入）」；
/// 缺失/非法时返回空串（不显示）。
String _fmtMetaTime(dynamic savedAt) {
  if (savedAt is! int || savedAt <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(savedAt);
  String p(int v) => v.toString().padLeft(2, '0');
  return '（${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)} 导入）';
}
