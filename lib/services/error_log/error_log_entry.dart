/// 一条错误记录。
///
/// 字段刻意保持最小：时间、错误文案、堆栈、来源与可选上下文。
/// 序列化成 JSON Lines 的一行写入 `{appDataDir}/error_logs.json`，
/// 与 PiliPlus 的 `.pili_logs.json` 同一思路：**追加写不重写历史**，
/// 读取时逐行 `jsonDecode`，单行损坏只丢那一条，不会整份日志不可读。
class ErrorLogEntry {
  const ErrorLogEntry({
    required this.at,
    required this.error,
    this.stackTrace,
    this.source = '',
    this.context = const {},
  });

  /// 发生时间（本地时区）
  final DateTime at;

  /// 错误文案（通常是 `toString()` 的结果）
  final String error;

  /// 堆栈（可能为空：部分 `throw` 不带堆栈，或平台侧只回传消息）
  final String? stackTrace;

  /// 来源标记：`Flutter 框架` / `异步未捕获` / `手动上报` 等
  final String source;

  /// 附加信息（键值均为字符串，便于直接展示与复制）
  final Map<String, String> context;

  /// 卡片标题：错误文案首个非空行，过长时由 UI 做 ellipsis
  String get title {
    for (final line in error.split('\n')) {
      final t = line.trim();
      if (t.isNotEmpty) return t;
    }
    return '空错误';
  }

  Map<String, dynamic> toMap() => {
    'at': at.toIso8601String(),
    'error': error,
    if (stackTrace != null && stackTrace!.isNotEmpty) 'stack': stackTrace,
    if (source.isNotEmpty) 'source': source,
    if (context.isNotEmpty) 'context': context,
  };

  /// 容错解析：任何字段类型不对都取默认值，不抛异常。
  ///
  /// 日志文件是长期累积的，格式演进（比如以后加字段）不该让旧记录整批失效。
  factory ErrorLogEntry.fromMap(Map<String, dynamic> map) {
    final rawAt = map['at']?.toString();
    final ctx = <String, String>{};
    final rawCtx = map['context'];
    if (rawCtx is Map) {
      rawCtx.forEach((k, v) => ctx[k.toString()] = v?.toString() ?? '');
    }
    return ErrorLogEntry(
      at: DateTime.tryParse(rawAt ?? '')?.toLocal() ?? DateTime.now(),
      error: map['error']?.toString() ?? '',
      stackTrace: map['stack']?.toString(),
      source: map['source']?.toString() ?? '',
      context: ctx,
    );
  }

  /// 完整文本：用于「复制」与导出。
  ///
  /// 刻意不用 markdown 代码块包裹：调用方按需加围栏，避免嵌套时多一层。
  String format() {
    final b = StringBuffer();
    b.writeln('时间: ${formatDateTime(at)}');
    if (source.isNotEmpty) b.writeln('来源: $source');
    for (final e in context.entries) {
      b.writeln('${e.key}: ${e.value}');
    }
    b.writeln('错误: $error');
    final stack = stackTrace?.trim() ?? '';
    if (stack.isNotEmpty) {
      b.writeln();
      b.writeln('堆栈:');
      b.write(stack);
    }
    return b.toString().trimRight();
  }

  /// `2026-11-22 21:30:05`
  static String formatDateTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
