import 'package:mtbbs/models/backup/backup_item.dart';
import 'package:mtbbs/platform/optional/secure_store.dart';

/// 备份相关设置 —— 持久化在 `AppSettings.backup` 子文档。
///
/// 项目铁律禁止新增 SharedPreferences（见 AGENTS.md #5），因此勾选状态、
/// Web 备份服务器配置全部走 `settings_app` 文档（等价 DataStore）。
class BackupSettings {
  /// 用户勾选的备份项（只存叶子 id）
  final Set<BackupItemId> selected;

  /// Web 备份总开关
  final bool webEnabled;

  /// 用户自备服务器配置（本应用不提供任何托管服务）
  final WebBackupConfig web;

  /// 运行日志保留天数（0 = 不保留）
  final int logKeepDays;

  /// 上次成功备份时间（ISO8601，'' = 从未）
  final String lastBackupAt;

  const BackupSettings({
    required this.selected,
    this.webEnabled = false,
    this.web = const WebBackupConfig(),
    this.logKeepDays = 30,
    this.lastBackupAt = '',
  });

  factory BackupSettings.defaults() =>
      BackupSettings(selected: BackupCatalog.defaults);

  /// 旧文档没有 `backup` 键时整体回落默认值（向后兼容唯一入口）
  factory BackupSettings.fromMap(Map<String, dynamic>? map) {
    if (map == null || map.isEmpty) return BackupSettings.defaults();
    final d = BackupSettings.defaults();
    final raw = map['selected'];
    return BackupSettings(
      selected: raw is List
          ? BackupSelection.fromNames(raw.map((e) => e.toString())).ids
          : d.selected,
      webEnabled: map['webEnabled'] as bool? ?? d.webEnabled,
      web: WebBackupConfig.fromMap(
        (map['web'] as Map?)?.cast<String, dynamic>(),
      ),
      logKeepDays: (map['logKeepDays'] as num?)?.toInt() ?? d.logKeepDays,
      lastBackupAt: map['lastBackupAt']?.toString() ?? d.lastBackupAt,
    );
  }

  Map<String, dynamic> toMap() => {
    'selected': {for (final id in selected) id.name}.toList(),
    'webEnabled': webEnabled,
    'web': web.toMap(),
    'logKeepDays': logKeepDays,
    'lastBackupAt': lastBackupAt,
  };

  /// 当前选中项（构造 [BackupSelection] 供 UI / 服务使用）
  BackupSelection get selection => BackupSelection(selected);

  BackupSettings copyWith({
    Set<BackupItemId>? selected,
    bool? webEnabled,
    WebBackupConfig? web,
    int? logKeepDays,
    String? lastBackupAt,
  }) => BackupSettings(
    selected: selected ?? this.selected,
    webEnabled: webEnabled ?? this.webEnabled,
    web: web ?? this.web,
    logKeepDays: logKeepDays ?? this.logKeepDays,
    lastBackupAt: lastBackupAt ?? this.lastBackupAt,
  );
}

/// 定时备份的调度单位。
///
/// 用「数值 + 单位」而不是裸分钟：用户要的是「一周一次」，让他自己算 10080 分钟
/// 既反人类也容易算错。系统侧统一换算成分钟交给 WorkManager。
enum BackupIntervalUnit {
  minutes,
  hours,
  days,
  weeks;

  String get label => switch (this) {
    BackupIntervalUnit.minutes => '分钟',
    BackupIntervalUnit.hours => '小时',
    BackupIntervalUnit.days => '天',
    BackupIntervalUnit.weeks => '周',
  };

  int get multiplier => switch (this) {
    BackupIntervalUnit.minutes => 1,
    BackupIntervalUnit.hours => 60,
    BackupIntervalUnit.days => 60 * 24,
    BackupIntervalUnit.weeks => 60 * 24 * 7,
  };

  static BackupIntervalUnit fromName(String? name) =>
      BackupIntervalUnit.values.firstWhere(
        (e) => e.name == name,
        orElse: () => BackupIntervalUnit.days,
      );
}

