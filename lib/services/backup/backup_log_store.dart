import 'dart:convert';

import 'package:mtbbs/core/utils/database_helper.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/models/backup/backup_log_entry.dart';

/// 备份运行日志仓库（环形保留，落盘在 `app_settings` KV 的
/// `backup_run_log` 键）。
///
/// 设计取舍：
/// - 只保留最近 [maxEntries] 条 + 超过 [keepDays] 天的自动清理，
///   避免备份跑一年把数据库写爆；
/// - 单条日志本身就是 JSON，读取时整体反序列化（条数上限很小，无性能问题）；
/// - 所有读写异常都吞掉并记 [AppLogger]，日志坏掉不能影响备份主流程。
class BackupLogStore {
  BackupLogStore._();

  static final BackupLogStore instance = BackupLogStore._();

  /// 最多保留的日志条数
  static const int maxEntries = 50;

  DatabaseHelper get _db => DatabaseHelper.instance;

  List<BackupRunLogEntry> _cache = const [];

  /// 读取全部日志（最新在前）
  Future<List<BackupRunLogEntry>> all() async {
    final raw = await _db.getBackupLogRaw();
    if (raw == null || raw.isEmpty) {
      _cache = const [];
      return _cache;
    }
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      _cache = [
        for (final e in list)
          if (e is Map) BackupRunLogEntry.fromMap(e.cast<String, dynamic>()),
      ]..sort((a, b) => b.at.compareTo(a.at));
      return _cache;
    } catch (e) {
      AppLogger.w('BACKUP', '读取运行日志失败: $e');
      return const [];
    }
  }

  /// 追加一条日志并按 [keepDays] 清理（返回清理后的列表）
  Future<List<BackupRunLogEntry>> add(
    BackupRunLogEntry entry, {
    int keepDays = 30,
  }) async {
    try {
      final current = await all();
      final cutoff = keepDays > 0
          ? DateTime.now().subtract(Duration(days: keepDays))
          : null;
      final kept = <BackupRunLogEntry>[
        entry,
        for (final e in current)
          if (cutoff == null || e.at.isAfter(cutoff)) e,
      ];
      final capped = kept.length > maxEntries
          ? kept.sublist(0, maxEntries)
          : kept;
      await _db.setBackupLogRaw(
        jsonEncode(capped.map((e) => e.toMap()).toList()),
      );
      _cache = capped;
      AppLogger.i('BACKUP', '记录运行日志 ${entry.id}（保留 ${capped.length} 条）');
      return capped;
    } catch (e) {
      AppLogger.w('BACKUP', '写入运行日志失败: $e');
      return _cache;
    }
  }

  Future<void> clear() async {
    try {
      await _db.clearBackupLog();
      _cache = const [];
    } catch (e) {
      AppLogger.w('BACKUP', '清空运行日志失败: $e');
    }
  }

  /// 导出全部日志为纯文本（供「导出日志」按钮 / Web 备份 logs 模块）
  Future<String> exportText() async {
    final list = await all();
    if (list.isEmpty) return '（暂无备份日志）';
    final b = StringBuffer('MTBBS 备份日志（${list.length} 条）\n');
    for (final e in list) {
      b.write(e.toText());
    }
    return b.toString();
  }

  /// 导出为 JSON 结构（Web 备份 `logs` 模块用）
  Future<Map<String, dynamic>> exportJson() async {
    final list = await all();
    return {
      'exportedAt': DateTime.now().toIso8601String(),
      'entries': list.map((e) => e.toMap()).toList(),
    };
  }
}
