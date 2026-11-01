import 'dart:convert';

/// 单个备份项的执行日志（一次收集或一次还原）。
class BackupItemLog {
  const BackupItemLog({
    required this.key,
    required this.action,
    required this.ok,
    this.count = 0,
    this.durationMs = 0,
    this.error,
  });

  /// 备份包键名（见 `BackupCatalog.payloadKey`）
  final String key;

  /// 'collect'（导出时收集）| 'apply'（导入时还原）
  final String action;

  final bool ok;

  /// 条目数（记录 / 站点 / 链接 / 快照数量）
  final int count;

  final int durationMs;

  /// 失败原因（ok=false 时必有）
  final String? error;

  Map<String, dynamic> toMap() => {
    'key': key,
    'action': action,
    'ok': ok,
    'count': count,
    'durationMs': durationMs,
    if (error != null) 'error': error,
  };

  factory BackupItemLog.fromMap(Map<String, dynamic> map) => BackupItemLog(
    key: map['key']?.toString() ?? '',
    action: map['action']?.toString() ?? '',
    ok: map['ok'] == true,
    count: (map['count'] as num?)?.toInt() ?? 0,
    durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
    error: map['error']?.toString(),
  );

  /// 一行摘要：`shortcuts apply ok 3 项 12ms`
  String get summary =>
      '$key $action ${ok ? 'ok' : 'FAIL'} $count 项 ${durationMs}ms'
      '${error == null ? '' : ' — $error'}';
}

/// 一次备份/恢复运行的完整日志。
class BackupRunLogEntry {
  const BackupRunLogEntry({
    required this.id,
    required this.at,
    required this.phase,
    required this.trigger,
    required this.ok,
    required this.items,
    this.keys = const {},
    this.durationMs = 0,
    this.detail = '',
  });

  /// 运行 id（时间戳 base36，用于在日志列表里定位）
  final String id;

  final DateTime at;

  /// 'export' | 'import'
  final String phase;

  /// 'manual' | 'web' | 'scheduled' | 'legacy'
  final String trigger;

  /// 整体是否成功（所有子项都成功才算）
  final bool ok;

  /// 本次涉及的备份包键
  final Set<String> keys;

  final List<BackupItemLog> items;

  final int durationMs;

  /// 额外说明（文件来源、服务器响应、跳过项等）
  final String detail;

  int get totalCount => items.fold(0, (s, e) => s + e.count);

  int get failedCount => items.where((e) => !e.ok).length;

  Map<String, dynamic> toMap() => {
    'id': id,
    'at': at.toIso8601String(),
    'phase': phase,
    'trigger': trigger,
    'ok': ok,
    'keys': keys.toList(),
    'durationMs': durationMs,
    'detail': detail,
    'items': items.map((e) => e.toMap()).toList(),
  };

  factory BackupRunLogEntry.fromMap(Map<String, dynamic> map) =>
      BackupRunLogEntry(
        id: map['id']?.toString() ?? '',
        at: DateTime.tryParse(map['at']?.toString() ?? '') ?? DateTime.now(),
        phase: map['phase']?.toString() ?? 'export',
        trigger: map['trigger']?.toString() ?? 'manual',
        ok: map['ok'] == true,
        keys: ((map['keys'] as List?) ?? const [])
            .map((e) => e.toString())
            .toSet(),
        durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
        detail: map['detail']?.toString() ?? '',
        items: ((map['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => BackupItemLog.fromMap(e.cast<String, dynamic>()))
            .toList(),
      );

  /// 人类可读的一行摘要（日志列表标题）
  String get title =>
      '${phase == 'export' ? '备份' : '恢复'} · ${_triggerLabel(trigger)} · '
      '${ok ? '成功' : '部分失败'} · ${items.length} 项';

  String get subtitle =>
      '$totalCount 条目 · ${durationMs}ms'
      '${detail.isEmpty ? '' : ' · $detail'}';

  static String _triggerLabel(String t) => switch (t) {
    'web' => 'Web 手动',
    'scheduled' => 'Web 定时',
    'legacy' => '旧格式',
    _ => '手动',
  };

  /// 导出为纯文本（日志分享 / 排障用）
  String toText() {
    final b = StringBuffer()
      ..writeln('[$id] ${at.toIso8601String()} $title')
      ..writeln('  键: ${keys.join(', ')}');
    if (detail.isNotEmpty) b.writeln('  说明: $detail');
    for (final it in items) {
      b.writeln('  - ${it.summary}');
    }
    return b.toString();
  }

  /// 导出为 JSON（可被日志查看页复制）
  String toJsonText() => const JsonEncoder.withIndent('  ').convert(toMap());
}
