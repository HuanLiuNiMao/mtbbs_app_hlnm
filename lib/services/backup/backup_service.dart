import 'dart:convert';

import 'package:mtbbs/config/build_config.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/models/backup/backup_item.dart';
import 'package:mtbbs/models/backup/backup_log_entry.dart';
import 'package:mtbbs/services/backup/backup_log_store.dart';
import 'package:mtbbs/services/backup/backup_pack.dart';
import 'package:mtbbs/services/backup/backup_registry.dart';

/// 导入失败时的处理策略
enum BackupImportStrategy {
  /// 逐项容错：某项失败只跳过该项，其余继续（默认，最不容易造成二次损失）
  perItem,

  /// 事务式：任何一项失败即把**本次涉及的模块**回滚到导入前的快照
  atomic,
}

/// 一次导出的结果
class BackupBuildResult {
  const BackupBuildResult({
    required this.pack,
    required this.json,
    required this.items,
    required this.durationMs,
    this.emptyKeys = const [],
  });

  final BackupPack pack;
  final String json;

  /// 逐项日志（含失败项）
  final List<BackupItemLog> items;

  final int durationMs;

  /// 勾选了但没有 handler 的项（不会写入包）
  final List<String> emptyKeys;

  bool get ok => items.every((e) => e.ok);

  int get totalCount => items.fold(0, (s, e) => s + e.count);

  Set<String> get keys => pack.modules.keys.toSet();
}

/// 一次导入的结果
class BackupApplySummary {
  const BackupApplySummary({
    required this.results,
    required this.items,
    required this.durationMs,
    this.rolledBack = false,
    this.rollbackError,
  });

  final List<BackupApplyResult> results;

  final List<BackupItemLog> items;

  final int durationMs;

  /// 是否执行了回滚
  final bool rolledBack;

  /// 回滚失败原因（此时数据可能处于中间态，需提示用户）
  final String? rollbackError;

  bool get ok => results.every((r) => r.ok) && rollbackError == null;

  bool get needsReload => results.any((r) => r.needsReload);

  int get totalApplied => results.fold(0, (s, r) => s + r.applied);

  int get totalSkipped => results.fold(0, (s, r) => s + r.skipped);

  String get summaryText {
    final failed = results.where((r) => !r.ok).length;
    final head = ok ? '成功' : '${failed} 项失败';
    return '$head · 写入 $totalApplied 条 · 跳过 $totalSkipped 条'
        '${rolledBack ? ' · 已回滚' : ''}';
  }
}

/// 备份/恢复服务 —— 唯一对外入口。
///
/// 核心保证：
/// 1. **按选项裁剪**：导出只序列化勾选项；导入只写包内出现的模块，
///    未勾选项（不在包里）保持本机原数据不变。
/// 2. **逐项容错 + 可选事务回滚**：每项单独 try/catch 并记日志；
///    [BackupImportStrategy.atomic] 下失败会整体回滚。
/// 3. **向后兼容**：旧版 `mtbbs.settings` / `mtbbs.cookies` 由
///    [BackupCodec] 转成新模块后照常导入。
class BackupService {
  BackupService._();

  static final BackupService instance = BackupService._();

  BackupLogStore get _logs => BackupLogStore.instance;

  // ==================== 导出 ====================

  /// 按 [selection] 收集并生成备份包。
  ///
  /// [extraModules] 用于 Web 备份追加非用户可见模块（如 `logs`）。
  Future<BackupBuildResult> build(
    BackupSelection selection, {
    Map<String, dynamic>? extraModules,
  }) async {
    final startedAt = DateTime.now();
    final ctx = BackupContext.current();
    final modules = <String, dynamic>{};
    final items = <BackupItemLog>[];
    final emptyKeys = <String>[];

    for (final key in selection.toPayloadKeys()) {
      final handler = BackupRegistry.handlerFor(key);
      if (handler == null) {
        emptyKeys.add(key);
        AppLogger.w('BACKUP', '备份项 $key 无实现，跳过');
        items.add(
          BackupItemLog(
            key: key,
            action: 'collect',
            ok: false,
            error: '本版本未实现该项',
          ),
        );
        continue;
      }
      final t0 = DateTime.now();
      try {
        final payload = await handler.collect(ctx);
        modules[key] = payload;
        final count = _countOf(payload);
        items.add(
          BackupItemLog(
            key: key,
            action: 'collect',
            ok: true,
            count: count,
            durationMs: DateTime.now().difference(t0).inMilliseconds,
          ),
        );
        AppLogger.i('BACKUP', '收集 $key 完成：$count 条');
      } catch (e) {
        items.add(
          BackupItemLog(
            key: key,
            action: 'collect',
            ok: false,
            durationMs: DateTime.now().difference(t0).inMilliseconds,
            error: e.toString(),
          ),
        );
        AppLogger.e('BACKUP', '收集 $key 失败: $e');
      }
    }

    if (extraModules != null) {
      for (final e in extraModules.entries) {
        modules[e.key] = e.value;
      }
    }

    final pack = BackupPack(
      createdAt: startedAt,
      appVersion: BuildConfig.versionName,
      appBuild: BuildConfig.versionCode,
      buildHash: BuildConfig.commitHash,
      enabledItems: modules.keys.toSet(),
      modules: modules,
    );
    final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
    return BackupBuildResult(
      pack: pack,
      json: BackupCodec.encode(pack),
      items: items,
      durationMs: durationMs,
      emptyKeys: emptyKeys,
    );
  }

