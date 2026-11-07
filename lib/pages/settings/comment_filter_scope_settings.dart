import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mtbbs/core/utils/content_filter.dart';
import 'package:mtbbs/providers/settings_provider.dart';

/// 评论屏蔽 — 二级设置页
///
/// 与「帖子列表屏蔽」（[ThreadFilterScopeSettingsPage]）同一套范式：
/// 顶部总开关 + 若干可点行。区别是这里只有一份配置（不分列表点），
/// 屏蔽词支持两种触发方式：
/// - 「仅隐藏贴触发」（Switch）：只有隐藏贴（回复可见类主题）才应用屏蔽词；
/// - 「按板块触发」（与板块屏蔽前端 UI 一致）：板块黑/白名单 + 名单模式。
///
/// 两种触发方式都不设置时，屏蔽词对所有主题全局生效（与旧行为一致）。
class CommentFilterSettingsPage extends StatelessWidget {
  const CommentFilterSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsProvider>();
    final f = s.commentFilter;
    return Scaffold(
      appBar: AppBar(title: const Text('评论屏蔽'), centerTitle: true),
      body: ListView(
        children: [
          // ==================== 总开关 ====================
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '评论屏蔽',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '命中屏蔽词即隐藏整层楼（楼主帖与「回复别人」的楼层豁免）',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: f.enabled,
                  onChanged: (v) => s.setCommentFilter(f.copyWith(enabled: v)),
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
                  icon: Icons.visibility_off_outlined,
                  label: '屏蔽词',
                  sub: f.keywords.isEmpty
                      ? '未设置（不过滤）'
                      : '${f.keywords.length} 条：${f.keywords.join('、')}',
                  onTap: () => _editKeywords(context, s, f),
                ),
                // 命中后占位提示开关
                //
                // 「消息 → 我的帖子」列表里，命中屏蔽词的回帖原本会画一整行
                // 「回帖内容已屏蔽」的提示，在卡片中视觉上就是一个占满宽度的
                // 大框。内容既然已被主动屏蔽，再占一块面积提醒「这里本来有
                // 东西」纯属噪音，因此默认关闭（直接收起、不留痕迹）。
                // 想要保留这层提示的用户可在此打开。
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '命中后保留提示',
                              style: TextStyle(fontSize: 13),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              f.showBlockedPlaceholder
                                  ? '当前：屏蔽后在「消息 → 我的帖子」留一行浅色提示'
                                  : '当前：屏蔽后直接收起，不占位置（默认）',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: f.showBlockedPlaceholder,
                        onChanged: (v) => s.setCommentFilter(
                          f.copyWith(showBlockedPlaceholder: v),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // ==================== 触发方式 ====================
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              '触发方式',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: Text(
              '不设置任何触发方式时，屏蔽词对所有主题生效；设置后两者为「或」的关系（命中任一即屏蔽）。',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          // 仅隐藏贴触发（开关形式）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('仅隐藏贴触发', style: TextStyle(fontSize: 13)),
                      const SizedBox(height: 2),
                      Text(
                        f.onlyHiddenThread
                            ? '当前：只在隐藏贴（回复可见）里应用屏蔽词'
                            : '当前：不限定隐藏贴',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: f.onlyHiddenThread,
                  onChanged: (v) =>
                      s.setCommentFilter(f.copyWith(onlyHiddenThread: v)),
                ),
              ],
            ),
          ),
          // 分板块触发（UI 与板块屏蔽一致：板块名单 + 名单模式）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              children: [
                _row(
                  context,
                  icon: Icons.block,
                  label: f.modeBlock ? '板块黑名单' : '板块白名单',
                  sub: f.boards.isEmpty
                      ? '未设置（不按板块触发）'
                      : (f.modeBlock ? '黑名单：' : '白名单：') + f.boards.join('、'),
                  onTap: () => _editBoards(context, s, f),
                ),
                _row(
                  context,
                  icon: Icons.flip,
                  label: '名单模式',
                  sub: f.modeBlock
                      ? '当前：黑名单（名单内板块才应用屏蔽词）'
                      : '当前：白名单（名单外板块才应用屏蔽词）',
                  onTap: () =>
                      s.setCommentFilter(f.copyWith(modeBlock: !f.modeBlock)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              f.isGlobalTrigger ? '当前屏蔽词对全部主题生效。' : '当前屏蔽词仅在满足触发条件的主题生效。',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editKeywords(
    BuildContext context,
    SettingsProvider s,
    CommentFilterConfig f,
  ) async {
    final r = await _showScopeListDialog(
      context: context,
      title: '评论屏蔽词',
      description:
          '每行一条屏蔽词或正则（| 表示或，包含匹配；非法正则按子串匹配）。'
          '正文剥引用后超过 10 字的评论不会被屏蔽。',
      initial: f.keywords,
    );
    if (r != null) await s.setCommentFilter(f.copyWith(keywords: r));
  }

  Future<void> _editBoards(
    BuildContext context,
    SettingsProvider s,
    CommentFilterConfig f,
  ) async {
    final r = await _showScopeListDialog(
      context: context,
      title: '板块名单',
      description: '每行一个板块名（须与页面显示的板块名一致），留空表示不按板块触发。',
      initial: f.boards,
    );
    if (r != null) await s.setCommentFilter(f.copyWith(boards: r));
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

/// 列表编辑弹窗（与帖子列表屏蔽同款语义：只按换行拆分）
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
