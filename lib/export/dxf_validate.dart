import 'dxf_version.dart';

/// DXF **结构自洽校验器**（防复发闸门，纯 Dart、零依赖）。
///
/// ⚠️ **为什么需要它（血泪教训）**：上一轮只做了「字符串 matching」（例如断言文件里含
/// `AC1015`/`370`/`420`）就认为文件合法——结果产出的 R2000 文件其实是「R12 结构贴上
/// `AC1015` 标签」，AutoCAD/GstarCAD 等不同容错程度不同，用户「碰运气能打开」，
/// 被强行打开时还静默丢弃解析不了的实体（建筑填充 HATCH 首当其冲）。
/// **字符串匹配证明不了文件合法**，必须做「结构自洽 + 真实解析器（ezdxf）严格打开」。
///
/// 本校验器覆盖：
/// 1. 组码/值成对、组码为整型；
/// 2. `SECTION/ENDSEC` 配对与顺序合法（HEADER→[CLASSES]→TABLES→BLOCKS→ENTITIES→[OBJECTS]）；
/// 3. `TABLE/ENDTAB` 配对；
/// 4. 每个实体块结构自洽（LWPOLYLINE 顶点数一致；POLYLINE→VERTEX*→SEQEND 闭合；
///    HATCH 路径/顶点计数一致；TEXT/INSERT/SOLID 必需组码齐全）；
/// 5. 版本相关：R2000 必须有 `$HANDSEED`、OBJECTS 段、每个实体句柄(5)且**全局唯一**、
///    `100` 子类标记齐全；R12 严禁 `370/420/LWPOLYLINE/HATCH`。
///
/// 说明：本校验器是「自动化回归闸门」；**最终裁定以真实解析器为准**
/// （见 `tool/validate_dxf.py`，调用 ezdxf 严格 `readfile`）。
class DxfStructureValidator {
  DxfStructureValidator._();

  static final RegExp _intRe = RegExp(r'^-?\d+$');

  /// 校验并返回问题清单（空 = 通过）。
  static List<String> validate(String dxf, {required DxfVersion version}) {
    final problems = <String>[];
    final lines = dxf.split('\n');

    // ---- 0. 成对化 ----
    var end = lines.length;
    if (end > 0 && lines[end - 1].trim().isEmpty) end--; // 末尾换行产生的空串
    if (end.isOdd) {
      problems.add('组码/值不成对：有效行数 $end 为奇数，文件疑似被截断');
    }
    final codes = <String>[];
    final values = <String>[];
    for (var i = 0; i + 1 < end; i += 2) {
      final code = lines[i].trim();
      if (!_intRe.hasMatch(code)) {
        problems.add('第 ${i + 1} 行组码非整型：`$code`（组码/值疑似错位）');
        // 错位后继续解析无意义，直接返回。
        return problems;
      }
      codes.add(code);
      values.add(lines[i + 1]);
    }

    // ---- 1. 段与表扫描 ----
    final sectionOrder = <String>[];
    var section = '';
    var openSection = false;
    var openTable = false;
    var tableCount = 0, endTabCount = 0;
    final entities = <_Ent>[];
    _Ent? cur; // 仅收集 ENTITIES 段内的实体

    for (var k = 0; k < codes.length; k++) {
      final code = codes[k];
      final val = values[k];
      if (code == '0') {
        // 顶层结构标记（DXF 中组码 0 恒为结构分隔，文字内容在组码 1）
        switch (val.trim()) {
          case 'SECTION':
            if (openSection) {
              problems.add('SECTION 嵌套/未闭合：新 SECTION 出现时上一段未 ENDSEC');
            }
            openSection = true;
            section = '<unnamed>';
            names: while (k + 1 < codes.length) {
              if (codes[k + 1] == '2') {
                section = values[k + 1].trim();
                break names;
              }
              // SECTION 后第一个非 2 组码即异常
              if (codes[k + 1] == '0') break;
              break;
            }
            sectionOrder.add(section);
            continue;
          case 'ENDSEC':
            if (!openSection) problems.add('ENDSEC 出现在 SECTION 之外');
            openSection = false;
            section = '';
            continue;
          case 'TABLE':
            if (section != 'TABLES') {
              problems.add('TABLE 出现在 TABLES 段之外（当前段：$section）');
            }
            if (openTable) problems.add('TABLE 嵌套/未闭合');
            openTable = true;
            tableCount++;
            continue;
          case 'ENDTAB':
            if (!openTable) problems.add('ENDTAB 出现在 TABLE 之外');
            openTable = false;
            endTabCount++;
            continue;
        }
        // 其余组码 0 值 = 实体起始
        if (section == 'ENTITIES') {
          cur = _Ent(val.trim());
          entities.add(cur);
          continue;
        }
        // ENTITIES 段外的实体（BLOCKS 内块定义体等）不计入结构校验
        cur = null;
        continue;
      }
      if (cur != null && section == 'ENTITIES') {
        cur.kv.add([code, val]);
      }
    }

    if (openSection) problems.add('文件结束时仍有未闭合的 SECTION（缺 ENDSEC）');
    if (openTable) problems.add('文件结束时仍有未闭合的 TABLE（缺 ENDTAB）');
    if (tableCount != endTabCount) {
      problems.add('TABLE($tableCount) 与 ENDTAB($endTabCount) 数量不一致');
    }

    // ---- 2. 段顺序 ----
    _checkSectionOrder(sectionOrder, version, problems);

    // ---- 3. 实体结构自洽 ----
    _checkEntityBlocks(entities, problems);

    // ---- 4. 版本相关强约束 ----
    if (version == DxfVersion.r2000) {
      _checkR2000(codes, values, sectionOrder, entities, problems);
    } else {
      _checkR12(codes, values, entities, problems);
    }

    return problems;
  }

