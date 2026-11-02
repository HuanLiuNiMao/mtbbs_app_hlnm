import 'dart:convert';

import 'package:mtbbs/core/utils/database_helper.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/mcp/mcp_server_controller.dart';
import 'package:mtbbs/models/browse_record.dart';
import 'package:mtbbs/models/editor_snapshot.dart';
import 'package:mtbbs/models/managed_item.dart';
import 'package:mtbbs/models/settings/app_settings.dart';
import 'package:mtbbs/services/backup/backup_registry.dart';
import 'package:mtbbs/services/data_portability.dart';

/// 各备份项的 collect / apply 实现。
///
/// 约定：
/// - `collect` 返回可 JSON 序列化的 Map（备份包里的 payload）；
/// - `apply` 只动**本模块**的数据，不碰其它模块（未勾选项保持原样）；
/// - 失败抛异常由上层捕获记日志，单项失败不影响其它项。

// ==================== 常量 ====================

/// 浏览记录「用户」维度
const Set<String> kBrowseUserTypes = {'user'};

/// 浏览记录「帖子」维度（含我的帖子 / 回复）
const Set<String> kBrowsePostTypes = {'thread', 'mythread', 'reply'};

/// 图床历史上限（与 `MtImageHosting` 写入逻辑一致）
const int _kMtHistoryLimit = 200;

/// 内容过滤的扁平 KV 键（见 `SettingsProvider`）
const List<String> _kContentFilterKeys = [
  'threadFilterModeBlock',
  'threadFilterBoards',
  'threadFilterKeywords',
  // 评论屏蔽：开关 + 两种触发方式 + 屏蔽词，整份 JSON（旧键
  // commentFilterKeywords / commentBlockEnabled / commentBlockWordsVersion
  // 已在升级时迁移并删除，不再列出——否则恢复旧备份会把废弃键写回来）
  'commentFilter',
];

/// 内容过滤按列表点配置的键前缀
const String _kScopeFilterPrefix = 'threadScopeFilter_';

/// 内容过滤按列表点的四个 scope（与 `SettingsProvider._kThreadScopes` 一致）
const List<String> _kThreadScopes = ['community', 'guide', 'search', 'user'];

/// MCP 配置键（见 `McpServerController`）
const List<String> _kMcpKeys = [
  'mcpEnabled',
  'mcpPort',
  'mcpAllowRemote',
  'mcpTokens',
  'mcpDisabledGroups',
];

/// 注册表内容（顺序不重要，导入顺序由 `BackupCatalog.applyOrder` 决定）
const List<BackupItemHandler> backupCollectors = [
  BackupItemHandler(
    key: 'app_settings',
    collect: _collectAppSettings,
    apply: _applyAppSettings,
  ),
  BackupItemHandler(
    key: 'site_settings',
    collect: _collectSiteSettings,
    apply: _applySiteSettings,
  ),
  BackupItemHandler(
    key: 'shortcuts',
    collect: _collectShortcuts,
    apply: _applyShortcuts,
  ),
  BackupItemHandler(
    key: 'mt_image_history',
    collect: _collectMtImageHistory,
    apply: _applyMtImageHistory,
  ),
  BackupItemHandler(
    key: 'browse_history_user',
    collect: _collectBrowseUser,
    apply: _applyBrowseUser,
  ),
  BackupItemHandler(
    key: 'browse_history_post',
    collect: _collectBrowsePost,
    apply: _applyBrowsePost,
  ),
  BackupItemHandler(
    key: 'editor_settings',
    collect: _collectEditorSettings,
    apply: _applyEditorSettings,
  ),
  BackupItemHandler(
    key: 'editor_snapshots',
    collect: _collectEditorSnapshots,
    apply: _applyEditorSnapshots,
  ),
  BackupItemHandler(
    key: 'content_filter',
    collect: _collectContentFilter,
    apply: _applyContentFilter,
  ),
  BackupItemHandler(
    key: 'mcp_config',
    collect: _collectMcpConfig,
    apply: _applyMcpConfig,
  ),
  BackupItemHandler(
    key: 'account_cookies',
    collect: _collectAccountCookies,
    apply: _applyAccountCookies,
  ),
];

// ==================== 应用设置 ====================

Future<Map<String, dynamic>> _collectAppSettings(BackupContext ctx) async =>
    ctx.repo.app.toMap();