/// 系统级定时备份的约束策略。
class BackupSchedulePolicy {
  /// 间隔数值（配合 [unit]；0 = 关闭定时）
  final int interval;

  final BackupIntervalUnit unit;

  /// 只在充电时执行（省电，适合日/周级备份）
  final bool requireCharging;

  /// 只在电量不低时执行
  final bool requireBatteryNotLow;

  /// 上次成功执行时间（ISO8601，'' = 从未）
  final String lastRunAt;

  /// 上次执行结果简述
  final String lastResult;

  const BackupSchedulePolicy({
    this.interval = 0,
    this.unit = BackupIntervalUnit.days,
    this.requireCharging = false,
    this.requireBatteryNotLow = true,
    this.lastRunAt = '',
    this.lastResult = '',
  });

  /// 间隔换算成分钟（0 = 不定时）
  int get intervalMinutes => interval <= 0 ? 0 : interval * unit.multiplier;

  bool get enabled => intervalMinutes > 0;

  /// 人类可读间隔，如「1 周」「6 小时」
  String get label => enabled ? '$interval ${unit.label}' : '关闭';

  /// WorkManager 的周期下限是 15 分钟；更小的值会被系统自动抬到 15。
  ///
  /// 这里不静默改用户的输入，而是在 UI 上提示，并在这里老实返回真实生效值，
  /// 让「日志里写的周期」= 「系统实际周期」。
  Duration get effectiveFrequency {
    final minutes = intervalMinutes < 15 ? 15 : intervalMinutes;
    return Duration(minutes: minutes);
  }

  Map<String, dynamic> toMap() => {
    'interval': interval,
    'unit': unit.name,
    'requireCharging': requireCharging,
    'requireBatteryNotLow': requireBatteryNotLow,
    'lastRunAt': lastRunAt,
    'lastResult': lastResult,
  };

  factory BackupSchedulePolicy.fromMap(Map<String, dynamic>? map) {
    if (map == null || map.isEmpty) return const BackupSchedulePolicy();
    const d = BackupSchedulePolicy();
    return BackupSchedulePolicy(
      interval: (map['interval'] as num?)?.toInt() ?? d.interval,
      unit: BackupIntervalUnit.fromName(map['unit']?.toString()),
      requireCharging: map['requireCharging'] as bool? ?? d.requireCharging,
      requireBatteryNotLow:
          map['requireBatteryNotLow'] as bool? ?? d.requireBatteryNotLow,
      lastRunAt: map['lastRunAt']?.toString() ?? d.lastRunAt,
      lastResult: map['lastResult']?.toString() ?? d.lastResult,
    );
  }

  BackupSchedulePolicy copyWith({
    int? interval,
    BackupIntervalUnit? unit,
    bool? requireCharging,
    bool? requireBatteryNotLow,
    String? lastRunAt,
    String? lastResult,
  }) => BackupSchedulePolicy(
    interval: interval ?? this.interval,
    unit: unit ?? this.unit,
    requireCharging: requireCharging ?? this.requireCharging,
    requireBatteryNotLow: requireBatteryNotLow ?? this.requireBatteryNotLow,
    lastRunAt: lastRunAt ?? this.lastRunAt,
    lastResult: lastResult ?? this.lastResult,
  );
}

/// Web 备份服务器配置（用户自备：自建 HTTP 接口 / NAS / WebDAV 网关）。
class WebBackupConfig {
  /// 上传地址（POST/PUT 到该 URL，body 为备份包 JSON）
  final String url;

  /// 'POST' | 'PUT'
  final String method;

  /// 鉴权头名（默认 Authorization，可填 `X-Api-Key` 等）
  final String headerName;

  /// 鉴权头值（如 `Bearer xxx`）。
  ///
  /// [secretMode] 为 [SecretStoreMode.secure] 时这里是**空串**，
  /// 真值在系统密钥库里（见 `SecretStore`）。明文模式下才落这里。
  final String headerValue;

  /// 鉴权头值的存储方式（明文 / 系统密钥库）
  final SecretStoreMode secretMode;

  /// 仅 Wi-Fi 下上传
  final bool wifiOnly;