  /// 便捷布尔：结构自洽返回 true。
  static bool isValid(String dxf, {required DxfVersion version}) =>
      validate(dxf, version: version).isEmpty;

  static void _checkSectionOrder(
      List<String> order, DxfVersion version, List<String> problems) {
    const allowed = ['HEADER', 'CLASSES', 'TABLES', 'BLOCKS', 'ENTITIES', 'OBJECTS'];
    if (order.isEmpty || order.first != 'HEADER') {
      problems.add('缺少 HEADER 段（段序：$order）');
    }
    const mustHave = ['HEADER', 'TABLES', 'BLOCKS', 'ENTITIES'];
    for (final s in mustHave) {
      if (!order.contains(s)) problems.add('缺少必需段：$s');
    }
    if (version == DxfVersion.r2000 && !order.contains('OBJECTS')) {
      problems.add('R2000 缺 OBJECTS 段（R2000 必需）');
    }
    // 相对顺序
    var last = -1;
    for (final s in order) {
      final idx = allowed.indexOf(s);
      if (idx < 0) {
        problems.add('未知段名：$s');
        continue;
      }
      if (idx < last) {
        problems.add('段顺序非法：$s 出现在更靠后的段之后（段序：$order）');
      }
      last = idx;
    }
  }

  static void _checkEntityBlocks(List<_Ent> ents, List<String> problems) {
    var inPoly = false;
    var vertexCount = 0;
    for (final e in ents) {
      switch (e.type) {
        case 'POLYLINE':
          if (inPoly) problems.add('POLYLINE 嵌套（前一条缺 SEQEND）');
          inPoly = true;
          vertexCount = 0;
          break;
        case 'VERTEX':
          if (!inPoly) problems.add('孤儿 VERTEX（不在 POLYLINE 内）');
          vertexCount++;
          break;
        case 'SEQEND':
          if (!inPoly) {
            problems.add('没有 POLYLINE 的 SEQEND');
          } else if (vertexCount == 0) {
            problems.add('POLYLINE 无 VERTEX 顶点');
          }
          inPoly = false;
          break;
        case 'LWPOLYLINE':
          final n = int.tryParse(e.first('90') ?? '');
          final pts = e.all('10').length;
          if (n == null) {
            problems.add('LWPOLYLINE 缺组码 90（顶点数）');
          } else if (n != pts) {
            problems.add('LWPOLYLINE 顶点数不自洽：90=$n，实际 10 组码 $pts 个');
          }
          if (e.all('10').length != e.all('20').length) {
            problems.add('LWPOLYLINE 的 10/20 组码数量不一致');
          }
          break;
        case 'HATCH':
          final paths = int.tryParse(e.first('91') ?? '');
          if (paths == null) {
            problems.add('HATCH 缺组码 91（边界路径数）');
            break;
          }
          final n92 = e.all('92').length;
          final n73 = e.all('73').length;
          final n97 = e.all('97').length;
          if (n92 != paths || n73 != paths || n97 != paths) {
            problems.add('HATCH 路径计数不自洽：91=$paths，92=$n92，73=$n73，97=$n97');
          }
          final sum93 = e.all('93').fold<int>(0, (a, b) => a + (int.tryParse(b) ?? 0));
          if (e.all('10').length != sum93 || e.all('20').length != sum93) {
            problems.add('HATCH 顶点计数不自洽：Σ93=$sum93，'
                '10=${e.all('10').length}，20=${e.all('20').length}');
          }
          break;
        case 'TEXT':
          if (e.first('1') == null) problems.add('TEXT 缺组码 1（文字内容）');
          final h = double.tryParse(e.first('40') ?? '');
          if (h == null || h <= 0) problems.add('TEXT 缺/非法组码 40（字高）');
          break;
        case 'INSERT':
          if ((e.first('2') ?? '').isEmpty) problems.add('INSERT 缺组码 2（块名）');
          break;
        case 'SOLID':
          for (final g in ['10', '11', '12', '13']) {
            if (e.first(g) == null) {
              problems.add('SOLID 缺组码 $g（四顶点）');
              break;
            }
          }
          break;
      }
    }
    if (inPoly) problems.add('文件结束时仍有未闭合的 POLYLINE（缺 SEQEND）');
  }

