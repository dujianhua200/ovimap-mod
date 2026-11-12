import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

/// 设备身份与同步配置（架构文档 §4.8 / C1）。
///
/// 不做账号体系：单用户共享一个 Worker Secret `SYNC_TOKEN`，每台设备本地保存自己的
/// `deviceId` / `deviceName`，用户在设置页手动粘贴「同步令牌 + 服务器地址」。
///
/// - 持久化走 `shared_preferences`（**零新增依赖**，硬约束 1）。
/// - `deviceId` 用「时间戳 + 随机数」生成（**不引入 `crypto`**，满足硬约束 1）。
///
/// ⚠️ **安全知情**：同步令牌以**明文**存于本机偏好设置（`shared_preferences` 的
/// `syncToken` 键）—— v1「单用户自用 + 零新增依赖」约束下的既定取舍（架构文档
/// §4.8）；设备丢失/转手时请先在 Worker 侧轮换 `SYNC_TOKEN`。升级为系统安全存储
/// （如 `flutter_secure_storage`）需先松绑「零新增依赖」约束，属 P2 决策。
class DeviceIdentity {
  DeviceIdentity();

  /// 生产用全局单例。
  static final DeviceIdentity instance = DeviceIdentity();

  // ---- 偏好键 ----
  static const kDeviceId = 'syncDeviceId';
  static const kDeviceName = 'syncDeviceName';
  static const kToken = 'syncToken';
  static const kServerBase = 'syncServerBase';

  String deviceId = '';
  String deviceName = '';
  String token = '';
  String serverBase = '';

  bool _loaded = false;

  /// 是否为「临时注入」身份（测试/注入）：为 true 时 [load] 不再读 prefs、
  /// [saveConfig] 不落盘，避免测试被真实 prefs 覆盖。
  bool ephemeral = false;

  /// 是否已从本地加载过。
  bool get loaded => _loaded;

  /// 是否已配置可用的同步（令牌 + 服务器地址都非空）。
  bool get configured =>
      _loaded && token.trim().isNotEmpty && serverBase.trim().isNotEmpty;

  /// 测试/注入用：直接给定身份并标记已加载（绕过 prefs）。
  factory DeviceIdentity.forTest({
    String deviceId = 'dev-test',
    String deviceName = '测试设备',
    String token = 'tok-test',
    String serverBase = 'https://sync.example.com',
  }) {
    return DeviceIdentity()
      ..deviceId = deviceId
      ..deviceName = deviceName
      ..token = token
      ..serverBase = serverBase
      ..ephemeral = true
      .._loaded = true;
  }

  /// 从 `shared_preferences` 加载；缺 `deviceId`/`deviceName` 时自动生成/取名。
  ///
  /// [prefs] 可注入（测试用）；缺省取 `SharedPreferences.getInstance()`。
  Future<void> load({SharedPreferences? prefs}) async {
    if (ephemeral) {
      _loaded = true;
      return;
    }
    final p = prefs ?? await SharedPreferences.getInstance();
    deviceId = p.getString(kDeviceId)?.trim() ?? '';
    deviceName = p.getString(kDeviceName)?.trim() ?? '';
    token = p.getString(kToken)?.trim() ?? '';
    serverBase = normalizeBase(p.getString(kServerBase) ?? '');
    if (deviceId.isEmpty) deviceId = newDeviceId();
    if (deviceName.isEmpty) deviceName = defaultDeviceName();
    _loaded = true;
    // 首次生成的身份落盘，避免每次重启都换 id。
    if (p.getString(kDeviceId)?.trim() != deviceId ||
        (p.getString(kDeviceName)?.trim() ?? '').isEmpty) {
      await _persist(p);
    }
  }

  Future<void> _persist([SharedPreferences? prefs]) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    await p.setString(kDeviceId, deviceId);
    await p.setString(kDeviceName, deviceName);
    await p.setString(kToken, token);
    await p.setString(kServerBase, serverBase);
  }

  /// 保存同步配置（令牌 / 服务器地址 / 设备名），并落盘。
  ///
  /// 传 `null` 表示该项不变；服务器地址会被 [normalizeBase] 规范化。
  Future<void> saveConfig({
    String? token,
    String? serverBase,
    String? deviceName,
    SharedPreferences? prefs,
  }) async {
    if (token != null) this.token = token.trim();
    if (serverBase != null) this.serverBase = normalizeBase(serverBase);
    if (deviceName != null && deviceName.trim().isNotEmpty) {
      this.deviceName = deviceName.trim();
    }
    if (deviceId.isEmpty) deviceId = newDeviceId();
    if (this.deviceName.isEmpty) this.deviceName = defaultDeviceName();
    _loaded = true;
    if (!ephemeral) await _persist(prefs);
  }

  /// 生成设备码：`dev-<epochms 的 36 进制>-<8 位随机>`（无需 crypto）。
  static String newDeviceId() {
    final rnd = math.Random();
    const chars = '0123456789abcdef';
    final buf = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buf.write(chars[rnd.nextInt(chars.length)]);
    }
    return 'dev-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-'
        '${buf.toString()}';
  }

  /// 默认设备名：桌面 `电脑-<主机名>`，移动 `手机`，其余 `设备`。
  static String defaultDeviceName() {
    try {
      if (Platform.isWindows) {
        final h = (Platform.environment['COMPUTERNAME'] ??
                Platform.environment['USERNAME'] ??
                '')
            .trim();
        return '电脑-${h.isEmpty ? '本机' : h}';
      }
    } catch (_) {}
    try {
      if (Platform.isAndroid || Platform.isIOS) return '手机';
    } catch (_) {}
    return '设备';
  }

  /// 规范化服务器基址：去空白、无协议时补 `https://`、去尾部 `/`。
  static String normalizeBase(String s) {
    var v = s.trim();
    if (v.isEmpty) return '';
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      v = 'https://$v';
    }
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }
}
