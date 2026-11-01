import 'dart:convert';

import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/models/backup/backup_item.dart';

/// 备份包解码失败（文件不是备份、版本过新、JSON 损坏）
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 备份包（自定义备份项的可裁剪容器）。
///
/// `modules` 只含用户勾选的项；未勾选项**不写入**，导入时也**不动**本机
/// 对应数据（这是「按选项裁剪」的核心保证）。
class BackupPack {
  static const String format = 'mtbbs.backup';

  /// 当前格式版本。字段只增不删；新增模块用新键，不改旧键语义。
  static const int version = 2;

  final int packVersion;
  final DateTime createdAt;

  /// 生成备份的应用版本（便于排障与「版本差异」提示）
  final String appVersion;
  final int appBuild;
  final String buildHash;

  /// 包内实际包含的模块键（= modules.keys，显式写出便于人眼查看）
  final Set<String> enabledItems;

  /// 模块键 → payload
  final Map<String, dynamic> modules;

  const BackupPack({
    this.packVersion = version,
    required this.createdAt,
    this.appVersion = '',
    this.appBuild = 0,
    this.buildHash = '',
    required this.enabledItems,
    required this.modules,
  });

  bool contains(String key) => modules.containsKey(key);

  Map<String, dynamic> toMap() => {
    'format': format,
    'version': packVersion,
    'createdAt': createdAt.toIso8601String(),
    'app': {'version': appVersion, 'build': appBuild, 'hash': buildHash},
    'enabledItems': enabledItems.toList()..sort(),
    'modules': modules,
  };
}

/// 备份包编解码 + 向后兼容。
///
/// 兼容矩阵（见 docs/04-状态管理.md）：
/// - `mtbbs.backup` v2 → 全量读
/// - `mtbbs.settings` v1（旧「导出设置」）→ 拆成 app_settings + site_settings
/// - `mtbbs.cookies`  v1（旧「导出 Cookie」）→ 转成 account_cookies
/// - `version > 2` → 拒绝（提示升级 App）
/// - 未知模块键 → 静默跳过并记日志（新版本写的项，旧版本不认）
/// - 缺 `enabledItems` → 按 modules 实际键推断
abstract final class BackupCodec {
  static const String legacySettingsFormat = 'mtbbs.settings';
  static const String legacyCookiesFormat = 'mtbbs.cookies';

  static const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

  static String encode(BackupPack pack) => _pretty.convert(pack.toMap());

  static BackupPack decode(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      throw BackupFormatException('JSON 解析失败：$e');
    }
    if (decoded is! Map) throw const BackupFormatException('不是有效的备份文件');
    final doc = decoded.cast<String, dynamic>();
    final format = doc['format']?.toString();
    if (format == BackupPack.format) return _decodeV2(doc);
    if (format == legacySettingsFormat) return _fromLegacySettings(doc);
    if (format == legacyCookiesFormat) return _fromLegacyCookies(doc);
    throw BackupFormatException('不认识的文件类型：${format ?? '（缺 format 字段）'}');
  }

  /// 探测是否为备份文件（用于导入前的类型提示，不抛异常）
  static String? detectKind(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final format = decoded['format']?.toString();
      return switch (format) {
        BackupPack.format => '备份包 v${decoded['version'] ?? '?'}',
        legacySettingsFormat => '旧版设置（v1）',
        legacyCookiesFormat => '旧版账号 Cookie（v1）',
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  static BackupPack _decodeV2(Map<String, dynamic> doc) {
    final v = (doc['version'] as num?)?.toInt() ?? 0;
    if (v <= 0) throw const BackupFormatException('备份包缺少有效 version');
    if (v > BackupPack.version) {
      throw BackupFormatException(
        '备份包版本 $v 高于本机支持的 ${BackupPack.version}，请先升级应用',
      );
    }

    final modules = <String, dynamic>{};
    final rawModules = doc['modules'];
    if (rawModules is Map) {
      for (final e in rawModules.entries) {
        final key = e.key.toString();
        if (BackupCatalog.byKey(key) == null) {
          AppLogger.w('BACKUP', '忽略未知模块 $key（本版本不支持）');
          continue;
        }
        modules[key] = e.value;
      }
    }

    final rawEnabled = doc['enabledItems'];
    final enabled = rawEnabled is List
        ? rawEnabled.map((e) => e.toString()).where(modules.containsKey).toSet()
        : modules.keys.toSet();

    final app = (doc['app'] as Map?)?.cast<String, dynamic>();
    return BackupPack(
      packVersion: v,
      createdAt:
          DateTime.tryParse(doc['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      appVersion: app?['version']?.toString() ?? '',
      appBuild: (app?['build'] as num?)?.toInt() ?? 0,
      buildHash: app?['hash']?.toString() ?? '',
      enabledItems: enabled,
      modules: modules,
    );
  }

  /// 旧版「导出设置」→ app_settings + site_settings
  static BackupPack _fromLegacySettings(Map<String, dynamic> doc) {
    final app = doc['app'];
    final sites = doc['sites'];
    final modules = <String, dynamic>{};
    if (app is Map) modules['app_settings'] = app.cast<String, dynamic>();
    if (sites is Map) {
      modules['site_settings'] = {
        for (final e in sites.entries) e.key.toString(): e.value,
      };
    }
    AppLogger.i('BACKUP', '识别为旧版设置文件（v1），按 2 个模块导入');
    return BackupPack(
      packVersion: 1,
      createdAt:
          DateTime.tryParse(doc['exportedAt']?.toString() ?? '') ??
          DateTime.now(),
      enabledItems: modules.keys.toSet(),
      modules: modules,
    );
  }

  /// 旧版「导出 Cookie」→ account_cookies
  static BackupPack _fromLegacyCookies(Map<String, dynamic> doc) {
    AppLogger.i('BACKUP', '识别为旧版 Cookie 文件（v1），按 account_cookies 导入');
    return BackupPack(
      packVersion: 1,
      createdAt:
          DateTime.tryParse(doc['exportedAt']?.toString() ?? '') ??
          DateTime.now(),
      enabledItems: const {'account_cookies'},
      modules: {'account_cookies': doc},
    );
  }
}