Future<BackupApplyResult> _applyAppSettings(
  BackupContext ctx,
  Map<String, dynamic> payload,
  BackupApplyMode mode,
) async {
  if (payload.isEmpty) {
    return const BackupApplyResult(key: 'app_settings', skipped: 1);
  }
  final current = ctx.repo.app;
  final incoming = AppSettings.fromMap(payload);
  // 两份「本机专属」数据不能被备份包覆盖：
  // - currentSiteHost：备份包里的站点在本机可能不存在，导入后会导致启动落在空站点
  // - backup：就是备份项勾选状态本身，覆盖会让用户下一次备份的选项莫名变化
  final next = mode == BackupApplyMode.replace
      ? incoming.copyWith(
          currentSiteHost: current.currentSiteHost,
          backup: current.backup,
        )
      : _mergeAppSettings(current, incoming);
  await ctx.repo.setApp(next);
  return const BackupApplyResult(
    key: 'app_settings',
    applied: 1,
    needsReload: true,
  );
}

/// 合并：以本机为基底，只覆盖备份包里**确实存在**的字段
AppSettings _mergeAppSettings(AppSettings cur, AppSettings incoming) {
  final map = <String, dynamic>{...cur.toMap(), ...incoming.toMap()};
  map['currentSiteHost'] = cur.currentSiteHost;
  map['backup'] = cur.backup.toMap();
  return AppSettings.fromMap(map);
}

// ==================== 站点设置 ====================

Future<Map<String, dynamic>> _collectSiteSettings(BackupContext ctx) async {
  final out = <String, dynamic>{};
  for (final host in ctx.hosts) {
    final raw = await ctx.db.getSiteSettingsRaw(host);
    if (raw != null && raw.isNotEmpty) {
      try {
        out[host] = jsonDecode(raw);
        continue;
      } catch (e) {
        AppLogger.w('BACKUP', '站点 $host 设置解析失败，回退内存值: $e');
      }
    }
    out[host] = ctx.repo.site(host).toMap();
  }
  return {'hosts': out};
}

Future<BackupApplyResult> _applySiteSettings(
  BackupContext ctx,
  Map<String, dynamic> payload,
  BackupApplyMode mode,
) async {
  final hosts = (payload['hosts'] as Map?)?.cast<String, dynamic>() ?? const {};
  var applied = 0;
  var skipped = 0;
  for (final e in hosts.entries) {
    final host = e.key.trim();
    final value = e.value;
    if (host.isEmpty || value is! Map) {
      skipped++;
      continue;
    }
    final incoming = value.cast<String, dynamic>();
    final toWrite = mode == BackupApplyMode.replace
        ? incoming
        : _mergeSiteSettings(await _currentSiteMap(ctx, host), incoming);
    await ctx.db.setSiteSettingsRaw(host, jsonEncode(toWrite));
    // 内存里已有该 host 时同步刷新，避免 UI 读到旧值
    if (ctx.hosts.contains(host)) {
      await ctx.repo.loadSite(host);
    }
    applied++;
  }
  return BackupApplyResult(
    key: 'site_settings',
    applied: applied,
    skipped: skipped,
    needsReload: applied > 0,
  );
}

Future<Map<String, dynamic>> _currentSiteMap(
  BackupContext ctx,
  String host,
) async {
  final raw = await ctx.db.getSiteSettingsRaw(host);
  if (raw != null && raw.isNotEmpty) {
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {}
  }
  return ctx.repo.site(host).toMap();
}

Map<String, dynamic> _mergeSiteSettings(
  Map<String, dynamic> cur,
  Map<String, dynamic> incoming,
) {
  Map<String, dynamic> deep(Map<String, dynamic> a, Map<String, dynamic> b) {
    final out = <String, dynamic>{...a};
    for (final e in b.entries) {
      final old = out[e.key];
      final nw = e.value;
      out[e.key] = (old is Map && nw is Map)
          ? deep(old.cast<String, dynamic>(), nw.cast<String, dynamic>())
          : nw;
    }
    return out;
  }

  // host 恒为当前 host（备份包里可能为空）
  return {...deep(cur, incoming), 'host': cur['host'] ?? incoming['host']};
}

// ==================== 快捷方式 ====================

Future<Map<String, dynamic>> _collectShortcuts(BackupContext ctx) async => {
  'hosts': {
    for (final host in ctx.hosts)
      host: ctx.repo.site(host).shortcutLinks.map((e) => e.toJson()).toList(),
  },
};