  /// 是否把运行日志一并上传（`logs` 模块）
  final bool includeLogs;

  /// 系统级定时备份策略（分钟/小时/天/周）
  final BackupSchedulePolicy schedule;

  /// 上次上传时间（ISO8601，'' = 从未）
  final String lastRunAt;

  /// 上次上传结果简述（'ok' / 'failed: ...'）
  final String lastResult;

  const WebBackupConfig({
    this.url = '',
    this.method = 'POST',
    this.headerName = 'Authorization',
    this.headerValue = '',
    this.secretMode = SecretStoreMode.plain,
    this.wifiOnly = false,
    this.includeLogs = false,
    this.schedule = const BackupSchedulePolicy(),
    this.lastRunAt = '',
    this.lastResult = '',
  });

  /// 地址是否可用（能被 Uri 解析）
  bool get usable {
    final uri = Uri.tryParse(url.trim());
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  /// 定时备份是否开启
  bool get scheduled => schedule.enabled;

  /// 兼容旧字段：定时间隔（分钟）
  int get intervalMinutes => schedule.intervalMinutes;

  /// 是否已配置鉴权头（明文模式看字段，加密模式看密钥库里有没有）
  bool get hasAuthHeader => headerName.trim().isNotEmpty;

  Map<String, dynamic> toMap() => {
    'url': url,
    'method': method,
    'headerName': headerName,
    // 加密模式下不把真值写进设置文档（写空串），避免「以为加密了其实还留了一份」
    'headerValue': secretMode == SecretStoreMode.secure ? '' : headerValue,
    'secretMode': secretMode.name,
    'wifiOnly': wifiOnly,
    'includeLogs': includeLogs,
    'schedule': schedule.toMap(),
    'lastRunAt': lastRunAt,
    'lastResult': lastResult,
  };

  factory WebBackupConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null || map.isEmpty) return const WebBackupConfig();
    const d = WebBackupConfig();
    // 兼容：老文档只有 intervalMinutes，没有 schedule 子文档
    final rawSchedule = (map['schedule'] as Map?)?.cast<String, dynamic>();
    final legacyMinutes = (map['intervalMinutes'] as num?)?.toInt() ?? 0;
    final schedule = rawSchedule != null
        ? BackupSchedulePolicy.fromMap(rawSchedule)
        : (legacyMinutes > 0
              ? BackupSchedulePolicy(
                  interval: legacyMinutes,
                  unit: BackupIntervalUnit.minutes,
                )
              : const BackupSchedulePolicy());
    return WebBackupConfig(
      url: map['url']?.toString() ?? d.url,
      method: (map['method']?.toString() ?? d.method).toUpperCase(),
      headerName: map['headerName']?.toString() ?? d.headerName,
      headerValue: map['headerValue']?.toString() ?? d.headerValue,
      secretMode: SecretStoreMode.fromName(map['secretMode']?.toString()),
      wifiOnly: map['wifiOnly'] as bool? ?? d.wifiOnly,
      includeLogs: map['includeLogs'] as bool? ?? d.includeLogs,
      schedule: schedule,
      lastRunAt: map['lastRunAt']?.toString() ?? d.lastRunAt,
      lastResult: map['lastResult']?.toString() ?? d.lastResult,
    );
  }

  WebBackupConfig copyWith({
    String? url,
    String? method,
    String? headerName,
    String? headerValue,
    SecretStoreMode? secretMode,
    bool? wifiOnly,
    bool? includeLogs,
    BackupSchedulePolicy? schedule,
    String? lastRunAt,
    String? lastResult,
  }) => WebBackupConfig(
    url: url ?? this.url,
    method: method ?? this.method,
    headerName: headerName ?? this.headerName,
    headerValue: headerValue ?? this.headerValue,
    secretMode: secretMode ?? this.secretMode,
    wifiOnly: wifiOnly ?? this.wifiOnly,
    includeLogs: includeLogs ?? this.includeLogs,
    schedule: schedule ?? this.schedule,
    lastRunAt: lastRunAt ?? this.lastRunAt,
    lastResult: lastResult ?? this.lastResult,
  );
}
