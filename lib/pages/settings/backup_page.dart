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
import 'package:mtbbs/services/backup/backup_local_store.dart';
import 'package:mtbbs/services/backup/backup_log_store.dart';
import 'package:mtbbs/services/backup/backup_pack.dart';
import 'package:mtbbs/services/backup/backup_registry.dart';
import 'package:mtbbs/services/backup/backup_service.dart';
import 'package:mtbbs/services/backup/backup_web_client.dart';
import 'package:mtbbs/services/data_portability.dart';
import 'package:mtbbs/widgets/common/toast_utils.dart';
import 'package:mtbbs/widgets/dialog/confirm_dialog.dart';

/// 备份与恢复页 —— 自定义备份项的唯一 UI 入口。
///
/// 三块内容：
/// 1. **备份内容**：`BackupCatalog` 声明的复选框树（分组 / 半选 / 依赖级联）；
/// 2. **备份 / 恢复**：立即导出（剪切板或文件）、从剪切板 / 文件导入，
///    导入前预览模块清单并二次确认敏感项；
/// 3. **本地备份**：定时把备份包写进应用私有目录，按份数轮转；
/// 4. **Web 备份**：标准 WebDAV（地址 / 用户 / 密码 / 路径 + 定时 / 仅 Wi-Fi / 带日志），
///    形态与逻辑借鉴 bggRGjQaUbCoE/PiliPlus 的 WebDAV 设置页。
///
/// 设计约束（见 docs/28）：
/// - 勾选状态只落独立 KV 键 `backupSettings`（`BackupSettingsStore`），
///   不新增 SharedPreferences；也不挂在 `AppSettings` 里（那是上游的文件，
///   加 fork 专属字段会让每次上游合并都冲突）；
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

  /// 本次会话里刚删掉的本地备份文件名（仅用于弹窗内即时刷新，不持久化）
  final Set<String> _deleted = <String>{};

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
          _sectionHeader('账号 Cookie', '单独导出 / 导入登录凭据，与上游格式一致'),
          _buildCookiesCard(settings),
          _sectionHeader('本地备份', '存在应用私有目录，卸载即清；不需要网络'),
          _buildLocalCard(settings, backup),
          _sectionHeader(
            'Web 备份',
            '借鉴于 bggRGjQaUbCoE/PiliPlus 的 WebDAV 设置；服务器由你自备'
                '（坚果云 / Nextcloud / 群晖均可）',
          ),
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
    await _importText(settings, text);
  }

  /// 对一段备份 JSON 文本执行导入。
  ///
  /// 三个入口共用：从文件、从剪切板、从本机备份文件。
  /// 抽出来是为了让「本机备份」也能走同一套敏感项确认 / 模块挑选 / 策略选择，
  /// 否则两套导入流程迟早会在某个校验上分叉。
  Future<void> _importText(SettingsProvider settings, String text) async {
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

  // ==================== 本地备份 ====================

  Widget _buildLocalCard(SettingsProvider settings, BackupSettings backup) {
    final local = backup.local;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.phone_android_outlined),
            title: const Text('启用本地备份'),
            subtitle: const Text('定时把备份包写进本机，断网也能恢复'),
            value: local.enabled,
            onChanged: (v) => settings.setLocalBackupEnabled(v),
          ),
          if (local.enabled) ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('定时备份'),
              subtitle: Text(
                local.scheduled
                    ? '每 ${local.schedule.label}（${_scheduleHint(local.schedule)}）'
                    : '关闭（仅手动备份）',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _editLocalSchedule(settings, local),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('保留份数'),
              subtitle: Text(
                local.keepCount <= 0
                    ? '不清理（全部保留）'
                    : '只留最新 ${local.effectiveKeepCount} 份，更早的自动删除',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showNumberDialog(
                context: context,
                title: '保留份数',
                description: '超出份数时删除最旧的。0 = 全部保留。',
                initValue: local.keepCount,
                min: 0,
                max: 100,
                helperText: '默认 5',
                onSave: (v) async {
                  await settings.setLocalBackupKeepCount(v);
                  settings.applyBackupRuntimeConfig();
                },
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.save_outlined),
              title: const Text('立即备份到本机'),
              subtitle: Text(
                local.lastRunAt.isEmpty
                    ? '从未备份'
                    : '上次：${_fmtTime(DateTime.tryParse(local.lastRunAt))}'
                          '${local.lastResult.isEmpty ? '' : ' · ${local.lastResult}'}',
              ),
              enabled: !_busy,
              onTap: _busy ? null : () => _runLocalBackup(settings),
            ),
          ],
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('本机备份文件'),
            subtitle: const Text('查看 / 恢复 / 删除已保存的备份'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : () => _showLocalFiles(settings),
          ),
        ],
      ),
    );
  }

  /// 立即备份到本机：与定时任务走同一条收集路径，只是不经过 WorkManager。
  ///
  /// 为什么不直接排一次后台任务：后台 isolate 要重新读站点/设置，而用户
  /// 点「立即」的期望是「马上看到文件」；此外部分机型首次注册一次性任务
  /// 有可见延迟。这里在主 isolate 直接生成 + 写盘，结果当场回写。
  Future<void> _runLocalBackup(SettingsProvider settings) async {
    final selection = settings.backupSelection;
    if (selection.count == 0) {
      showToast('请先勾选至少一个备份项');
      return;
    }
    final local = settings.backupSettings.local;
    setState(() => _busy = true);
    try {
      final result = await BackupService.instance.exportToJson(
        selection,
        trigger: 'manual',
        includeLogs: false,
      );
      final name = await BackupLocalStore.instance.save(
        result.json,
        keepCount: local.effectiveKeepCount,
      );
      if (!mounted) return;
      await settings.markLocalBackupRun(
        at: DateTime.now(),
        result: 'ok',
        fileName: name,
      );
      if (!mounted) return;
      showToast('已备份到本机：$name');
    } catch (e) {
      if (!mounted) return;
      await settings.markLocalBackupRun(
        at: DateTime.now(),
        result: 'failed: $e',
      );
      if (mounted) showToast('本地备份失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 本地备份文件列表：可恢复 / 可删除。
  ///
  /// 恢复走与「从文件恢复」完全相同的 apply 流程（含敏感项确认、
  /// 模块挑选、合并/覆盖策略），只是文本来源换成私有目录里的文件。
  Future<void> _showLocalFiles(SettingsProvider settings) async {
    final files = await BackupLocalStore.instance.list();
    if (!mounted) return;
    if (files.isEmpty) {
      showToast('还没有本机备份文件');
      return;
    }
    final picked = await showDialog<LocalBackupFile>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        // 删完要当场刷新列表：重建整张弹窗比「关掉再让用户点开」自然，
        // 也不会让用户以为删除没生效。
        builder: (ctx, setLocal) {
          final items = files.where((f) => !_deleted.contains(f.name)).toList();
          final total = items.fold<int>(0, (s, f) => s + f.sizeBytes);
          return AlertDialog(
            title: const Text('本机备份文件'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    items.isEmpty
                        ? '已清空'
                        : '共 ${items.length} 份 · ${_sizeLabel(total)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 固定最大高度：备份多时列表自己滚，不把弹窗撑出屏幕
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final f = items[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.description_outlined),
                          title: Text(_prettyName(f.name)),
                          subtitle: Text(
                            '${_fmtTime(f.modifiedAt)} · ${f.sizeLabel}',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: '删除',
                            onPressed: () async {
                              final ok = await showConfirmDialog(
                                ctx,
                                title: '删除备份',
                                message: '确认删除 ${f.name}？此操作不可撤销。',
                                confirmText: '删除',
                                danger: true,
                              );
                              if (ok != true) return;
                              await BackupLocalStore.instance.delete(f.name);
                              if (!ctx.mounted) return;
                              setLocal(() => _deleted.add(f.name));
                            },
                          ),
                          onTap: () => Navigator.of(ctx).pop(f),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
    if (picked == null || !mounted) return;
    await _restoreLocalFile(settings, picked);
  }

  /// 从某个本地备份文件恢复（复用导入流程）
  Future<void> _restoreLocalFile(
    SettingsProvider settings,
    LocalBackupFile file,
  ) async {
    final String text;
    try {
      text = await BackupLocalStore.instance.read(file.name);
    } catch (e) {
      if (mounted) showToast('读取失败：$e');
      return;
    }
    if (!mounted) return;
    await _importText(settings, text);
  }

  /// 编辑本地备份定时（与 Web 那套交互一致，只是写到 local 上）
  Future<void> _editLocalSchedule(
    SettingsProvider settings,
    LocalBackupConfig local,
  ) async {
    final s = local.schedule;
    await showNumberDialog(
      context: context,
      title: '定时备份间隔',
      description: '0 = 关闭定时。单位在下一步选择。',
      initValue: s.interval,
      min: 0,
      max: 9999,
      helperText: '当前：${s.label}',
      onSave: (v) async {
        if (v == 0) {
          await settings.setLocalBackupSchedule(s.copyWith(interval: 0));
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
        await settings.setLocalBackupSchedule(
          s.copyWith(interval: v, unit: unit),
        );
        settings.applyBackupRuntimeConfig();
      },
    );
  }

  // ==================== 独立 Cookie 备份 ====================

  /// 独立的「导出 / 导入账号 Cookie」入口。
  ///
  /// 产物格式是上游那套 `mtbbs.cookies` v1（`DataPortability`），
  /// 与备份包里的 `cookies` 模块**同源**：都是先 `exportCookiesJson()`
  /// 再剥字段。所以这里导出的文件也能被上游 App 直接导入，反之亦然。
  Widget _buildCookiesCard(SettingsProvider settings) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.cookie_outlined),
            title: const Text('导出账号 Cookie'),
            subtitle: const Text('各站点登录凭据（mtbbs.cookies，上游可直接导入）'),
            enabled: !_busy,
            onTap: _busy ? null : () => _exportCookiesOnly(),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.download_for_offline_outlined),
            title: const Text('导入账号 Cookie'),
            subtitle: const Text('覆盖本机 Cookie，不动账号列表'),
            enabled: !_busy,
            onTap: _busy ? null : () => _importCookiesOnly(settings),
          ),
        ],
      ),
    );
  }

  /// 只导出 Cookie（不含账号列表），格式与上游一致
  Future<void> _exportCookiesOnly() async {
    setState(() => _busy = true);
    try {
      final doc = (jsonDecode(await DataPortability.exportCookiesJson()) as Map)
          .cast<String, dynamic>();
      // 剥掉 accounts：账号列表属另一项，这里只给凭据
      final sites = doc['sites'];
      if (sites is List) {
        doc['sites'] = [
          for (final raw in sites)
            if (raw is Map)
              {
                'host': raw['host'],
                'baseUrl': raw['baseUrl'],
                'cookies': raw['cookies'],
              },
        ];
      }
      final json = const JsonEncoder.withIndent('  ').convert(doc);
      if (!mounted) return;
      await _deliverJson(json, 'mtbbs_cookies');
      if (mounted) showToast('已导出 Cookie');
    } catch (e) {
      if (mounted) showToast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 只导入 Cookie：从文件或剪切板读 `mtbbs.cookies`
  Future<void> _importCookiesOnly(SettingsProvider settings) async {
    final mode = await showSelectDialog<String>(
      context: context,
      title: 'Cookie 来源',
      options: const [
        SelectOption(value: 'file', icon: Icons.folder_open, label: '选择文件'),
        SelectOption(
          value: 'clipboard',
          icon: Icons.content_paste,
          label: '从剪切板粘贴',
        ),
        SelectOption(
          value: 'local',
          icon: Icons.phone_android_outlined,
          label: '从本机备份中选',
          description: '本机备份里的 cookies 模块',
        ),
      ],
    );
    if (mode == null || !mounted) return;
    String? text;
    if (mode == 'clipboard') {
      text = await ClipboardHelper.read();
      if (text == null || text.trim().isEmpty) {
        if (mounted) showToast('剪切板为空');
        return;
      }
    } else if (mode == 'file') {
      text = await _readBackupText(fromFile: true);
    } else {
      text = await _pickCookiesFromLocal();
    }
    if (text == null || text.trim().isEmpty || !mounted) return;

    // 两种来源都接受：独立的 mtbbs.cookies，或含 cookies 模块的备份包。
    String payload;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) throw const FormatException('不是有效的 JSON 对象');
      final doc = decoded.cast<String, dynamic>();
      final format = doc['format']?.toString() ?? '';
      if (format == DataPortability.cookiesFormat) {
        payload = text;
      } else {
        // 备份包：取出 cookies 模块的 payload 再走同一导入器。
        // 注意 modules 是「键 → payload」，取出来直接就是那段 JSON。
        final pack = BackupService.instance.parse(text);
        final module = pack.modules['cookies'];
        if (module == null) {
          if (mounted) showToast('该备份包里没有 Cookie 模块');
          return;
        }
        payload = jsonEncode(module);
      }
    } catch (e) {
      if (mounted) showToast('无法识别该内容：$e');
      return;
    }
    if (!mounted) return;
    final ok = await showConfirmDialog(
      context,
      title: '覆盖本机 Cookie？',
      message:
          '导入会用文件里的凭据替换本机各站点 Cookie，'
          '账号列表不受影响。若当前处于登录状态，可能需要重新登录。',
      confirmText: '覆盖',
      danger: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await DataPortability.importCookiesJson(payload);
      if (!mounted) return;
      if (result.hosts.isNotEmpty) {
        await settings.load();
        settings.applyRuntimeConfig();
      }
      if (!mounted) return;
      showToast('已导入 ${result.jars} 份 Cookie，涉及 ${result.hosts.length} 个站点');
    } catch (e) {
      if (mounted) showToast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 从本机备份文件里挑一个，取出其 cookies 模块的 JSON
  Future<String?> _pickCookiesFromLocal() async {
    final files = await BackupLocalStore.instance.list();
    if (!mounted) return null;
    if (files.isEmpty) {
      showToast('还没有本机备份文件');
      return null;
    }
    final picked = await showSelectDialog<LocalBackupFile>(
      context: context,
      title: '选择本机备份',
      options: [
        for (final f in files)
          SelectOption(
            value: f,
            icon: Icons.description_outlined,
            label: _prettyName(f.name),
            description: '${_fmtTime(f.modifiedAt)} · ${f.sizeLabel}',
          ),
      ],
    );
    if (picked == null || !mounted) return null;
    try {
      return await BackupLocalStore.instance.read(picked.name);
    } catch (e) {
      if (mounted) showToast('读取失败：$e');
      return null;
    }
  }

  static String _prettyName(String name) {
    // mtbbs_auto_20251108_033512.json → 2025-11-08 03:35:12
    final m = RegExp(
      r'(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})',
    ).firstMatch(name);
    if (m == null) return name;
    return '${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:${m[6]}';
  }

  static String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  // ==================== Web 备份（WebDAV） ====================

  /// 四个输入框的控制器。放在 State 里而不是每次 build 新建：
  /// 每次 build 新建会让光标位置在每次 setState 后跳回开头。
  late final TextEditingController _davUriCtr;
  late final TextEditingController _davUserCtr;
  late final TextEditingController _davPassCtr;
  late final TextEditingController _davDirCtr;
  bool _davObscure = true;

  /// 控制器与「上一次同步进来的配置」。
  ///
  /// 不能在 `initState` 里读 Provider（那时还拿不到），所以懒初始化。
  /// 记录 `_davSynced` 是为了区分「外部改了配置」和「用户正在输入」：
  /// 前者要刷新输入框（如导入备份包后），后者绝不能覆盖（会让光标跳到末尾）。
  bool _davCtrReady = false;
  WebBackupConfig? _davSynced;

  void _ensureDavControllers(WebBackupConfig web) {
    if (!_davCtrReady) {
      _davUriCtr = TextEditingController(text: web.uri);
      _davUserCtr = TextEditingController(text: web.username);
      // 加密模式下密码在密钥库里，输入框留空（提示语已说明「留空 = 不改」）
      _davPassCtr = TextEditingController(
        text: web.secretMode == SecretStoreMode.secure ? '' : web.password,
      );
      _davDirCtr = TextEditingController(text: web.directory);
      _davSynced = web;
      _davCtrReady = true;
      return;
    }
    // 同步外部变更（导入备份 / 走别的入口改了配置），但不打断用户输入
    final prev = _davSynced;
    if (prev == null ||
        (prev.uri == web.uri &&
            prev.username == web.username &&
            prev.password == web.password &&
            prev.directory == web.directory &&
            prev.secretMode == web.secretMode)) {
      return;
    }
    void sync(TextEditingController c, String next) {
      // 只在该字段确实变了时改：无条件赋值会把光标位置重置到开头
      if (c.text != next) c.text = next;
    }

    sync(_davUriCtr, web.uri);
    sync(_davUserCtr, web.username);
    sync(
      _davPassCtr,
      web.secretMode == SecretStoreMode.secure ? '' : web.password,
    );
    sync(_davDirCtr, web.directory);
    _davSynced = web;
  }

  @override
  void dispose() {
    if (_davCtrReady) {
      _davUriCtr.dispose();
      _davUserCtr.dispose();
      _davPassCtr.dispose();
      _davDirCtr.dispose();
    }
    super.dispose();
  }

  Widget _buildWebCard(SettingsProvider settings, BackupSettings backup) {
    final web = backup.web;
    _ensureDavControllers(web);
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.cloud_upload_outlined),
            title: const Text('启用 Web 备份'),
            subtitle: const Text('把备份包传到你的 WebDAV 网盘（坚果云 / Nextcloud / 群晖）'),
            value: backup.webEnabled,
            onChanged: (v) => settings.setBackupWebEnabled(v),
          ),
          if (backup.webEnabled) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                children: [
                  TextField(
                    controller: _davUriCtr,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '地址',
                      hintText: 'https://dav.jianguoyun.com/dav/',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _davUserCtr,
                    decoration: const InputDecoration(
                      labelText: '用户',
                      hintText: '坚果云填账号邮箱',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _davPassCtr,
                    obscureText: _davObscure,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: '密码',
                      hintText: '坚果云填「应用授权码」，不是登录密码',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: IconButton(
                        onPressed: () =>
                            setState(() => _davObscure = !_davObscure),
                        icon: _davObscure
                            ? const Icon(Icons.visibility)
                            : const Icon(Icons.visibility_off),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _davDirCtr,
                    decoration: const InputDecoration(
                      labelText: '路径',
                      hintText:
                          '默认 ${WebBackupConfig.defaultDirectory}；'
                          '可改成任意子目录，如 backup 或 备份/手机',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '云端文件：${web.remoteFileLabel}',
                      style: TextStyle(fontSize: 11, color: cs.outline),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: _busy ? null : () => _saveAndTestDav(settings),
                      child: const Text('连接测试'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: _busy
                          ? null
                          : () => _runWebUpload(settings, backup),
                      child: const Text('立即备份'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: _busy ? null : () => _runWebRestore(settings),
                      child: const Text('从云端恢复'),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 28),
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
            SwitchListTile(
              secondary: Icon(
                web.secretMode == SecretStoreMode.secure
                    ? Icons.lock_outline
                    : Icons.lock_open_outlined,
              ),
              title: const Text('把密码存进系统密钥库'),
              subtitle: Text(
                web.secretMode == SecretStoreMode.secure
                    ? '已启用：密码存在 Keystore / Keychain，不随备份包迁移'
                    : '当前明文保存在设置文档中；公共设备建议开启',
              ),
              value: web.secretMode == SecretStoreMode.secure,
              onChanged: SecretStore.available
                  ? (v) => _toggleDavSecret(settings, v)
                  : null,
            ),
            if (!SecretStore.available)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  '当前平台没有可用的系统密钥库，只能明文保存',
                  style: TextStyle(fontSize: 11, color: cs.outline),
                ),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('上次结果'),
              subtitle: Text(
                web.lastRunAt.isEmpty
                    ? '从未上传'
                    : '${_fmtTime(DateTime.tryParse(web.lastRunAt))}'
                          '${web.lastResult.isEmpty ? '' : ' · ${web.lastResult}'}',
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 保存四个输入框 + 连接测试（对应 PiliPlus 的保存 FAB 里调 `init()`）。
  ///
  /// 先落库再测试：测试用的是「刚填进去的值」，而不是旧配置。
  /// 地址为空时只保存不测试（PiliPlus 也是这个行为）——
  /// 用户可能只是想先清空。
  Future<void> _saveAndTestDav(SettingsProvider settings) async {
    final uri = _davUriCtr.text.trim();
    final user = _davUserCtr.text.trim();
    final pass = _davPassCtr.text;
    final dir = _davDirCtr.text.trim();
    final web = settings.backupSettings.web;

    // 加密模式下输入框留空 = 不改（值已在密钥库），别把空串写回去
    final keepSecret = web.secretMode == SecretStoreMode.secure && pass.isEmpty;
    final next = web.copyWith(
      uri: uri,
      username: user,
      password: keepSecret ? null : pass,
      directory: dir,
    );
    if (web.secretMode == SecretStoreMode.secure && pass.isNotEmpty) {
      final ok = await SecretStore.write(BackupWebClient.secretKey, pass);
      if (!ok) {
        if (mounted) showToast('写入系统密钥库失败');
        return;
      }
    }
    await settings.setWebBackupConfig(next);
    // 基线一起推进：否则下次 build 会判定为「外部变更」，
    // 加密模式下会把用户刚输入的密码从输入框里抹掉
    _davSynced = next;
    if (uri.isEmpty) {
      if (mounted) showToast('已保存（地址为空，未做连接测试）');
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final result = await BackupWebClient.instance.test(next);
      if (!mounted) return;
      showToast(result.ok ? '配置成功' : '配置失败：${result.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 切换密码存储方式（明文 ↔ 系统密钥库）
  Future<void> _toggleDavSecret(SettingsProvider settings, bool secure) async {
    final target = secure ? SecretStoreMode.secure : SecretStoreMode.plain;
    // 切到明文前先把输入框里的值落进设置，否则刚输入的密码会丢
    if (!secure && _davPassCtr.text.isNotEmpty) {
      await settings.setWebBackupConfig(
        settings.backupSettings.web.copyWith(password: _davPassCtr.text),
      );
    }
    final ok = await settings.setWebBackupSecretMode(target);
    if (!mounted) return;
    if (!ok) {
      showToast('该平台不支持系统密钥库，已保持原方式');
      return;
    }
    // 切模式会搬值，控制器要跟着同步一次
    final web = settings.backupSettings.web;
    _davPassCtr.text = web.secretMode == SecretStoreMode.secure
        ? ''
        : web.password;
    _davSynced = web;
    showToast(
      web.secretMode == SecretStoreMode.secure ? '已存入系统密钥库' : '已改为明文保存',
    );
  }

  /// 手动上传一次备份包（对应 PiliPlus 的「备份设置」按钮）
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

  /// 从云端读回备份包并走与「从文件导入」完全相同的流程
  /// （对应 PiliPlus 的「恢复设置」按钮）。
  ///
  /// 复用 `_importText`：敏感项确认、模块挑选、合并/覆盖、失败策略
  /// 一个都不少，避免云端恢复走一条更宽松的旁路。
  Future<void> _runWebRestore(SettingsProvider settings) async {
    final web = settings.backupSettings.web;
    if (!web.usable) {
      showToast('请先填写并保存 WebDAV 地址');
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await BackupWebClient.instance.download(web);
      if (!mounted) return;
      if (!result.ok || result.text == null) {
        showToast(result.message);
        return;
      }
      await _importText(settings, result.text!);
    } catch (e) {
      if (mounted) showToast('恢复失败：$e');
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
          web.copyWith(
            schedule: s.copyWith(interval: v, unit: unit),
          ),
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
    final outcome = await FileSave.saveText(json, fileName: fileName);
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
    final file = await FilePick.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (file == null) return null;
    final path = file.path;
    try {
      // file_picker 13 不再预带 bytes，Android 走 path，其它平台按需 readAsBytes
      if (path != null) return await File(path).readAsString();
      return utf8.decode(await file.readAsBytes());
    } catch (e) {
      if (mounted) showToast('读取文件失败：$e');
      return null;
    } finally {
      await FilePick.cleanupTemp(path);
    }
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
