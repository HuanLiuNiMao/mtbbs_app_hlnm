import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mtbbs/core/utils/content_filter.dart';
import 'package:mtbbs/pages/settings/comment_filter_scope_settings.dart';
import 'package:mtbbs/pages/settings/thread_filter_scope_settings.dart';
import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/widgets/common/app_sheet.dart';

/// 内容过滤快捷面板：在列表页右上角直接开关屏蔽，并直达二级设置页。
///
/// 为什么不做成「点图标就直接切换开关」：列表点屏蔽与评论屏蔽是两套独立配置
/// （前者按列表点各一份，后者全局一份），一键切换只能动其中一套，用户分不清
/// 当前关掉的是哪一层；面板把「开关」和「去哪改细节」放在同一处，一次点击可达。
///
/// [scope] 是帖子列表点标识（见 `content_filter.dart` 的 `kThreadScope*`），
/// [scopeTitle] 用设置页里的同一份名称，避免两处叫法不一致。
///
/// [showCommentFilter] 为 true 时（回帖列表这类会展开楼层的页面）额外提供评论
/// 屏蔽开关——那里的楼层由 [CommentFilterConfig] 决定，与帖子列表屏蔽无关。
Future<void> showContentFilterQuickSheet(
  BuildContext context, {
  required String scope,
  required String scopeTitle,
  bool showCommentFilter = false,
}) {
  return showAppSheet<void>(
    context: context,
    maxHeight: 420,
    builder: (_) => _ContentFilterQuickSheet(
      scope: scope,
      scopeTitle: scopeTitle,
      showCommentFilter: showCommentFilter,
    ),
  );
}

class _ContentFilterQuickSheet extends StatelessWidget {
  const _ContentFilterQuickSheet({
    required this.scope,
    required this.scopeTitle,
    required this.showCommentFilter,
  });

  final String scope;
  final String scopeTitle;
  final bool showCommentFilter;

  @override
  Widget build(BuildContext context) {
    // 必须 watch 而不是 read：面板里拨开关后，同一面板的副标题与设置页入口
    // 都要立刻反映新状态（read 不会重建，见 docs/30「配置必须 watch」）。
    final s = context.watch<SettingsProvider>();
    final f = s.threadScopeFilter(scope);
    final c = s.commentFilter;
    final cs = Theme.of(context).colorScheme;
    return AppSheetScaffold(
      title: '屏蔽',
      child: ListView(
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          _sectionHeader(context, '帖子列表屏蔽', scopeTitle),
          SwitchListTile(
            title: const Text('屏蔽帖子', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              _threadFilterHint(f),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            value: f.enabled,
            onChanged: (v) =>
                s.setThreadScopeFilter(scope, f.copyWith(enabled: v)),
          ),
          ListTile(
            leading: Icon(
              Icons.filter_alt_outlined,
              size: 18,
              color: cs.onSurfaceVariant,
            ),
            title: const Text('帖子列表屏蔽设置', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              '板块名单 · 标题关键词 · 名单模式',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            trailing: Icon(Icons.chevron_right, size: 18, color: cs.outline),
            visualDensity: VisualDensity.compact,
            onTap: () =>
                _openSettings(context, const ThreadFilterScopeSettingsPage()),
          ),
          if (showCommentFilter) ...[
            const Divider(height: 1),
            _sectionHeader(context, '评论屏蔽', '本页展开的回复楼层'),
            SwitchListTile(
              title: const Text('屏蔽回复楼层', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                _commentFilterHint(c),
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
              value: c.enabled,
              onChanged: (v) => s.setCommentFilter(c.copyWith(enabled: v)),
            ),
            ListTile(
              leading: Icon(
                Icons.visibility_off_outlined,
                size: 18,
                color: cs.onSurfaceVariant,
              ),
              title: const Text('评论屏蔽设置', style: TextStyle(fontSize: 13)),
              subtitle: Text(
                '屏蔽词 · 触发方式（仅隐藏贴 / 按板块）',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
              trailing: Icon(Icons.chevron_right, size: 18, color: cs.outline),
              visualDensity: VisualDensity.compact,
              onTap: () =>
                  _openSettings(context, const CommentFilterSettingsPage()),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              '屏蔽只在本机隐藏内容，不改动数据源；列表点与评论的判定链见「设置 → 内容过滤」。',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// 先关面板再进设置：面板是挂在当前 Navigator 上的 route，直接 push 会把它
  /// 留在新页面下面，返回时又弹出来（与 `forum_management.dart` 同一套处理）。
  void _openSettings(BuildContext context, Widget page) {
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(MaterialPageRoute(builder: (_) => page));
  }

  Widget _sectionHeader(BuildContext context, String title, String hint) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// 该列表点的屏蔽概况（开关态 + 实际会不会隐藏内容）
String _threadFilterHint(ThreadScopeFilter f) {
  if (!f.enabled) return '已关闭 · 本列表显示全部帖子';
  if (f.isNoop) return '已开启 · 未设置板块或关键词，暂不隐藏任何帖子';
  final parts = <String>[
    if (f.boards.isNotEmpty)
      '${f.modeBlock ? '板块黑名单' : '板块白名单'} ${f.boards.length} 项',
    if (f.keywords.isNotEmpty) '标题关键词 ${f.keywords.length} 条',
  ];
  return '已开启 · ${parts.join(' · ')}';
}

/// 评论屏蔽概况（开关态 + 屏蔽词条数 + 触发范围）
String _commentFilterHint(CommentFilterConfig f) {
  if (!f.enabled) return '已关闭 · 回复楼层全部显示';
  if (f.keywords.isEmpty) return '已开启 · 未设置屏蔽词，暂不隐藏任何回复';
  final trigger = f.isGlobalTrigger
      ? '全部主题'
      : [
          if (f.onlyHiddenThread) '仅隐藏贴',
          if (f.boards.isNotEmpty) f.modeBlock ? '板块黑名单' : '板块白名单',
        ].join(' / ');
  return '已开启 · ${f.keywords.length} 条屏蔽词 · $trigger';
}