Future<BackupApplyResult> _applyShortcuts(
  BackupContext ctx,
  Map<String, dynamic> payload,
  BackupApplyMode mode,
) async {
  final hosts = (payload['hosts'] as Map?)?.cast<String, dynamic>() ?? const {};
  var applied = 0;
  var skipped = 0;
  for (final e in hosts.entries) {
    final host = e.key.trim();
    final raw = e.value;
    if (host.isEmpty || raw is! List) {
      skipped++;
      continue;
    }
    final incoming = <ManagedItem>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final parsed = ManagedItem.fromJson(item.cast<String, dynamic>());
      if (parsed.id.isEmpty) continue;
      incoming.add(parsed);
    }
    if (incoming.isEmpty) {
      skipped++;
      continue;
    }
    final current = ctx.repo.site(host).shortcutLinks;
    final next = mode == BackupApplyMode.replace
        ? incoming
        : _mergeManagedItems(current, incoming);
    await ctx.repo.updateSite(host, (s) => s.copyWith(shortcutLinks: next));
    applied++;
  }
  return BackupApplyResult(
    key: 'shortcuts',
    applied: applied,
    skipped: skipped,
  );
}

/// 按 id 合并可管理条目（保留本机顺序，新条目追加到末尾）
List<ManagedItem> _mergeManagedItems(
  List<ManagedItem> cur,
  List<ManagedItem> incoming,
) {
  final out = List<ManagedItem>.from(cur);
  for (final item in incoming) {
    final i = out.indexWhere((e) => e.id == item.id);
    if (i >= 0) {
      out[i] = item;
    } else {
      out.add(item);
    }
  }
  return out;
}

// ==================== MT 图床历史 ====================

Future<Map<String, dynamic>> _collectMtImageHistory(BackupContext ctx) async {
  final raw = await ctx.db.getImageHistoryRaw();
  if (raw == null || raw.isEmpty) return {'items': const <dynamic>[]};
  try {
    final list = jsonDecode(raw);
    return {'items': list is List ? list : const <dynamic>[]};
  } catch (e) {
    AppLogger.w('BACKUP', '图床历史解析失败，按空导出: $e');
    return {'items': const <dynamic>[]};
  }
}

Future<BackupApplyResult> _applyMtImageHistory(
  BackupContext ctx,
  Map<String, dynamic> payload,
  BackupApplyMode mode,
) async {
  final raw = (payload['items'] as List?) ?? const [];
  final incoming = <Map<String, dynamic>>[];
  var skipped = 0;
  for (final e in raw) {
    if (e is! Map) {
      skipped++;
      continue;
    }
    final item = e.cast<String, dynamic>();
    if ((item['url']?.toString() ?? '').isEmpty) {
      skipped++;
      continue;
    }
    incoming.add(item);
  }
  if (mode == BackupApplyMode.replace) {
    final capped = incoming.length > _kMtHistoryLimit
        ? incoming.sublist(0, _kMtHistoryLimit)
        : incoming;
    await ctx.db.setImageHistoryRaw(jsonEncode(capped));
    return BackupApplyResult(
      key: 'mt_image_history',
      applied: capped.length,
      skipped: skipped,
    );
  }

  // merge：按 url 去重，按上传时间倒序，保留上限
  final current = await _collectMtImageHistory(ctx);
  final byUrl = <String, Map<String, dynamic>>{};
  for (final e in (current['items'] as List).whereType<Map>()) {
    final item = e.cast<String, dynamic>();
    final url = item['url']?.toString() ?? '';
    if (url.isNotEmpty) byUrl[url] = item;
  }
  for (final item in incoming) {
    byUrl[item['url'].toString()] = item; // 后导入优先
  }
  final merged = byUrl.values.toList()
    ..sort(
      (a, b) => (b['uploadedAt']?.toString() ?? '').compareTo(
        a['uploadedAt']?.toString() ?? '',
      ),
    );
  final capped = merged.length > _kMtHistoryLimit
      ? merged.sublist(0, _kMtHistoryLimit)
      : merged;
  await ctx.db.setImageHistoryRaw(jsonEncode(capped));
  return BackupApplyResult(
    key: 'mt_image_history',
    applied: capped.length,
    skipped: skipped,
  );
}

// ==================== 浏览记录（用户 / 帖子 分开） ====================

Future<Map<String, dynamic>> _collectBrowse(
  BackupContext ctx,
  Set<String> types,
) async {
  final all = await ctx.db.getAllBrowseRecords();
  final records = <Map<String, dynamic>>[];
  for (final r in all) {
    if (types.contains(r.type)) records.add(r.toJson());
  }
  return {'records': records};
}

