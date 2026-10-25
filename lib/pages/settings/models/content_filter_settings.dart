import 'package:flutter/material.dart';
import 'package:mtbbs/pages/settings/models/settings_model.dart';
import 'package:mtbbs/pages/settings/thread_filter_scope_settings.dart';
import 'package:mtbbs/core/utils/content_filter.dart';

/// 内容过滤组设置项（功能①②）
///
/// - 板块过滤：黑名单优先（默认），可切白名单。名单每行一个板块名，
///   与 `ThreadItem.boardName` 严格相等匹配（见 core/utils/content_filter.dart）；
/// - 帖子关键词过滤：命中即隐藏该主题卡片（标题子串匹配，大小写不敏感）；
/// - 评论屏蔽：对齐 mtlite 语义——每行一条屏蔽词或正则（合法正则按正则
///   匹配、非法退化子串），正文剥引用后超 10 字不屏蔽，纯 ASCII 短评
///   直接屏蔽，楼主帖与「回复别人」的楼层豁免；首次运行预填内置词表。
List<SettingsModel> contentFilterSettings() => [
  SwitchSetting(
    title: '评论屏蔽',
    subtitle: '命中屏蔽词即隐藏整层楼（楼主帖与回复别人的楼层豁免；超 10 字或含正则都不误伤）。关闭则立即失效',
    icon: Icons.visibility_off_outlined,
    value: (s) => s.commentBlockEnabled,
    onChanged: (ctx, s, v) => s.setCommentBlockEnabled(v),
  ),
  NormalSetting(
    title: '评论屏蔽词',
    icon: Icons.comments_disabled_outlined,
    subtitleBuilder: (s) => s.commentFilterKeywords.isEmpty
        ? '未设置（不过滤）'
        : '命中即隐藏整楼：${s.commentFilterKeywords.join('、')}',
    onTap: (ctx, s) async {
      final r = await _showListEditDialog(
        context: ctx,
        title: '评论屏蔽词',
        description: '每行一条屏蔽词或正则（| 表示或，包含匹配；非法正则按子串匹配）。内置词表已预填，不需要的行可直接删。',
        initial: s.commentFilterKeywords,
      );
      if (r != null) await s.setCommentFilterKeywords(r);
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
      return active == 0
          ? '未启用（各列表点独立配置）'
          : '$active 个列表点已启用屏蔽';
    },
    onTap: (ctx, s) {
      Navigator.push(
        ctx,
        MaterialPageRoute(
          builder: (_) => ThreadFilterScopeSettingsPage(),
        ),
      );
    },
  ),
];

/// 四个帖子列表点（与 provider 侧 `_kThreadScopes` 一致）
const List<String> _kThreadScopes = [
  kThreadScopeCommunity,
  kThreadScopeGuide,
  kThreadScopeSearch,
  kThreadScopeUser,
];

/// 列表编辑弹窗：每行一个条目，确定返回解析后的列表，取消返回 null
Future<List<String>?> _showListEditDialog({
  required BuildContext context,
  required String title,
  String? description,
  required List<String> initial,
}) {
  final controller = TextEditingController(
    text: initial.join('\n'),
  );
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
            // 只按换行拆分：屏蔽词支持正则，`, ; ， ； 、` 是正则合法字符
            // （如 `{2,3}`），按逗号拆会把正则拆坏（mtlite 同款踩坑）
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