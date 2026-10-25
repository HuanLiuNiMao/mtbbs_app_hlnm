import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mtbbs/core/utils/content_filter.dart';
import 'package:mtbbs/providers/settings_provider.dart';

/// 帖子列表屏蔽 — 二级设置页
///
/// 四个帖子列表点（社区 / 导读 / 搜索 / 个人主页）各自独立配置：
/// - 屏蔽开关（整组总开关，关闭则该列表完全不过滤）
/// - 板块黑/白名单 + 名单
/// - 标题关键词（正则语义，与评论屏蔽词共用匹配器）
///
/// 旧全局配置在首次进入时已自动迁移为各点初始值（见 persistence 层）。
class ThreadFilterScopeSettingsPage extends StatelessWidget {
  const ThreadFilterScopeSettingsPage({super.key});

  /// scope 标识（与 provider 持久化键一致）
  static const List<String> _scopes = [
    kThreadScopeCommunity,
    kThreadScopeGuide,
    kThreadScopeSearch,
    kThreadScopeUser,
  ];
  /// 列表点显示名（顺序与 _scopes 一致）
  static const List<String> _scopeTitles = [
    '社区页（含标签页）',
    '导读页',
    '搜索结果页',
    '个人主页帖子列表',
  ];
  static const List<String> _scopeHints = [
    '社区版块页与版块标签页的帖子列表',
    '导读页（最新回复 / 精华等视图）',
    '站内搜索结果列表',
    '个人主页的主题 / 回帖列表',
  ];

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('帖子列表屏蔽'), centerTitle: true),
      body: ListView(
        children: [
          for (var i = 0; i < _scopes.length; i++)
            _buildScopeSection(context, s, _scopes[i], _scopeTitles[i], _scopeHints[i]),
        ],
      ),
    );
  }

  Widget _buildScopeSection(
    BuildContext context,
    SettingsProvider s,
    String scope,
    String title,
    String hint,
  ) {
    final f = s.threadScopeFilter(scope);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(hint, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
              Switch(
                value: f.enabled,
                onChanged: (v) => s.setThreadScopeFilter(scope, f.copyWith(enabled: v)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            children: [
              _row(
                context,
                icon: Icons.block,
                label: f.modeBlock ? '板块黑名单' : '板块白名单',
                sub: f.boards.isEmpty
                    ? '未设置'
                    : (f.modeBlock ? '黑名单：' : '白名单：') + f.boards.join('、'),
                onTap: () => _editBoards(context, s, scope, title, f),
              ),
              _row(
                context,
                icon: Icons.topic_outlined,
                label: '标题关键词',
                sub: f.keywords.isEmpty
                    ? '未设置'
                    : '命中即隐藏：${f.keywords.join('、')}',
                onTap: () => _editKeywords(context, s, scope, title, f),
              ),
              _row(
                context,
                icon: Icons.flip,
                label: '名单模式',
                sub: f.modeBlock ? '当前：黑名单（命中隐藏）' : '当前：白名单（仅命中显示）',
                onTap: () => s.setThreadScopeFilter(scope, f.copyWith(modeBlock: !f.modeBlock)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Future<void> _editBoards(
    BuildContext context,
    SettingsProvider s,
    String scope,
    String scopeTitle,
    ThreadScopeFilter f,
  ) async {
    final r = await _showScopeListDialog(
      context: context,
      title: '$scopeTitle · 板块名单',
      description: '每行一个板块名（须与页面显示的板块名一致），留空表示不过滤。',
      initial: f.boards,
    );
    if (r != null) await s.setThreadScopeFilter(scope, f.copyWith(boards: r));
  }

  Future<void> _editKeywords(
    BuildContext context,
    SettingsProvider s,
    String scope,
    String scopeTitle,
    ThreadScopeFilter f,
  ) async {
    final r = await _showScopeListDialog(
      context: context,
      title: '$scopeTitle · 标题关键词',
      description: '每行一条关键词或正则（| 表示或，包含匹配；非法正则按子串匹配）。',
      initial: f.keywords,
    );
    if (r != null) await s.setThreadScopeFilter(scope, f.copyWith(keywords: r));
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String sub,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: cs.outline),
          ],
        ),
      ),
    );
  }
}

/// 列表编辑弹窗（复用 content_filter_settings 的行为语义：换行拆分）
Future<List<String>?> _showScopeListDialog({
  required BuildContext context,
  required String title,
  String? description,
  required List<String> initial,
}) {
  final controller = TextEditingController(text: initial.join('\n'));
  return showDialog<List<String>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (description != null) Text(description),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            maxLines: 8,
            minLines: 4,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '每行一个，支持空行',
              isDense: true,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, null),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            final lines = controller.text
                .split('\n')
                .map((l) => l.trim())
                .where((l) => l.isNotEmpty)
                .toList();
            Navigator.pop(ctx, lines);
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}