Future<BackupApplyResult> _applyBrowse(
  BackupContext ctx,
  Map<String, dynamic> payload,
  BackupApplyMode mode,
  Set<String> types,
  String key,
) async {
  final raw = (payload['records'] as List?) ?? const [];
  final incoming = <BrowseRecord>[];
  var skipped = 0;
  for (final e in raw) {
    if (e is! Map) {
      skipped++;
      continue;
    }
    final record = BrowseRecord.fromJson(e.cast<String, dynamic>());
    // 外键约束：id 必须存在；类型必须属于本维度（防止有人把帖子记录塞进用户维度，
    // 导致删除时跨维度误删）；归属 host 为空时按当前站点补全，保证多站点隔离。
    if (record.id.isEmpty || !types.contains(record.type)) {
      skipped++;
      continue;
    }
    if (record.host.isEmpty && ctx.hosts.length == 1) {
      incoming.add(
        BrowseRecord(
          id: record.id,
          host: ctx.hosts.first,
          type: record.type,
          routePath: record.routePath,
          timestamp: record.timestamp,
          info: record.info,
        ),
      );
    } else {
      incoming.add(record);
    }
  }
  if (mode == BackupApplyMode.replace) {
    await ctx.db.deleteBrowseRecordsByTypes(types);
  }
  final applied = await ctx.db.upsertBrowseRecords(incoming);
  return BackupApplyResult(
    key: key,
    applied: applied,
    skipped: skipped,
    needsReload: applied > 0,
  );
}

Future<Map<String, dynamic>> _collectBrowseUser(BackupContext ctx) =>
    _collectBrowse(ctx, kBrowseUserTypes);

Future<BackupApplyResult> _applyBrowseUser(
  BackupContext ctx,
  Map<String, dynamic> payload,
  BackupApplyMode mode,
) => _applyBrowse(ctx, payload, mode, kBrowseUserTypes, 'browse_history_user');

Future<Map<String, dynamic>> _collectBrowsePost(BackupContext ctx) =>
    _collectBrowse(ctx, kBrowsePostTypes);

Future<BackupApplyResult> _applyBrowsePost(
  BackupContext ctx,
  Map<String, dynamic> payload,
  BackupApplyMode mode,
) => _applyBrowse(ctx, payload, mode, kBrowsePostTypes, 'browse_history_post');

// ==================== 编辑框设置 / 草稿 ====================

Future<Map<String, dynamic>> _collectEditorSettings(BackupContext ctx) async =>
    ctx.repo.app.editor.toMap();

Future<BackupApplyResult> _applyEditorSettings(
  BackupContext ctx,
  Map<String, dynamic> payload,
  BackupApplyMode mode,
) async {
  if (payload.isEmpty) {
    return const BackupApplyResult(key: 'editor_settings', skipped: 1);
  }
  final current = ctx.repo.app.editor;
  final incoming = EditorSettings.fromMap(payload);
  final next = mode == BackupApplyMode.replace
      ? incoming
      : EditorSettings.fromMap({...current.toMap(), ...incoming.toMap()});
  await ctx.repo.setApp(ctx.repo.app.copyWith(editor: next));
  return const BackupApplyResult(
    key: 'editor_settings',
    applied: 1,
    needsReload: true,
  );
}

Future<Map<String, dynamic>> _collectEditorSnapshots(BackupContext ctx) async {
  final snapshots = await ctx.db.getAllEditorSnapshots();
  return {'snapshots': snapshots.map((e) => e.toJson()).toList()};
}

Future<BackupApplyResult> _applyEditorSnapshots(
  BackupContext ctx,
  Map<String, dynamic> payload,
  BackupApplyMode mode,
) async {
  final raw = (payload['snapshots'] as List?) ?? const [];
  final incoming = <EditorSnapshot>[];
  var skipped = 0;
  for (final e in raw) {
    if (e is! Map) {
      skipped++;
      continue;
    }
    try {
      final snapshot = EditorSnapshot.fromJson(e.cast<String, dynamic>());
      if (snapshot.id.isEmpty) {
        skipped++;
        continue;
      }
      incoming.add(snapshot);
    } catch (_) {
      skipped++; // 单条损坏只跳过这一条，不影响其余草稿
    }
  }
  if (mode == BackupApplyMode.replace) {
    await ctx.db.clearAllEditorSnapshots();
  }
  var applied = 0;
  for (final s in incoming) {
    await ctx.db.insertEditorSnapshot(s);
    applied++;
  }
  return BackupApplyResult(
    key: 'editor_snapshots',
    applied: applied,
    skipped: skipped,
    needsReload: applied > 0,
  );
}

