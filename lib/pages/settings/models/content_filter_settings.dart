import 'package:flutter/material.dart';
import 'package:mtbbs/pages/settings/models/settings_model.dart';
import 'package:mtbbs/pages/settings/comment_filter_scope_settings.dart';
import 'package:mtbbs/pages/settings/thread_filter_scope_settings.dart';
import 'package:mtbbs/core/utils/content_filter.dart';

/// 内容过滤组设置项（功能①②）
///
/// - 板块过滤：黑名单优先（默认），可切白名单。名单每行一个板块名，
///   与 `ThreadItem.boardName` 严格相等匹配（见 core/utils/content_filter.dart）；
/// - 帖子关键词过滤：命中即隐藏该主题卡片（标题子串匹配，大小写不敏感）；
/// - 评论屏蔽：二级页配置（与「帖子列表屏蔽」同款范式），含开关、屏蔽词
///   与两种触发方式（仅隐藏贴 / 按板块）。**没有内置默认词表**：屏蔽词
///   完全由用户维护，为空即不屏蔽任何评论。
List<SettingsModel> contentFilterSettings() => [
  NormalSetting(
    title: '评论屏蔽',
    icon: Icons.visibility_off_outlined,
    subtitleBuilder: (s) => _commentFilterSummary(s.commentFilter),
    onTap: (ctx, s) {
      Navigator.push(
        ctx,
        MaterialPageRoute(builder: (_) => const CommentFilterSettingsPage()),
      );
    },
  ),
  NormalSetting(
    title: '帖子列表屏蔽',
    icon: Icons.filter_alt_outlined,
    subtitleBuilder: (s) {
      final active = _kThreadScopes
          .map((sc) => s.threadScopeFilter(sc))
          .where((f) => f.enabled && !f.isNoop)
          .length;
      return active == 0 ? '未启用（各列表点独立配置）' : '$active 个列表点已启用屏蔽';
    },
    onTap: (ctx, s) {
      Navigator.push(
        ctx,
        MaterialPageRoute(builder: (_) => ThreadFilterScopeSettingsPage()),
      );
    },
  ),
];

/// 评论屏蔽的副标题：一眼看出「开没开、几条词、什么触发范围」
String _commentFilterSummary(CommentFilterConfig f) {
  if (!f.enabled) return '已关闭';
  if (f.keywords.isEmpty) return '已开启 · 未设置屏蔽词（不过滤）';
  final trigger = f.isGlobalTrigger
      ? '全部主题'
      : [
          if (f.onlyHiddenThread) '仅隐藏贴',
          if (f.boards.isNotEmpty) f.modeBlock ? '板块黑名单' : '板块白名单',
        ].join(' / ');
  return '已开启 · ${f.keywords.length} 条屏蔽词 · $trigger';
}

/// 四个帖子列表点（与 provider 侧 `_kThreadScopes` 一致）
const List<String> _kThreadScopes = [
  kThreadScopeCommunity,
  kThreadScopeGuide,
  kThreadScopeSearch,
  kThreadScopeUser,
];
