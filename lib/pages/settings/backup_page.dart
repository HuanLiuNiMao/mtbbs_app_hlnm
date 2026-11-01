import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:mtbbs/core/app/app_paths.dart';
import 'package:mtbbs/core/utils/clipboard_helper.dart';
import 'package:mtbbs/models/backup/backup_item.dart';
import 'package:mtbbs/models/settings/backup_settings.dart';
import 'package:mtbbs/pages/settings/widgets/dialogs.dart';
import 'package:mtbbs/platform/optional/file_pick.dart';
import 'package:mtbbs/platform/optional/file_save.dart';
import 'package:mtbbs/platform/optional/secure_store.dart';
import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/services/backup/backup_log_store.dart';
import 'package:mtbbs/services/backup/backup_pack.dart';
import 'package:mtbbs/services/backup/backup_registry.dart';
import 'package:mtbbs/services/backup/backup_service.dart';
import 'package:mtbbs/services/backup/backup_web_client.dart';
import 'package:mtbbs/widgets/common/toast_utils.dart';
import 'package:mtbbs/widgets/dialog/confirm_dialog.dart';

/// 备份与恢复页 —— 自定义备份项的唯一 UI 入口。
///
/// 三块内容：
/// 1. **备份内容**：`BackupCatalog` 声明的复选框树（分组 / 半选 / 依赖级联）；
/// 2. **备份 / 恢复**：立即导出（剪切板或文件）、从剪切板 / 文件导入，
///    导入前预览模块清单并二次确认敏感项；
/// 3. **Web 备份**：用户自备服务器的地址 / 鉴权 / 间隔 / 仅 Wi-Fi / 附带日志。
///
/// 设计约束（见 docs/28）：
/// - 勾选状态只落 `AppSettings.backup`，不新增 SharedPreferences；
/// - 服务层不读 provider（`BackupService.keepDays` 由 provider 注入）；
/// - 所有按钮都 await 服务层并回写「上次备份时间 / 上次上传结果」，
///   保证页面刷新后用户能看到上次结果，而不是只有一次性的 toast。
class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final backup = settings.backupSettings;
    final selection = settings.backupSelection;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复'), centerTitle: true),
      body: ListView(
        children: [
          _sectionHeader('备份内容', '只勾选需要的项；未勾选的项不进备份包，导入时也不动本机数据'),
          _buildSelectionCard(settings, selection),
          _sectionHeader('备份', '导出的 JSON 可直接上传到自建服务器'),
          _buildExportCard(settings, selection),
          _sectionHeader('恢复', '导入前会列出包内模块，可再次挑选要恢复的项'),
          _buildImportCard(settings),
          _sectionHeader('Web 备份', '服务器由你自备，本应用不提供托管空间'),
          _buildWebCard(settings, backup),
          _sectionHeader('运行日志', '每次备份 / 恢复都会留一条记录，环形保留'),
          _buildLogCard(settings, backup),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '提示：MCP 配置、账号与 Cookie 属敏感数据，备份包请勿外传。',
              style: TextStyle(fontSize: 12, color: cs.outline),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 备份内容 ====================

  Widget _buildSelectionCard(
    SettingsProvider settings,
    BackupSelection selection,
  ) {
    final rows = <Widget>[];
    for (final spec in BackupCatalog.roots) {
      rows.add(_buildItemTile(settings, selection, spec));
      if (spec.isGroup) {
        for (final kid in BackupCatalog.childrenOf(spec.id)) {
          rows.add(
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: _buildItemTile(settings, selection, kid),
            ),
          );
        }
      }
    }
    rows.add(const Divider(height: 1));
    rows.add(
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            Text(
              '已选 ${selection.count} / ${selection.total} 项',
              style: const TextStyle(fontSize: 12),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => settings.setBackupSelection(selection.all.ids),
              child: const Text('全选'),
            ),
            TextButton(
              onPressed: () =>
                  settings.setBackupSelection(selection.inverted.ids),
              child: const Text('反选'),
            ),
            TextButton(
              onPressed: () =>
                  settings.setBackupSelection(BackupCatalog.defaults),
              child: const Text('重置'),
            ),
          ],
        ),
      ),
    );
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(children: rows),
    );
  }

  Widget _buildItemTile(
    SettingsProvider settings,
    BackupSelection selection,
    BackupItemSpec spec,
  ) {
    final isGroup = spec.isGroup;
    // 分组父用三态：全选 / 半选（null） / 未选
    final bool? value = isGroup
        ? (selection.groupFully(spec.id)
              ? true
              : (selection.groupPartial(spec.id) ? null : false))
        : selection.contains(spec.id);
    return CheckboxListTile(
      value: value,
      tristate: isGroup,
      secondary: Icon(spec.icon),
      title: Text(spec.title),
      subtitle: Text(
        spec.sensitive ? '${spec.subtitle}（敏感，导入需确认）' : spec.subtitle,
      ),
      onChanged: (_) => settings.setBackupSelection(
        isGroup
            ? selection.setGroup(spec.id, !selection.groupFully(spec.id)).ids
            : selection.toggled(spec.id).ids,
      ),
    );
  }

  // ==================== 导出 ====================

  Widget _buildExportCard(
    SettingsProvider settings,
    BackupSelection selection,
  ) {
    final lastAt = settings.backupSettings.lastBackupAt;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: const Text('立即备份'),
            subtitle: Text(
              lastAt.isEmpty
                  ? '尚未备份过'
                  : '上次备份：${_fmtTime(DateTime.tryParse(lastAt))}',
            ),
            trailing: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _busy ? null : () => _runExport(settings, selection),
          ),
          if (BackupRegistry.missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '以下项本版本无实现（不会写入包）：'
                  '${BackupRegistry.missing.join(', ')}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _runExport(
    SettingsProvider settings,
    BackupSelection selection,
  ) async {
    if (selection.count == 0) {
      showToast('请先勾选至少一个备份项');
      return;
    }
    final withLogs = await showConfirmDialog(
      context,
      title: '附带运行日志？',
      message: '把最近 50 条备份日志一并写进备份包（会略增大文件）。',
      confirmText: '带上',
      cancelText: '不带',
    );
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final result = await BackupService.instance.exportToJson(
        selection,
        trigger: 'manual',
        includeLogs: withLogs == true,
      );
      if (!mounted) return;
      await settings.markBackupDone(DateTime.now());
      if (!mounted) return;
      await _deliverJson(result.json, 'mtbbs_backup');
      if (!mounted) return;
      final failed = result.items.where((e) => !e.ok).toList();
      showToast(
        failed.isEmpty
            ? '已生成备份：${result.keys.length} 项 / ${result.totalCount} 条'
            : '备份完成但有 ${failed.length} 项失败：'
                  '${failed.map((e) => e.key).join(', ')}',
      );
    } catch (e) {
      if (mounted) showToast('备份失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ==================== 导入 ====================

  Widget _buildImportCard(SettingsProvider settings) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.settings_backup_restore_outlined),
            title: const Text('从文件恢复'),
            subtitle: const Text('支持新备份包与旧版「设置 / 账号 Cookie」文件'),
            onTap: _busy ? null : () => _runImport(settings, fromFile: true),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.content_paste),
            title: const Text('从剪切板恢复'),
            subtitle: const Text('粘贴备份 JSON 文本'),
            onTap: _busy ? null : () => _runImport(settings, fromFile: false),
          ),
        ],
      ),
    );
  }

  Future<void> _runImport(
    SettingsProvider settings, {
    required bool fromFile,
  }) async {
    final text = await _readBackupText(fromFile: fromFile);
    if (text == null || !mounted) return;
    final BackupPack pack;
    try {
      pack = BackupService.instance.parse(text);
    } catch (e) {
      showToast('无法识别该文件：$e');
      return;
    }
    final keys = BackupService.describableKeys(pack);
    if (keys.isEmpty) {
      showToast('备份包里没有可导入的模块');
      return;
    }
    final sensitive = keys.where(
      (k) => BackupCatalog.byKey(k)?.sensitive ?? false,
    );
    if (sensitive.isNotEmpty && mounted) {
      final ok = await showConfirmDialog(
        context,
        title: '含敏感数据',
        message:
            '备份包包含：${sensitive.map(BackupService.labelOfKey).join('、')}。\n'
            '导入会覆盖本机对应数据，确认继续？',
        confirmText: '继续',
        danger: true,
      );
      if (ok != true || !mounted) return;
    }
    final onlyKeys = await _pickImportKeys(keys);
    if (onlyKeys == null || onlyKeys.isEmpty || !mounted) return;
    final opts = await showSelectDialog<String>(
      context: context,
      title: '导入方式',
      options: const [
        SelectOption(
          value: 'merge',
          icon: Icons.merge,
          label: '合并（推荐）',
          description: '保留本机数据，按主键去重后并入备份内容',
        ),
        SelectOption(
          value: 'replace',
          icon: Icons.swap_horiz,
          label: '覆盖',
          description: '用备份内容替换本机对应模块（原数据丢失）',
        ),
      ],
    );
    if (opts == null || !mounted) return;
    final strategy = await showSelectDialog<String>(
      context: context,
      title: '失败处理',
      options: const [
        SelectOption(
          value: 'perItem',
          icon: Icons.checklist,
          label: '逐项容错（推荐）',
          description: '某项失败只跳过该项，其余继续',
        ),
        SelectOption(
          value: 'atomic',
          icon: Icons.restore,
          label: '事务式',
          description: '任一项失败即把本次涉及的模块回滚到导入前',
        ),
      ],
    );
    if (strategy == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final summary = await BackupService.instance.applyText(
        text,
        mode: opts == 'merge' ? BackupApplyMode.merge : BackupApplyMode.replace,
        strategy: strategy == 'atomic'
            ? BackupImportStrategy.atomic
            : BackupImportStrategy.perItem,
        onlyKeys: onlyKeys,
        trigger: 'manual',
        keepDays: settings.backupSettings.logKeepDays,
      );
      if (!mounted) return;
      if (summary.needsReload) {
        await settings.load();
        settings.applyRuntimeConfig();
      }
      if (!mounted) return;
      showToast(summary.summaryText);
    } catch (e) {
      if (mounted) showToast('恢复失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导入前二次挑选模块（返回 null = 用户取消）
  Future<Set<String>?> _pickImportKeys(List<String> keys) async {
    final selected = keys.toSet();
    return showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('选择要恢复的内容'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final key in keys)
                  CheckboxListTile(
                    dense: true,
                    value: selected.contains(key),
                    title: Text(BackupService.labelOfKey(key)),
                    subtitle: Text(key),
                    onChanged: (v) => setLocal(() {
                      if (v == true) {
                        selected.add(key);
                      } else {
                        selected.remove(key);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(selected),
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== Web 备份 ====================

  Widget _buildWebCard(SettingsProvider settings, BackupSettings backup) {
    final web = backup.web;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.cloud_upload_outlined),
            title: const Text('启用 Web 备份'),
            subtitle: const Text('把备份包上传到你自己搭建的接口'),
            value: backup.webEnabled,
            onChanged: (v) => settings.setBackupWebEnabled(v),
          ),
          if (backup.webEnabled) ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('服务器地址'),
              subtitle: Text(
                web.url.isEmpty ? '未填写' : web.url,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final v = await _askText(
                  title: '服务器地址',
                  description:
                      '例如 https://nas.local/backup.php（POST/PUT 接收 JSON）',
                  initValue: web.url,
                  keyboardType: TextInputType.url,
                );
                if (v != null) {
                  await settings.setWebBackupConfig(web.copyWith(url: v));
                }
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.swap_vert),
              title: const Text('请求方法'),
              subtitle: Text(web.method),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final m = await showSelectDialog<String>(
                  context: context,
                  title: '请求方法',
                  options: const [
                    SelectOption(value: 'POST', label: 'POST'),
                    SelectOption(value: 'PUT', label: 'PUT'),
                  ],
                  selected: web.method,
                );
                 if (m != null) {
                   await settings.setWebBackupConfig(web.copyWith(method: m));
                 }
               },
             ),
             const Divider(height: 1),
             ListTile(
               leading: const Icon(Icons.vpn_key_outlined),
              title: const Text('鉴权头'),
              subtitle: Text(
                web.secretMode == SecretStoreMode.secure
                    ? '${web.headerName}: '
                          '${web.headerValue.isNotEmpty ? _maskSecret(web.headerValue) : '已存密钥库'}'
                    : '${web.headerName}: ${_maskSecret(web.headerValue)}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _editAuthHeader(settings, web),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('定时上传'),
              subtitle: Text(
                web.scheduled
                    ? '每 ${web.schedule.label}（${_scheduleHint(web.schedule)}）'
                    : '关闭（仅手动上传）',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _editSchedule(settings, web),
            ),
            const Divider(height: 1),
            SwitchListTile(
              secondary: const Icon(Icons.wifi),
              title: const Text('仅 Wi-Fi 上传'),
              subtitle: const Text('非 Wi-Fi 时跳过，避免偷跑流量'),
              value: web.wifiOnly,
              onChanged: (v) =>
                  settings.setWebBackupConfig(web.copyWith(wifiOnly: v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.receipt_long_outlined),
              title: const Text('附带运行日志'),
              subtitle: const Text('上传时把最近日志写进 logs 模块'),
              value: web.includeLogs,
              onChanged: (v) =>
                  settings.setWebBackupConfig(web.copyWith(includeLogs: v)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('立即上传'),
              subtitle: Text(
                web.lastRunAt.isEmpty
                    ? '从未上传'
                    : '上次：${_fmtTime(DateTime.tryParse(web.lastRunAt))}'
                          '${web.lastResult.isEmpty ? '' : ' · ${web.lastResult}'}',
              ),
              enabled: !_busy && web.usable,
              onTap: _busy || !web.usable
                  ? null
                  : () => _runWebUpload(settings, backup),
            ),
          ],
        ],
      ),
    );
  }

  /// 编辑鉴权头：先选存储方式（明文 / 系统密钥库），再填名字与值。
  ///
  /// 为什么要先选存储方式：它决定了「值写到哪里」，而两处的写法和
  /// 换机迁移能力完全不同。等用户填完再问，容易让他以为填进明文里更安全。
  Future<void> _editAuthHeader(
    SettingsProvider settings,
    WebBackupConfig web,
  ) async {
    final secureAvailable = SecretStore.available;
    final mode = await showSelectDialog<SecretStoreMode>(
      context: context,
      title: '鉴权头值存储方式',
      selected: web.secretMode,
      options: [
        for (final m in SecretStoreMode.values)
          if (m != SecretStoreMode.secure || secureAvailable)
            SelectOption(value: m, label: m.label, description: m.description),
      ],
    );
    if (mode == null || !mounted) return;
    if (mode != web.secretMode) {
      final ok = await settings.setWebBackupSecretMode(mode);
      if (!ok) {
        if (mounted) showToast('该平台不支持系统密钥库，已保持原方式');
        return;
      }
    }
    if (!mounted) return;
    // 重新取一次：切模式会搬值，旧对象里的 headerValue 已经不准了
    final current = settings.backupSettings.web;

    final name = await _askText(
      title: '鉴权头名',
      description: '常见值：Authorization / X-Api-Key',
      initValue: current.headerName,
    );
    if (name == null || !mounted) return;

    final value = await _askText(
      title: '鉴权头值',
      description: current.secretMode == SecretStoreMode.secure
          ? '例如 Bearer <token>。将写入系统密钥库，不随备份包迁移。'
          : '例如 Bearer <token>。明文保存在设置文档中，请勿在公共设备使用。',
      initValue: current.secretMode == SecretStoreMode.secure
          ? '' // 密钥库里的值不回显到输入框
          : current.headerValue,
      obscure: true,
    );
    if (value == null) return;

    if (current.secretMode == SecretStoreMode.secure) {
      // 留空 = 不改（用户只是改了个头名，不必重输令牌）
      if (value.isNotEmpty) {
        final ok = await SecretStore.write(BackupWebClient.secretKey, value);
        if (!ok) {
          if (mounted) showToast('写入系统密钥库失败');
          return;
        }
      }
      await settings.setWebBackupConfig(
        current.copyWith(headerName: name, headerValue: ''),
      );
      return;
    }
    await settings.setWebBackupConfig(
      current.copyWith(headerName: name, headerValue: value),
    );
  }

  Future<void> _runWebUpload(
    SettingsProvider settings,
    BackupSettings backup,
  ) async {
    final selection = settings.backupSelection;
    if (selection.count == 0) {
      showToast('请先勾选至少一个备份项');
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await BackupService.instance.build(
        selection,
        extraModules: backup.web.includeLogs
            ? {'logs': await BackupLogStore.instance.exportJson()}
            : null,
      );
      final upload = await BackupWebClient.instance.upload(
        result.json,
        backup.web,
      );
      if (!mounted) return;
      await settings.markWebBackupRun(
        at: DateTime.now(),
        result: upload.shortResult,
      );
      if (upload.ok) {
        await settings.markBackupDone(DateTime.now());
      }
      if (!mounted) return;
      showToast(upload.message);
    } catch (e) {
      if (mounted) showToast('上传失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ==================== 日志 ====================

  Widget _buildLogCard(SettingsProvider settings, BackupSettings backup) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.receipt_long),
            title: const Text('备份运行日志'),
            subtitle: const Text('查看每次备份 / 恢复的逐项结果'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/backup/logs'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.timelapse),
            title: const Text('日志保留天数'),
            subtitle: Text(
              backup.logKeepDays == 0
                  ? '不保留（每次写入即清空历史）'
                  : '${backup.logKeepDays} 天（最多 50 条）',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showNumberDialog(
              context: context,
              title: '日志保留天数',
              description: '超过天数的日志在下次写入时清理。0 = 不保留。',
              initValue: backup.logKeepDays,
              min: 0,
              max: 365,
              helperText: '默认 30',
              onSave: (v) async {
                await settings.setBackupLogKeepDays(v);
                settings.applyBackupRuntimeConfig();
              },
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 通用小工具 ====================
  /// 定时上传的一句话说明（把系统限制如实写出来，避免「设了但没跑」的投诉）。
  ///
  /// 「由系统调度」是重点：用户明确要求「一周一次」这种跨重启的周期，
  /// 所以我们用 WorkManager 而不是前台 Timer。代价是系统会按省电策略
  /// 合并延迟，实际时刻不精确——这一点必须写清楚，不能承诺「准时」。
  static String _scheduleHint(BackupSchedulePolicy s) {
    final parts = <String>['由系统调度，App 关闭也会执行'];
    if (s.requireCharging) parts.add('仅充电时');
    if (s.requireBatteryNotLow) parts.add('电量不低时');
    if (s.intervalMinutes > 0 && s.intervalMinutes < 15) {
      parts.add('系统最小 15 分钟，已按 15 分钟生效');
    }
    return parts.join('、');
  }

  /// 编辑定时上传：先填间隔数值，再选单位（0 = 关闭）。
  ///
  /// 拆成两次弹窗而不是自造大表单：`showNumberDialog` / `showSelectDialog`
  /// 已是设置页统一交互，自造表单会与其他入口风格不一致。
  /// 注意 `showNumberDialog` 返回 `Future<void>`，取值走 `onSave` 回调。
  Future<void> _editSchedule(
    SettingsProvider settings,
    WebBackupConfig web,
  ) async {
    final s = web.schedule;
    await showNumberDialog(
      context: context,
      title: '定时上传间隔',
      description: '0 = 关闭定时。单位在下一步选择。',
      initValue: s.interval,
      min: 0,
      max: 9999,
      helperText: '当前：${s.label}',
      onSave: (v) async {
        if (v == 0) {
          await settings.setWebBackupConfig(
            web.copyWith(schedule: s.copyWith(interval: 0)),
          );
          settings.applyBackupRuntimeConfig();
          return;
        }
        if (!mounted) return;
        final unit = await showSelectDialog<BackupIntervalUnit>(
          context: context,
          title: '间隔单位',
          selected: s.unit,
          options: [
            for (final u in BackupIntervalUnit.values)
              SelectOption(value: u, label: u.label),
          ],
        );
        if (unit == null) return;
        await settings.setWebBackupConfig(
          web.copyWith(schedule: s.copyWith(interval: v, unit: unit)),
        );
        settings.applyBackupRuntimeConfig();
      },
    );
  }

  Future<void> _deliverJson(String json, String prefix) async {
    final mode = await showSelectDialog<String>(
      context: context,
      title: '导出方式',
      options: const [
        SelectOption(
          value: 'clipboard',
          icon: Icons.copy_all_outlined,
          label: '复制到剪切板',
        ),
        SelectOption(value: 'file', icon: Icons.save_alt, label: '保存为文件'),
      ],
    );
    if (mode == null || !mounted) return;
    if (mode == 'clipboard') {
      await ClipboardHelper.write(json);
      if (mounted) showToast('已复制到剪切板');
      return;
    }
    final fileName = '${prefix}_${_timestamp()}.json';
    final outcome = await FileSave.saveText(
      json,
      fileName: fileName,
      allowedExtensions: const ['json'],
    );
    if (!mounted) return;
    switch (outcome) {
      case FileSaveOutcome.saved:
        showToast('已保存');
      case FileSaveOutcome.canceled:
        break;
      case FileSaveOutcome.unavailable:
        // 平台没有「另存为」：退回应用导出目录，至少让文件落地
        final dir = await AppPaths.exportsDir;
        await Directory(dir).create(recursive: true);
        final path = p.join(dir, fileName);
        await File(path).writeAsString(json);
        if (mounted) showToast('已保存到 $path');
      case FileSaveOutcome.failed:
        showToast('保存失败');
    }
  }

  Future<String?> _readBackupText({required bool fromFile}) async {
    if (!fromFile) {
      final text = await ClipboardHelper.read();
      if (text == null || text.trim().isEmpty) {
        if (mounted) showToast('剪切板为空');
        return null;
      }
      return text;
    }
    final result = await FilePick.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    final files = result?.files;
    if (files == null || files.isEmpty) return null;
    final file = files.first;
    final bytes = file.bytes;
    if (bytes != null) return utf8.decode(bytes);
    final path = file.path;
    if (path != null) return File(path).readAsString();
    if (mounted) showToast('无法读取文件');
    return null;
  }

  Future<String?> _askText({
    required String title,
    String? description,
    String initValue = '',
    TextInputType keyboardType = TextInputType.text,
    bool obscure = false,
  }) => showDialog<String>(
    context: context,
    builder: (_) => _TextInputDialog(
      title: title,
      description: description,
      initValue: initValue,
      keyboardType: keyboardType,
      obscure: obscure,
    ),
  );

  static String _maskSecret(String value) {
    if (value.isEmpty) return '（未填写）';
    if (value.length <= 8) return '••••';
    return '${value.substring(0, 6)}••••${value.substring(value.length - 2)}';
  }

  static String _fmtTime(DateTime? at) {
    if (at == null) return '未知时间';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }

  static String _timestamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_'
        '${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }
}

/// 单行文本输入弹窗（设置页没有通用的文本输入弹窗，这里按需自带一个）。
///
/// 控制器由 State 持有并在 dispose 释放：不能在 `await showDialog` 之后释放，
/// 弹窗退场动画期间子树仍会重建（同 docs/07 #51 的教训）。
class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    this.description,
    required this.initValue,
    required this.keyboardType,
    required this.obscure,
  });

  final String title;
  final String? description;
  final String initValue;
  final TextInputType keyboardType;
  final bool obscure;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.description != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                widget.description!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: widget.keyboardType,
            obscureText: widget.obscure,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
