import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mtbbs/api/home/mypost/export.dart' as mypost_api;
import 'package:mtbbs/config/notice_config.dart';
import 'package:mtbbs/core/utils/content_filter.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/core/utils/url_router.dart';
import 'package:mtbbs/core/utils/url_util.dart';
import 'package:mtbbs/models/post_preview.dart';
import 'package:mtbbs/pages/message/notice_segments.dart';
import 'package:mtbbs/pages/message/notice_subtype_state.dart';
import 'package:mtbbs/pages/message/paged_list_state.dart';
import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/services/api_service.dart';
import 'package:mtbbs/widgets/bbcode/post_html_widget.dart';
import 'package:mtbbs/widgets/common/user_avatar.dart';
import 'package:mtbbs/widgets/layout/state_views.dart';
import 'package:mtbbs/widgets/thread/post_source_sheet.dart';
import 'package:provider/provider.dart';

/// 「我的帖子」分组配置（唯一数据源：lib/config/notice_config.dart）
final NoticeGroup _mypostGroup = noticeGroupOf('mypost')!;

/// 我的帖子 Tab
class MypostTab extends StatefulWidget {
  const MypostTab({super.key});

  @override
  State<MypostTab> createState() => _MypostTabState();
}

class _MypostTabState extends State<MypostTab>
    with PagedListStateMixin<MypostTab>, NoticeSubtypeStateMixin<MypostTab> {
  @override
  String get noticeView => 'mypost';

  @override
  List<NoticeType> get configuredTypes => _mypostGroup.types;

  final Map<int, PostPreviewData?> _previews = {};
  final Set<int> _previewLoading = {};

  /// 本代（一次 load / 刷新 / 切子类型）已自动补页的次数。
  ///
  /// 整页条目都被屏蔽词命中时，列表没有任何可滚动的行，触底加载更多不会被
  /// 触发 → 用户会卡在一个空白页上，后面几页的正常提醒永远看不到。这里按
  /// 帖子列表屏蔽的同款思路自动向后补页，但**限次**：补页是兜底，不是把整帖
  /// 提醒全拉一遍。
  int _autoExtendCount = 0;
  static const int _autoExtendMax = 3;

  /// 已排了一次补页、还没执行完 → 避免 build 连跑几次时重复排
  bool _autoExtendScheduled = false;

  @override
  Future<Map<String, dynamic>> fetchPage(int page) =>
      mypost_api.getMypostList(ApiService().dio, page: page, type: noticeType);

  @override
  void onPageFetched(Map<String, dynamic> result) =>
      applyNoticeNav(result['nav']);

  @override
  void onItemsReplaced() {
    _previews.clear();
    _previewLoading.clear();
    _autoExtendCount = 0;
    // 自动触发预览请求
    for (int i = 0; i < items.length; i++) {
      _tryFetchPreview(i);
    }
  }

  @override
  void onItemsAppended(int start) {
    // 只给新追加的条目拉预览
    for (int i = start; i < items.length; i++) {
      _tryFetchPreview(i);
    }
  }

  @override
  void onSubtypeChanged(String type) {
    _previews.clear();
    _previewLoading.clear();
    _autoExtendCount = 0;
    _autoExtendScheduled = false;
  }

  // ==================== 预览逻辑 ====================

  Future<void> _tryFetchPreview(int index) async {
    if (index >= items.length) return;
    if (_previews.containsKey(index)) return;

    final item = items[index];
    final viewUrl = item['viewUrl'] as String? ?? '';
    final ids = parseViewUrl(viewUrl);
    if (ids == null) return;

    // 先查缓存
    final cached = PostPreviewManager.instance.getCached(ids.tid, ids.pid);
    if (cached != null) {
      if (mounted) setState(() => _previews[index] = cached);
      return;
    }

    setState(() => _previewLoading.add(index));
    final data = await PostPreviewManager.instance.fetch(ids.tid, ids.pid);
    if (!mounted) return;
    setState(() {
      _previews[index] = data;
      _previewLoading.remove(index);
    });
  }

  // ==================== Build ====================

  @override
  Widget build(BuildContext context) {
    // 子类型 chip 常驻：某个子类型为空时也要能切到别的类型（7 个子类型尤其需要）
    //
    // 订阅放在 build 里而不是 _body 里：_body 由 PageView.builder 的
    // itemBuilder 调用，那时已不属于 build 阶段，`context.watch` 会触发
    // provider 的「在 widget 树之外监听」断言。用 watch 是为了让用户改完
    // 屏蔽词回到列表时重新判定一遍（用 read 不会重建，旧结果留在屏幕上，
    // 看起来仍然「过滤没生效」）。
    final settings = context.watch<SettingsProvider>();
    return buildNoticeTab(
      body: () => _body(settings.commentFilter, settings.autoDetectUrls),
      alwaysShowHeader: true,
    );
  }

  Widget _body(CommentFilterConfig cfg, bool autoDetectUrls) {
    // 命中屏蔽词且「命中后保留提示」关闭 → 整条提醒都不渲染（不是只藏正文）。
    //
    // 早期只把回帖正文换成一行提示，卡片本身（头像、用户名、「回复了您的
    // 帖子」、查看/回复按钮）全部留着，用户设了屏蔽词却仍看到消息在列表里，
    // 表现为「屏蔽没生效」。内容既已被主动屏蔽，整条提醒就没有存在意义。
    final hidden = <int>{
      for (var i = 0; i < items.length; i++)
        if (shouldHideMypostEntry(_previews[i]?.bbcode, cfg)) i,
    };
    // 整页都被屏蔽 → 自动补一页（限次），否则用户只能盯着空白页
    _maybeAutoExtend(hidden.length);
    return buildPagedList(
      emptyView: EmptyView(
        icon: Icons.forum_outlined,
        text: items.isNotEmpty && hidden.length == items.length
            ? '命中屏蔽词，本页内容已隐藏'
            : '暂无提醒',
      ),
      itemVisible: (i) => !hidden.contains(i),
      itemBuilder: (_, i) => _buildItem(items[i], i, cfg, autoDetectUrls),
    );
  }

  /// 整页条目都被屏蔽时自动补一页（限次）。
  ///
  /// 判据是「隐藏条数 == 当前条目数」而不是「小于一页基准」：这里的预览是
  /// 逐条异步拉回来的，用基准条数会在预览还没回来时误判成整页被屏蔽，
  /// 白白发起请求。只在 build 里被调用，实际加载放到帧后执行。
  void _maybeAutoExtend(int hiddenCount) {
    if (items.isEmpty || hiddenCount != items.length) return;
    if (_autoExtendScheduled) return;
    if (_autoExtendCount >= _autoExtendMax) return;
    if (!hasMore || isLoading || isLoadingMore) return;
    // 预览还在拉 → 等这一轮回来再判定
    if (_previewLoading.isNotEmpty) return;
    _autoExtendCount++;
    _autoExtendScheduled = true;
    final next = pageNumber + 1;
    AppLogger.i('MYPOST', '全页命中屏蔽词，自动补第 $next 页');
    Future.microtask(() async {
      _autoExtendScheduled = false;
      if (!mounted) return;
      await loadMore();
    });
  }

  // ==================== Item ====================

  Widget _buildItem(
    Map<String, dynamic> item,
    int index,
    CommentFilterConfig commentCfg,
    bool autoDetectUrls,
  ) {
    final cs = Theme.of(context).colorScheme;
    final uid = item['uid'] as String? ?? '';
    final username = item['username'] as String? ?? '';
    final time = item['time'] as String? ?? '';
    final timeTitle = item['timeTitle'] as String? ?? '';
    final segments = item['segments'] as List<dynamic>? ?? [];
    final viewUrl = item['viewUrl'] as String? ?? '';
    final ids = parseViewUrl(viewUrl);
    final isPreviewLoading = _previewLoading.contains(index);
    final preview = _previews[index];
    // 命中屏蔽词时：默认整卡已从列表里移除（见 _body），只有用户打开
    // 「命中后保留提示」才会走到这里 → 渲染一行提示代替正文。
    final blocked = isMypostEntryBlocked(preview?.bbcode, commentCfg);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部：头像 + 用户名 + 时间
            Row(
              children: [
                UserAvatar(uid: uid, radius: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    username,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (time.isNotEmpty)
                  Tooltip(
                    message: timeTitle.isNotEmpty ? timeTitle : time,
                    child: Text(
                      time,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            // 通知消息体（结构化段落，标题可点击）
            if (segments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: buildNoticeSegments(context, segments),
              ),
            const SizedBox(height: 8),
            // 预览区
            if (isPreviewLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            // 命中屏蔽词时正文换成一行提示。
            //
            // 默认配置下这张卡根本不会出现在列表里（见 _body），能走到这里
            // 只可能是用户打开了「设置 → 评论屏蔽 → 命中后保留提示」，此时
            // 「查看 / 回复」按钮行照常渲染，用户仍可点进去看完整上下文。
            if (!blocked && preview != null && preview.bbcode.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: PostHtmlWidget(
                  bbcode: preview.bbcode,
                  disabledTags: const {},
                  autoDetectUrls: autoDetectUrls,
                ),
              )
            else if (blocked && preview != null && preview.bbcode.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.visibility_off_outlined,
                      size: 14,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '回帖内容已屏蔽（命中评论屏蔽词）',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),
            // 操作按钮行
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // 查看按钮
                if (viewUrl.isNotEmpty)
                  _actionBtn(
                    label: '查看',
                    onTap: () {
                      final fullUrl = normalizeUrl(viewUrl);
                      final result = UrlRouter.parse(fullUrl);
                      if (result.appPath != null && !result.isOtherSite) {
                        context.push(result.appPath!);
                      } else {
                        context.push(
                          '/browser?url=${Uri.encodeComponent(fullUrl)}&intercept=false',
                        );
                      }
                    },
                  ),
                const SizedBox(width: 6),
                // 回复按钮
                if (ids != null)
                  _actionBtn(
                    label: '回复',
                    onTap: () => context.push(
                      '/editor?type=reply&tid=${ids.tid}&pid=${ids.pid}',
                    ),
                  ),
                if (preview != null &&
                    preview.bbcode.isNotEmpty &&
                    !blocked) ...[
                  const SizedBox(width: 6),
                  PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    icon: Icon(
                      Icons.more_horiz,
                      size: 16,
                      color: cs.onSurfaceVariant,
                    ),
                    onSelected: (v) {
                      if (v == 'showBbcode') {
                        PostSourceSheet.show(
                          context,
                          username: username,
                          bbcode: preview.bbcode,
                        );
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'showBbcode',
                        child: Text('查看', style: TextStyle(fontSize: 13)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionBtn({required String label, required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}
