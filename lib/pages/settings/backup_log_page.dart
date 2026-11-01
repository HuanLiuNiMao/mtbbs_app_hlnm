import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:mtbbs/core/app/app_paths.dart';
import 'package:mtbbs/core/utils/clipboard_helper.dart';
import 'package:mtbbs/models/backup/backup_log_entry.dart';
import 'package:mtbbs/pages/settings/widgets/dialogs.dart';
import 'package:mtbbs/platform/optional/file_save.dart';
import 'package:mtbbs/services/backup/backup_log_store.dart';
import 'package:mtbbs/widgets/common/toast_utils.dart';
import 'package:mtbbs/widgets/dialog/confirm_dialog.dart';

/// 备份运行日志页 —— 列出 `BackupLogStore` 里最近的运行记录。
///
/// 只读页：点击一条展开逐项结果（key / 条数 / 耗时 / 错误）。
/// 支持导出纯文本或 JSON（用户反馈问题时可贴出来）。
class BackupLogPage extends StatefulWidget {
  const BackupLogPage({super.key});

  @override
  State<BackupLogPage> createState() => _BackupLogPageState();
}

class _BackupLogPageState extends State<BackupLogPage> {
  List<BackupRunLogEntry>? _entries;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final list = await BackupLogStore.instance.all();
    if (!mounted) return;
    setState(() {
      _entries = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('备份运行日志'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: '导出',
            onPressed: _export,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空',
            onPressed: _clear,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _reload,
              child: (_entries == null || _entries!.isEmpty)
                  ? ListView(
                      children: [
                        const SizedBox(height: 120),
                        Center(
                          child: Text(
                            '暂无备份日志',
                            style: TextStyle(color: cs.outline),
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      itemCount: _entries!.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 16),
                      itemBuilder: (_, i) => _buildEntry(_entries![i]),
                    ),
            ),
    );
  }

  Widget _buildEntry(BackupRunLogEntry e) {
    final cs = Theme.of(context).colorScheme;
    return ExpansionTile(
      leading: Icon(
        e.ok ? Icons.check_circle_outline : Icons.error_outline,
        color: e.ok ? cs.primary : cs.error,
      ),
      title: Text(e.title),
      subtitle: Text(e.subtitle),
      childrenPadding: const EdgeInsets.fromLTRB(24, 0, 16, 12),
      children: [
        if (e.keys.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '模块：${e.keys.join(', ')}',
                style: TextStyle(fontSize: 12, color: cs.outline),
              ),
            ),
          ),
        for (final item in e.items)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                item.summary,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: item.ok ? null : cs.error,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _export() async {
    final mode = await showSelectDialog<String>(
      context: context,
      title: '导出格式',
      options: const [
        SelectOption(value: 'text', icon: Icons.notes, label: '纯文本（便于贴到反馈里）'),
        SelectOption(
          value: 'json',
          icon: Icons.data_object,
          label: 'JSON（便于脚本处理）',
        ),
      ],
    );
    if (mode == null || !mounted) return;
    final String text;
    if (mode == 'json') {
      final json = await BackupLogStore.instance.exportJson();
      text = const JsonEncoder.withIndent('  ').convert(json);
    } else {
      text = await BackupLogStore.instance.exportText();
    }
    if (!mounted) return;
    final dest = await showSelectDialog<String>(
      context: context,
      title: '导出到',
      options: const [
        SelectOption(
          value: 'clipboard',
          icon: Icons.copy_all_outlined,
          label: '复制到剪切板',
        ),
        SelectOption(value: 'file', icon: Icons.save_alt, label: '保存为文件'),
      ],
    );
    if (dest == null || !mounted) return;
    if (dest == 'clipboard') {
      await ClipboardHelper.write(text);
      if (mounted) showToast('已复制到剪切板');
      return;
    }
    final fileName =
        'mtbbs_backup_log_${mode == 'json' ? 'json' : 'txt'}'
        '_${DateTime.now().millisecondsSinceEpoch}.${mode == 'json' ? 'json' : 'txt'}';
    final outcome = await FileSave.saveText(
      text,
      fileName: fileName,
      allowedExtensions: [mode == 'json' ? 'json' : 'txt'],
    );
    if (!mounted) return;
    switch (outcome) {
      case FileSaveOutcome.saved:
        showToast('已保存');
      case FileSaveOutcome.canceled:
        break;
      case FileSaveOutcome.unavailable:
        final dir = await AppPaths.exportsDir;
        await Directory(dir).create(recursive: true);
        final path = p.join(dir, fileName);
        await File(path).writeAsString(text);
        if (mounted) showToast('已保存到 $path');
      case FileSaveOutcome.failed:
        showToast('保存失败');
    }
  }

  Future<void> _clear() async {
    final ok = await showConfirmDialog(
      context,
      title: '清空日志',
      message: '将删除全部备份运行日志（不影响备份包本身）。',
      confirmText: '清空',
      danger: true,
    );
    if (ok != true || !mounted) return;
    await BackupLogStore.instance.clear();
    if (!mounted) return;
    await _reload();
    if (mounted) showToast('已清空');
  }
}