// ==================== 内容过滤 ====================

Future<Map<String, dynamic>> _collectContentFilter(BackupContext ctx) async {
  final values = <String, String?>{};
  for (final key in _kContentFilterKeys) {
    values[key] = await ctx.db.getSetting(key);
  }
  for (final scope in _kThreadScopes) {
    values['$_kScopeFilterPrefix$scope'] = await ctx.db.getSetting(
      '$_kScopeFilterPrefix$scope',
    );
  }
  return {
    'values': {
      for (final e in values.entries)
        if (e.value != null && e.value!.isNotEmpty) e.key: e.value,
    },
  };
}

Future<BackupApplyResult> _applyContentFilter(
  BackupContext ctx,
  Map<String, dynamic> payload,
  BackupApplyMode mode,
) async {
  final values =
      (payload['values'] as Map?)?.cast<String, dynamic>() ?? const {};
  final allowed = {
    ..._kContentFilterKeys,
    for (final scope in _kThreadScopes) '$_kScopeFilterPrefix$scope',
  };
  var applied = 0;
  var skipped = 0;
  for (final e in values.entries) {
    if (!allowed.contains(e.key)) {
      skipped++; // 未知键（更高版本新增）跳过，不污染本机 KV
      continue;
    }
    final value = e.value;
    if (value is bool) {
      await ctx.db.setSettingBool(e.key, value);
      applied++;
    } else if (value is String) {
      await ctx.db.setSetting(e.key, value);
      applied++;
    } else {
      skipped++;
    }
  }
  return BackupApplyResult(
    key: 'content_filter',
    applied: applied,
    skipped: skipped,
    needsReload: applied > 0,
  );
}

// ==================== MCP 配置 ====================

Future<Map<String, dynamic>> _collectMcpConfig(BackupContext ctx) async {
  final values = <String, dynamic>{};
  for (final key in _kMcpKeys) {
    values[key] = await ctx.db.getSetting(key);
  }
  return {
    'values': {
      for (final e in values.entries)
        if (e.value != null && e.value!.isNotEmpty) e.key: e.value,
    },
  };
}

Future<BackupApplyResult> _applyMcpConfig(
  BackupContext ctx,
  Map<String, dynamic> payload,
  BackupApplyMode mode,
) async {
  final values =
      (payload['values'] as Map?)?.cast<String, dynamic>() ?? const {};
  var applied = 0;
  var skipped = 0;
  for (final e in values.entries) {
    if (!_kMcpKeys.contains(e.key)) {
      skipped++;
      continue;
    }
    final value = e.value;
    if (value == null) {
      skipped++;
      continue;
    }
    if (value is bool) {
      await ctx.db.setSettingBool(e.key, value);
      applied++;
    } else if (value is int) {
      await ctx.db.setSettingInt(e.key, value);
      applied++;
    } else if (value is String) {
      await ctx.db.setSetting(e.key, value);
      applied++;
    } else {
      skipped++;
    }
  }
  // MCP 配置读进内存后带 `_loaded` 缓存：导入后必须重新装载，
  // 否则端口/令牌/开关要等下次冷启动才生效。
  await McpServerController.instance.reloadFromStorage();
  return BackupApplyResult(
    key: 'mcp_config',
    applied: applied,
    skipped: skipped,
    needsReload: applied > 0,
  );
}

// ==================== 账号与 Cookie ====================

Future<Map<String, dynamic>> _collectAccountCookies(BackupContext ctx) async {
  final text = await DataPortability.exportCookiesJson();
  return (jsonDecode(text) as Map).cast<String, dynamic>();
}

Future<BackupApplyResult> _applyAccountCookies(
  BackupContext ctx,
  Map<String, dynamic> payload,
  BackupApplyMode mode,
) async {
  // 复用既有导入实现（格式即 `mtbbs.cookies`，v1 老文件同样适用）。
  // 账号按 uid 去重合并；Cookie 按账号覆盖。
  final result = await DataPortability.importCookiesJson(jsonEncode(payload));
  return BackupApplyResult(
    key: 'account_cookies',
    applied: result.jars,
    skipped: 0,
    needsReload: result.hosts.isNotEmpty,
  );
}