  /// 导出并把结果写进运行日志（[trigger]：manual / web / scheduled）
  Future<BackupBuildResult> exportToJson(
    BackupSelection selection, {
    String trigger = 'manual',
    bool includeLogs = false,
  }) async {
    final result = await build(
      selection,
      extraModules: includeLogs ? {'logs': await _logs.exportJson()} : null,
    );
    await _recordRun(
      phase: 'export',
      trigger: trigger,
      items: result.items,
      keys: result.keys,
      ok: result.ok,
      durationMs: result.durationMs,
      detail: result.emptyKeys.isEmpty
          ? ''
          : '未实现项：${result.emptyKeys.join(', ')}',
      keepDays: _keepDays,
    );
    return result;
  }

  // ==================== 导入 ====================

  /// 解析备份文本（不落库，用于导入前预览项清单）
  BackupPack parse(String text) => BackupCodec.decode(text);

  /// 导入备份文本。
  ///
  /// [onlyKeys] 非空时只导入这些模块（用户在导入确认框里二次勾选）；
  /// 空则按包内实际模块全导入。
  Future<BackupApplySummary> applyText(
    String text, {
    BackupApplyMode mode = BackupApplyMode.replace,
    BackupImportStrategy strategy = BackupImportStrategy.perItem,
    Set<String>? onlyKeys,
    String trigger = 'manual',
    int keepDays = 30,
  }) async {
    final pack = BackupCodec.decode(text);
    return applyPack(
      pack,
      mode: mode,
      strategy: strategy,
      onlyKeys: onlyKeys,
      trigger: trigger,
      keepDays: keepDays,
    );
  }

  Future<BackupApplySummary> applyPack(
    BackupPack pack, {
    BackupApplyMode mode = BackupApplyMode.replace,
    BackupImportStrategy strategy = BackupImportStrategy.perItem,
    Set<String>? onlyKeys,
    String trigger = 'manual',
    int keepDays = 30,
  }) async {
    final startedAt = DateTime.now();
    final ctx = BackupContext.current();
    final keys = BackupCatalog.sortKeys(
      pack.modules.keys.where(
        (k) =>
            // `logs` 等附加模块只用于导出/上传，不参与还原
            BackupCatalog.byKey(k) != null &&
            (onlyKeys == null || onlyKeys.contains(k)),
      ),
    );

    // 事务式导入：先拍快照（用同一套 collector），失败后按快照写回
    Map<String, dynamic>? before;
    if (strategy == BackupImportStrategy.atomic && keys.isNotEmpty) {
      before = await _snapshot(ctx, keys);
      AppLogger.i('BACKUP', '事务式导入：已保存 ${before.length} 个模块的前置快照');
    }

    final results = <BackupApplyResult>[];
    final items = <BackupItemLog>[];
    for (final key in keys) {
      final handler = BackupRegistry.handlerFor(key);
      final t0 = DateTime.now();
      if (handler == null) {
        results.add(BackupApplyResult(key: key, skipped: 1, error: '本版本未实现该项'));
        items.add(
          BackupItemLog(
            key: key,
            action: 'apply',
            ok: false,
            error: '本版本未实现该项',
            durationMs: DateTime.now().difference(t0).inMilliseconds,
          ),
        );
        continue;
      }
      try {
        final result = await handler.apply(ctx, pack.modules[key], mode);
        results.add(result);
        items.add(
          BackupItemLog(
            key: key,
            action: 'apply',
            ok: result.ok,
            count: result.applied,
            durationMs: DateTime.now().difference(t0).inMilliseconds,
            error: result.error,
          ),
        );
        AppLogger.i(
          'BACKUP',
          '还原 $key：写入 ${result.applied} 条，跳过 ${result.skipped} 条'
              '，耗时 ${DateTime.now().difference(t0).inMilliseconds}ms',
        );
      } catch (e, st) {
        results.add(BackupApplyResult(key: key, error: e.toString()));
        items.add(
          BackupItemLog(
            key: key,
            action: 'apply',
            ok: false,
            error: e.toString(),
            durationMs: DateTime.now().difference(t0).inMilliseconds,
          ),
        );
        AppLogger.e('BACKUP', '还原 $key 失败: $e\n$st');
      }
    }

    var rolledBack = false;
    String? rollbackError;
    final failed = results.where((r) => !r.ok).toList();
    if (strategy == BackupImportStrategy.atomic &&
        failed.isNotEmpty &&
        before != null) {
      rolledBack = true;
      try {
        await _restoreSnapshot(ctx, before);
        AppLogger.w(
          'BACKUP',
          '事务式导入失败（${failed.map((e) => e.key).join(', ')}），已回滚',
        );
      } catch (e) {
        rollbackError = e.toString();
        AppLogger.e('BACKUP', '回滚失败，数据可能处于中间态: $e');
      }
    }

    final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
    await _recordRun(
      phase: 'import',
      trigger: trigger,
      items: items,
      keys: keys.toSet(),
      ok: failed.isEmpty && rollbackError == null,
      durationMs: durationMs,
      detail: [
        if (pack.packVersion < BackupPack.version) '旧格式 v${pack.packVersion}',
        if (failed.isNotEmpty) '失败：${failed.map((e) => e.key).join(', ')}',
        if (rolledBack) '已回滚',
        if (rollbackError != null) '回滚失败',
      ].join('；'),
      keepDays: keepDays,
    );

    return BackupApplySummary(
      results: results,
      items: items,
      durationMs: durationMs,
      rolledBack: rolledBack,
      rollbackError: rollbackError,
    );
  }

