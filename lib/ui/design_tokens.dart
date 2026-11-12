/// 滑洲云图设计令牌（Design Tokens）—— 尺度与配色的**唯一真源**。
///
/// ## 为什么要有这个文件
///
/// 用户反馈"界面太粗糙"。根因不是审美，而是**没有统一尺度**：同样一排按钮，
/// 有的内边距是 6、有的是 8；同样是小标题，有的是 10.5px、有的是 11px；
/// 同样是输入框底色，写了两三个近似但不同的深灰。每个面板各自即兴发挥，
/// 单看每个都对，拼在一起就"差一点点"——那一点点就是粗糙感的来源。
///
/// 把尺度收敛成常量后，新增界面只需**挑令牌**，不必再发明数字。
///
/// ## 使用约定
///
/// - 间距取 [TokSp]（4 的倍数：4/8/12/16/24），不要再出现 5/7/9/14。
/// - 圆角取 [TokR]（6/8/12）。
/// - 字号取 [TokFs]（11/12/13/14/16），不要再出现 10.5/12.5/13.5。
/// - 颜色取 [TokC]。[dialogs.dart] 里的 `kXxx` 已改为本类的**转发别名**，
///   历史调用点一行都不用改。
///
/// ## 与 Dart 常量转发的关系
///
/// `const Color kAccent = TokC.accent;` 这种转发是**编译期常量**，不产生额外
/// 运行时开销，也不会改变任何既有行为；它只是让"名字还留在老地方、值只此一份"。
library;

import 'package:flutter/widgets.dart';

/// 间距（spacing）。全部为 4 的倍数。
class TokSp {
  TokSp._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;

  /// 区块之间的竖向间隔（比 [l] 略大，用于"换话题"）。
  static const double section = 18;

  /// 面板内容区统一内边距。
  static const EdgeInsets panelPad = EdgeInsets.fromLTRB(12, 12, 12, 20);

  /// 面板标题行统一内边距。
  static const EdgeInsets titlePad = EdgeInsets.fromLTRB(14, 12, 8, 6);

  /// 紧凑列表行统一内边距。
  static const EdgeInsets rowPad =
      EdgeInsets.symmetric(horizontal: 10, vertical: 6);
}

/// 圆角（corner radius）。
class TokR {
  TokR._();

  /// 小控件：标签、色块、徽标。
  static const double s = 6;

  /// 常规控件：输入框、卡片、按钮。
  static const double m = 8;

  /// 容器：面板、弹层。
  static const double l = 12;
}

/// 字号（font size）。
///
/// ## 为什么只有 6 档
/// 收敛前全项目出现过 9 / 9.5 / 10 / 10.5 / 11 / 11.5 / 12 / 12.5 / 13 / 13.5 / 15
/// 共 **11 档**字号。相邻两档差 0.5px 肉眼几乎不可分辨，却让每一处界面都在"再微调
/// 一点点"，最后整体看着不齐——这正是用户说的"界面太粗糙"。
///
/// 现在只剩 6 档，档差 ≥1px，层级一眼可辨：micro < caption < small < body < title < heading。
class TokFs {
  TokFs._();

  /// 极小：密集列表里的序号、单位、徽标（左栏 220px 宽时必须用这一档）。
  static const double micro = 10;

  /// 辅助说明、单位、计数。
  static const double caption = 11;

  /// 次要文字、次要按钮。
  static const double small = 12;

  /// 正文、表单输入。
  static const double body = 13;

  /// 强调正文、表单标题。
  static const double title = 14;

  /// 面板标题。
  static const double heading = 15;
}

/// 语义色。**浅色单主题**（应用强制白色，宿主层 `NSApp.appearance = lightAqua`，
/// 与系统深浅模式解耦——用户明确要求白底，不随系统切换）。
class TokC {
  TokC._();

  // ---- 容器 ----
  /// 弹层/对话框底：接近纯白的半透明，底下地图仍隐约可见。
  static const Color panel = Color(0xFAF9FAFB);

  /// 常驻侧栏底（不透明，避免侧栏透出地图造成"脏"感）。
  static const Color panelSolid = Color(0xFFF2F4F6);

  /// 浮起卡片/列表项底。
  static const Color card = Color(0xFFFFFFFF);

  /// 输入框填充底。
  static const Color field = Color(0xFFECEFF2);

  /// 顶栏底。
  static const Color bar = Color(0xF7FFFFFF);

  /// 工具栏底。
  static const Color toolbar = Color(0xFFF7F8FA);

  // ---- 前景 ----
  /// 主文字。
  static const Color textMain = Color(0xFF1C242C);

  /// 次要文字。
  static const Color textSub = Color(0xFF4A5560);

  /// 提示/占位文字。
  static const Color textHint = Color(0xFF8A949E);

  // ---- 强调与状态 ----
  // 在白底上，原来深色主题的亮色（40C4FF 等）对比度不足，统一换成
  // 同色系更深的档位——色相不变，只提"墨量"，视觉识别连续。

  /// 主题强调色（青蓝）。
  static const Color accent = Color(0xFF0288D1);

  /// 成功 / 通过。
  static const Color ok = Color(0xFF2E7D32);

  /// 警示（竣工模式、超限）。
  static const Color warn = Color(0xFFE65100);

  /// 危险 / 错误（删除、体检 error）。
  static const Color danger = Color(0xFFD32F2F);

  /// 分隔线。
  static const Color divider = Color(0x1F000000);

  // ---- 领域语义色：敷设方式色标 ----
  //
  // 与 `RouteSegment.kindName` / `GeoUtil.kindPrefixOf` 的枚举同源
  // （0默认 / 1架空 / 2埋地 / 3管道）。左栏段落表、图例、统计区共用同一套色，
  // 避免"图上绿线是架空、表里绿点是埋地"这种自相矛盾的图例。
  //
  // 注意：这组颜色同时出现在**地图上**（图例 / 连线色标），底是影像不是 UI，
  // 因此保持中亮度——白底下做 chip 背景配黑字也够读。

  /// 架空。
  static const Color kindOverhead = Color(0xFF43A047);

  /// 埋地。
  static const Color kindBuried = Color(0xFFFB8C00);

  /// 管道。
  static const Color kindDuct = Color(0xFF039BE5);

  /// 敷设方式 → 色标。
  static Color kind(int k) => switch (k) {
        1 => kindOverhead,
        2 => kindBuried,
        3 => kindDuct,
        _ => textHint,
      };
}
