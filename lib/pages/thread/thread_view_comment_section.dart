import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mtbbs/auth/providers/auth_provider.dart';
import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/models/thread_detail.dart';
import 'package:mtbbs/widgets/thread/thread_post_card.dart';

/// 评论区粘性头部委托
class CommentHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  CommentHeaderDelegate({required this.child});

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => child;

  @override
  double get minExtent => 44;

  @override
  double get maxExtent => 44;

  @override
  bool shouldRebuild(CommentHeaderDelegate oldDelegate) => true;
}

/// 评论区组件
///
/// 展示评论列表 + 分页头部（评论区标题 + 上下页按钮）。
/// 不管理任何状态，纯展示 + 回调。
class CommentSection extends StatelessWidget {
  final List<PostItem> posts;
  final Map<String, GlobalKey> postKeys;
  final int currentPage;
  final int totalPages;
  final bool pageLoading;
  final String tid;

  /// 楼主（主题作者）uid，用于评论卡片显示"楼主"标志
  final String opUid;

  // 回调
  final void Function(PostItem post)? onReply;
  final void Function(PostItem post)? onRecommend;
  final void Function(PostCardAction action, PostItem post)? onPopupAction;

  /// 页面级"全局禁用样式"开关（顶栏 toggle），开启时禁用所有样式
  final bool globalDisableStyle;

  /// 只读模式（缓存快照页）：隐藏互动入口
  final bool readOnly;

  /// 当前是否处于「只看楼主」筛选状态。
  ///
  /// 仅用于空态文案：筛选后本页可能一个楼层都不剩，但后面几页也许还有
  /// 楼主的回复，此时说「暂无评论」会误导。
  final bool onlyOpAuthor;

  const CommentSection({
    super.key,
    required this.posts,
    required this.postKeys,
    required this.currentPage,
    required this.totalPages,
    required this.pageLoading,
    required this.tid,
    this.opUid = '',
    this.onReply,
    this.onRecommend,
    this.onPopupAction,
    this.globalDisableStyle = false,
    this.readOnly = false,
    this.onlyOpAuthor = false,
  });

  @override
  Widget build(BuildContext context) {
    if (posts.isEmpty && pageLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (posts.isEmpty) return _buildEmpty(context);

    final isLoggedIn = context.select<AuthProvider, bool>((a) => a.isLoggedIn);
    final currentUid = context.select<AuthProvider, String>((a) => a.uid);
    final disabledTags = context.select<SettingsProvider, Set<String>>(
      (s) => s.disabledBbcodeTags,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...posts.map(
          (post) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ThreadPostCard(
              key: postKeys.putIfAbsent(post.pid, () => GlobalKey()),
              post: post,
              index: currentPage,
              tid: tid,
              isLiked: false,
              isLoggedIn: isLoggedIn,
              currentUid: currentUid,
              opUid: opUid,
              globalDisabledTags: disabledTags,
              globalDisableStyle: globalDisableStyle,
              readOnly: readOnly,
              onReply: () => onReply?.call(post),
              onRecommend: () => onRecommend?.call(post),
              onPopupAction: (action) => onPopupAction?.call(action, post),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              onlyOpAuthor ? Icons.person_search_outlined : Icons.forum_outlined,
              size: 40,
              color: cs.outlineVariant,
            ),
            const SizedBox(height: 8),
            Text(
              onlyOpAuthor ? '本页没有楼主的回复' : '暂无评论',
              style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
            ),
            if (onlyOpAuthor) ...[
              const SizedBox(height: 4),
              Text(
                '可以翻到下一页看看',
                style: TextStyle(fontSize: 12, color: cs.outline),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 评论区头部（标题 + 分页控件 + 刷新）
  static Widget buildHeader({
    required BuildContext context,
    required int currentPage,
    required int totalPages,
    required bool pageLoading,
    required VoidCallback? onPrev,
    required VoidCallback? onNext,
    required VoidCallback? onPageTap,
    required VoidCallback? onRefresh,
    int? windowEnd,
    VoidCallback? onTitleTap,
    /// 「只看楼主」当前是否开启；null = 不显示该按钮（如只读缓存页）
    bool? onlyOpAuthor,
    VoidCallback? onToggleOnlyOpAuthor,
  }) {
    final cs = Theme.of(context).colorScheme;
    // 固化「只看楼主」胶囊的显示条件与开关态。
    // 命名参数是 bool?，直接用可能拿不到类型提升，这里先收敛成非空值。
    final showOnlyOpChip = onlyOpAuthor != null && onToggleOnlyOpAuthor != null;
    final onlyOpOn = onlyOpAuthor ?? false;
    // 扩窗模式：页码显示区间（如 1-3 / 20），未扩窗时 windowEnd == currentPage 退化单页
    final pageLabel = (windowEnd != null && windowEnd > currentPage)
        ? '$currentPage-$windowEnd / $totalPages'
        : '$currentPage / $totalPages';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: cs.surface,
      child: Row(
        children: [
          // 标题与筛选胶囊作为一个整体占用剩余宽度：标题靠左，胶囊紧随其后，
          // 多余空间由这层 Expanded 吸收（等价于原来的 Spacer）。
          // 这样胶囊能用上「标题之后、右侧控件之前」的全部空间，窄屏也不会溢出。
          Expanded(
            child: Row(
              children: [
                Icon(
                  Icons.forum_outlined,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onTitleTap,
                  behavior: HitTestBehavior.opaque,
                  child: Text(
                    '评论区',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                      // 下划线表示可点击（点击后输入楼层并跳转）
                      decoration: onTitleTap == null
                          ? null
                          : TextDecoration.underline,
                    ),
                  ),
                ),
                // 「只看楼主」：筛选型操作，用紧凑胶囊而非 Switch。
                //
                // 评论区头部横向已排满（刷新 / 上一页 / 页码 / 下一页），既不能加
                // 行高也不能占太宽，所以做成 24 高的 chip 紧贴标题右侧：开启时用
                // 主题色填充 + 实心图标 + 加粗表示「当前处于筛选状态」，关闭时只有
                // 描边，不抢视线。
                //
                // 文案固定「只看楼主」不加后缀：开启态若多两个字，320dp 窄屏下
                // 整行总宽会超过可用宽度，直接 RenderFlex overflow。
                // 外层 Flexible 是兜底——极窄屏或大字体时文字省略，而不是报错。
                if (showOnlyOpChip) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: GestureDetector(
                      onTap: onToggleOnlyOpAuthor,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 24,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: onlyOpOn
                              ? cs.primary.withValues(alpha: 0.12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: onlyOpOn ? cs.primary : cs.outlineVariant,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              onlyOpOn
                                  ? Icons.person
                                  : Icons.person_outline_rounded,
                              size: 13,
                              color: onlyOpOn
                                  ? cs.primary
                                  : cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                '只看楼主',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.1,
                                  fontWeight: onlyOpOn
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: onlyOpOn
                                      ? cs.primary
                                      : cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: onRefresh,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            tooltip: '刷新当前页',
          ),
          const SizedBox(width: 2),
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
            onPressed: onPrev,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            tooltip: '上一页',
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onPageTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
              ),
              child: pageLoading
                  ? SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cs.onSurfaceVariant,
                      ),
                    )
                  : Text(
                      pageLabel,
                      style: TextStyle(fontSize: 12, color: cs.onSurface),
                    ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed: onNext,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            tooltip: '下一页',
          ),
        ],
      ),
    );
  }
}