  /// 读取备份包里可导入的模块清单（导入确认框用）
  static List<String> describableKeys(BackupPack pack) =>
      BackupCatalog.sortKeys(pack.modules.keys);

  /// 模块键 → 显示名（未知键原样返回）
  static String labelOfKey(String key) =>
      BackupCatalog.byKey(key)?.title ?? key;

  // ==================== 内部 ====================

  /// 当前日志保留天数（由调用方传入；服务层不直接读 SettingsProvider，
  /// 避免 provider → service 的循环依赖）
  int _keepDays = 30;

  /// 由 `SettingsProvider` 在启动/改设置时注入日志保留天数
  set keepDays(int value) => _keepDays = value;

  int get logKeepDays => _keepDays;

  Future<Map<String, dynamic>> _snapshot(
    BackupContext ctx,
    List<String> keys,
  ) async {
    final out = <String, dynamic>{};
    for (final key in keys) {
      final handler = BackupRegistry.handlerFor(key);
      if (handler == null) continue;
      try {
        out[key] = await handler.collect(ctx);
      } catch (e) {
        AppLogger.w('BACKUP', '快照 $key 失败（该模块不可回滚）: $e');
      }
    }
    return out;
  }

  Future<void> _restoreSnapshot(
    BackupContext ctx,
    Map<String, dynamic> snapshot,
  ) async {
    for (final key in BackupCatalog.sortKeys(snapshot.keys)) {
      final handler = BackupRegistry.handlerFor(key);
      if (handler == null) continue;
      // 回滚一律用 replace：快照即「导入前完整状态」
      await handler.apply(ctx, snapshot[key], BackupApplyMode.replace);
    }
  }

  /// 统计 payload 的「条目数」用于日志（不同模块结构不同，这里取通用近似）
  int _countOf(Map<String, dynamic> payload) {
    int fromList(Object? v) => v is List ? v.length : 0;
    // 单值模块（app_settings / editor_settings）按 1 计
    if (payload.containsKey('hosts')) {
      final hosts = payload['hosts'];
      if (hosts is Map) {
        // 站点设置：host → 对象；快捷方式：host → 列表
        var total = 0;
        for (final v in hosts.values) {
          if (v is List) {
            total += v.length;
          } else {
            total += 1;
          }
        }
        return total;
      }
    }
    for (final key in ['items', 'records', 'snapshots']) {
      if (payload.containsKey(key)) return fromList(payload[key]);
    }
    if (payload.containsKey('values')) {
      final v = payload['values'];
      return v is Map ? v.length : 0;
    }
    if (payload.containsKey('sites')) return fromList(payload['sites']);
    return 1;
  }

  Future<void> _recordRun({
    required String phase,
    required String trigger,
    required List<BackupItemLog> items,
    required Set<String> keys,
    required bool ok,
    required int durationMs,
    required String detail,
    required int keepDays,
  }) async {
    final now = DateTime.now();
    final entry = BackupRunLogEntry(
      id: 'b${now.millisecondsSinceEpoch.toRadixString(36)}',
      at: now,
      phase: phase,
      trigger: trigger,
      ok: ok,
      keys: keys,
      items: items,
      durationMs: durationMs,
      detail: detail,
    );
    await _logs.add(entry, keepDays: keepDays);
  }

  /// 生成 JSON 字符串（Web 备份直接上传用）
  static String encode(BackupPack pack) => BackupCodec.encode(pack);

  /// 便于测试：把 payload 转成稳定字符串（避免 Map 顺序影响断言）
  static String canonicalJson(Object? value) => jsonEncode(value);
}
