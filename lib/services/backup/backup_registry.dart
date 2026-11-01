import 'package:mtbbs/core/app/site_store.dart';
import 'package:mtbbs/core/settings/settings_repository.dart';
import 'package:mtbbs/core/utils/database_helper.dart';
import 'package:mtbbs/models/backup/backup_item.dart';
import 'package:mtbbs/services/backup/backup_collectors.dart';

/// 导入策略
enum BackupApplyMode {
  /// 覆盖：先用备份包内容替换本机对应数据
  replace,

  /// 合并：保留本机数据，按业务主键去重合并（后导入优先）
  merge,
}

/// 单项还原结果
class BackupApplyResult {
  const BackupApplyResult({
    required this.key,
    this.applied = 0,
    this.skipped = 0,
    this.error,
    this.needsReload = false,
  });

  /// 备份包键名
  final String key;

  /// 实际写入条目数
  final int applied;

  /// 因数据非法 / 类型不符被跳过的条目数
  final int skipped;

  /// 失败原因（null = 成功）
  final String? error;

  /// 是否要求调用方 `settings.load()` / 重载会话（编辑器设置、Cookie 等）
  final bool needsReload;

  bool get ok => error == null;
}

/// 收集 / 还原时可用的上下文（一次运行内固定，避免各处重复查站点列表）
class BackupContext {
  BackupContext({required this.db, required this.repo, required this.hosts});

  final DatabaseHelper db;
  final SettingsRepository repo;

  /// 本机站点 host 列表
  final List<String> hosts;

  factory BackupContext.current() {
    final sites = SiteStore.instance.sites;
    return BackupContext(
      db: DatabaseHelper.instance,
      repo: SettingsRepository.instance,
      hosts: [for (final s in sites) s.host],
    );
  }
}

typedef BackupCollector =
    Future<Map<String, dynamic>> Function(BackupContext ctx);

typedef BackupApplier =
    Future<BackupApplyResult> Function(
      BackupContext ctx,
      Map<String, dynamic> payload,
      BackupApplyMode mode,
    );

/// 一个备份项的读写实现
class BackupItemHandler {
  const BackupItemHandler({
    required this.key,
    required this.collect,
    required this.apply,
  });

  final String key;
  final BackupCollector collect;
  final BackupApplier apply;
}

/// 备份项注册表 —— 与 `BackupCatalog` 的 payloadKey 一一对应。
///
/// 新增备份项时两处都要加：Catalog 里加声明，这里加 collect/apply。
/// 缺少 handler 的项会在运行日志里记为「未实现」，不会静默丢数据。
abstract final class BackupRegistry {
  static final Map<String, BackupItemHandler> _handlers = {
    for (final h in backupCollectors) h.key: h,
  };

  static BackupItemHandler? handlerFor(String key) => _handlers[key];

  static Set<String> get keys => _handlers.keys.toSet();

  /// Catalog 声明了但没有实现的项（单测断言它为空）
  static Set<String> get missing => {
    for (final e in BackupCatalog.leaves)
      if (!_handlers.containsKey(e.payloadKey)) e.payloadKey!,
  };
}
