import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mtbbs/core/utils/clipboard_helper.dart';
import 'package:mtbbs/core/utils/url_router.dart';
import 'package:mtbbs/models/credits.dart';
import 'package:mtbbs/widgets/common/toast_utils.dart';
import 'package:mtbbs/widgets/common/user_avatar.dart';

/// 致谢名单二级页 — 从关于页「致谢名单」进入。
///
/// 内容全部来自 `assets/config/credits.json`：分组（项目与上游 / 特别鸣谢 /
/// 语言与框架 / 架构与状态 / 网络与解析 / 渲染与媒体 / 平台与工具链），条目
/// 点击即复制对应仓库链接。带 `uid` 的条目（真实论坛用户）额外显示头像。
class CreditsPage extends StatefulWidget {
  const CreditsPage({super.key});

  @override
  State<CreditsPage> createState() => _CreditsPageState();
}

class _CreditsPageState extends State<CreditsPage> {
  /// 只读一次 assets，避免主题切换等 rebuild 重复解析 JSON
  late final Future<List<CreditSection>> _credits = Credits.load();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('致谢名单'), centerTitle: true),
      body: FutureBuilder<List<CreditSection>>(
        future: _credits,
        builder: (context, snapshot) {
          final sections = snapshot.data ?? const <CreditSection>[];
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (sections.isEmpty) {
            return Center(
              child: Text(
                '致谢名单为空',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Text(
                  '本应用站在这些项目之上。点击任意条目可复制其仓库地址。',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
              for (final section in sections) ...[
                _sectionTitle(cs, section.title),
                _card([
                  for (var i = 0; i < section.entries.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 16),
                    _entryTile(cs, section.entries[i]),
                  ],
                ]),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _sectionTitle(ColorScheme cs, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _card(List<Widget> children) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  /// 单个条目：左侧可选头像，中间名称 + 说明，右侧复制图标
  ///
  /// 点击行为分两种：带 `uid` 的特别鸣谢条目（link 是论坛帖子）直接打开链接；
  /// 其余技术栈条目（link 是仓库地址）复制地址，方便粘到浏览器或 issue 里。
  Widget _entryTile(ColorScheme cs, CreditEntry entry) {
    return InkWell(
      onTap: () => entry.hasAvatar ? _openLink(entry) : _copyLink(entry),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (entry.hasAvatar) ...[
              UserAvatar(
                uid: entry.uid,
                nickname: entry.name,
                radius: 18,
                siteHost: entry.siteHost,
                tapAction: AvatarTapAction.none,
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (entry.desc.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      entry.desc,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (entry.link.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      entry.link,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.primary.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              entry.hasAvatar ? Icons.open_in_new : Icons.copy,
              size: 16,
              color: cs.outline,
            ),
          ],
        ),
      ),
    );
  }

  /// 特别鸣谢条目：按 URL 路由打开（站内帖子直接进 App，否则交给浏览器）
  void _openLink(CreditEntry entry) {
    if (entry.link.isEmpty) return;
    final target = UrlRouter.resolveTarget(entry.link);
    if (target != null) context.push(target);
  }

  /// 点击条目：复制该项目的仓库/官网链接
  Future<void> _copyLink(CreditEntry entry) async {
    if (entry.link.isEmpty) return;
    await ClipboardHelper.write(entry.link);
    if (!mounted) return;
    showToast('已复制 ${entry.name} 的地址', duration: const Duration(seconds: 1));
  }
}
