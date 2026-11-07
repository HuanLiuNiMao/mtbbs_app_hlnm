import 'dart:convert';

import 'package:mtbbs/core/utils/database_helper.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/models/settings/backup_settings.dart';

/// 备份设置的独立持久化层。
///
/// ## 为什么单独存一个 KV 键，而不是挂在 `AppSettings.backup`
///
/// 备份/恢复是本 fork 相对上游的**附加能力**，上游并没有
/// `AppSettings.backup` 字段。把它塞进 `AppSettings` 会导致：
///
/// 1. `AppSettings` 成为双方高频改动且结构不同的文件，每次上游合并都在
///    `defaults()` / `copyWith()` / `toMap()` / `fromMap()` 四处产生冲突；
/// 2. 上游若调整 `AppSettings` 的子文档顺序或新增字段，冲突会更难解。
///
/// 因此这里改用独立 KV 键 `backupSettings`（与 `commentFilter`、
/// `threadScopeFilter_*` 同范式：fork 专属配置一律走独立键，
/// 不碰上游的文档结构）。
///
/// 旧数据（v2 备份包之前写进 `app_settings.backup` 的）在 [load] 里做一次
/// 惰性迁移：读不到新键时回落到旧位置，读到就立刻写到新键，之后不再回看。
class BackupSettingsStore {
  BackupSettingsStore._();

  static final BackupSettingsStore instance = BackupSettingsStore._();

  /// 独立 KV 键
  static const String storageKey = 'backupSettings';

  /// 旧位置（`app_settings` 文档里的 `backup` 子文档），仅用于迁移
  static const String legacyField = 'backup';

  BackupSettings? _cache;

  /// 同步读取已加载的配置（未加载时返回默认值）
  BackupSettings get current => _cache ?? BackupSettings.defaults();

  /// 从存储加载（带旧位置迁移）。应用启动 / 导入备份后调用。
  Future<BackupSettings> load() async {
    final db = DatabaseHelper.instance;
    final raw = await db.getSetting(storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _cache = BackupSettings.fromMap(map);
        return _cache!;
      } catch (e) {
        AppLogger.w('BACKUP', '备份设置损坏，回退默认值: $e');
      }
    }

    // ---- 旧位置迁移：app_settings 文档的 backup 子文档 ----
    try {
      final appRaw = await db.getAppSettingsRaw();
      if (appRaw != null && appRaw.isNotEmpty) {
        final appMap = jsonDecode(appRaw) as Map<String, dynamic>;
        final legacy = appMap[legacyField];
        if (legacy is Map) {
          _cache = BackupSettings.fromMap(legacy.cast<String, dynamic>());
          AppLogger.i('BACKUP', '已从 app_settings.backup 迁移备份设置');
          await save(_cache!);
          return _cache!;
        }
      }
    } catch (e) {
      AppLogger.w('BACKUP', '迁移旧备份设置失败（忽略）: $e');
    }

    _cache = BackupSettings.defaults();
    return _cache!;
  }

  /// 写入存储（同时更新内存缓存）
  Future<void> save(BackupSettings value) async {
    _cache = value;
    await DatabaseHelper.instance.setSetting(
      storageKey,
      jsonEncode(value.toMap()),
    );
  }

  /// 局部更新
  Future<BackupSettings> update(BackupSettings Function(BackupSettings) f) async {
    final next = f(current);
    await save(next);
    return next;
  }

  /// 清空缓存（测试用）
  void resetCache() => _cache = null;
}