  static void _checkR2000(
    List<String> codes,
    List<String> values,
    List<String> sectionOrder,
    List<_Ent> ents,
    List<String> problems,
  ) {
    // $ACADVER
    final ver = _headerVar(codes, values, r'$ACADVER');
    if (ver != 'AC1015') problems.add('R2000 \$ACADVER 应为 AC1015，实际：$ver');
    // $HANDSEED
    if (_headerVar(codes, values, r'$HANDSEED') == null) {
      problems.add('R2000 缺 HEADER 变量 \$HANDSEED');
    }
    if (!sectionOrder.contains('OBJECTS')) {
      problems.add('R2000 缺 OBJECTS 段');
    }
    // 每个实体：句柄 + 子类标记
    for (final e in ents) {
      final handle = e.first('5');
      if (handle == null || handle.trim().isEmpty) {
        problems.add('R2000 实体 ${e.type} 缺句柄(5)');
      }
      if (e.all('100').isEmpty) {
        problems.add('R2000 实体 ${e.type} 缺 100 子类标记');
      }
    }
    // 句柄全局唯一（含 TABLES/BLOCKS/OBJECTS 记录）。
    // 注意：`$HANDSEED` 自身也是 `5` 组码（其值不是句柄），须排除。
    final seedIdx = _handSeedValueIndex(codes, values);
    final seen = <String, int>{};
    var dup = 0;
    for (var k = 0; k < codes.length; k++) {
      if (codes[k] != '5' || k == seedIdx) continue;
      final hv = values[k].trim();
      if (hv.isEmpty) continue;
      if (seen.containsKey(hv)) {
        dup++;
      } else {
        seen[hv] = k;
      }
    }
    if (dup > 0) problems.add('R2000 存在重复句柄(5)：$dup 处');
    // $HANDSEED 必须大于所有已用句柄
    final seedStr = _headerVar(codes, values, r'$HANDSEED');
    final seed = seedStr == null ? null : int.tryParse(seedStr.trim(), radix: 16);
    if (seed != null) {
      var maxUsed = -1;
      for (var k = 0; k < codes.length; k++) {
        if (codes[k] != '5' || k == seedIdx) continue;
        final v = int.tryParse(values[k].trim(), radix: 16);
        if (v != null && v > maxUsed) maxUsed = v;
      }
      if (seed <= maxUsed) {
        problems.add('R2000 \$HANDSEED($seedStr=$seed) 未大于最大句柄($maxUsed)');
      }
    }
  }

  /// 定位 `$HANDSEED` 的取值在 values 中的下标（其值不是实体句柄）。
  static int _handSeedValueIndex(List<String> codes, List<String> values) {
    for (var k = 1; k < codes.length; k++) {
      if (codes[k] == '5' &&
          codes[k - 1] == '9' &&
          values[k - 1].trim() == r'$HANDSEED') {
        return k;
      }
    }
    return -1;
  }

  static void _checkR12(
    List<String> codes,
    List<String> values,
    List<_Ent> ents,
    List<String> problems,
  ) {
    final ver = _headerVar(codes, values, r'$ACADVER');
    if (ver != 'AC1009') problems.add('R12 \$ACADVER 应为 AC1009，实际：$ver');
    for (final e in ents) {
      if (e.type == 'LWPOLYLINE') problems.add('R12 不得出现 LWPOLYLINE 实体');
      if (e.type == 'HATCH') problems.add('R12 不得出现 HATCH 实体');
    }
    for (var k = 0; k < codes.length; k++) {
      if (codes[k] == '370' || codes[k] == '420') {
        problems.add('R12 不得出现组码 ${codes[k]}（R2000 专有）');
      }
    }
  }

  /// 读取 HEADER 段内某变量（如 `$ACADVER`）的第一个取值。
  ///
  /// 变量形如 `9,<name>,<valueCode>,<value>`——**取值组码不固定**
  /// （`$ACADVER`=1、`$HANDSEED`=5、`$DWGCODEPAGE`=3），故取 `9,<name>` 之后的下一对。
  static String? _headerVar(List<String> codes, List<String> values, String name) {
    for (var k = 0; k + 1 < codes.length; k++) {
      if (codes[k] == '9' && values[k].trim() == name) {
        return values[k + 1].trim();
      }
    }
    return null;
  }
}

/// 校验用轻量实体（组码/值序列）。
class _Ent {
  final String type;
  final List<List<String>> kv = [];
  _Ent(this.type);
  String? first(String c) {
    for (final p in kv) {
      if (p[0] == c) return p[1].trim();
    }
    return null;
  }

  List<String> all(String c) =>
      [for (final p in kv) if (p[0] == c) p[1].trim()];
}
