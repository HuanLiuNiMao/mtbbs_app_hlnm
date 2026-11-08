import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mtbbs/controllers/thread_list_controller.dart';
import 'package:mtbbs/widgets/thread/thread_grid.dart';
import 'package:mtbbs/widgets/common/page_actions.dart';
import 'package:mtbbs/services/api_service.dart';
import 'package:mtbbs/api/home/mythread/export.dart' as my_thread_api;
import 'package:mtbbs/api/forum/viewthread/detail/export.dart' as detail_api;
import 'package:mtbbs/models/thread_detail.dart';
import 'package:mtbbs/models/thread_item.dart';
import 'package:mtbbs/providers/history_provider.dart';
import 'package:mtbbs/auth/providers/auth_provider.dart';
import 'package:mtbbs/models/browse_record.dart';
import 'package:mtbbs/core/app/emoji_loader.dart';
import 'package:mtbbs/core/app/site_store.dart';
import 'package:mtbbs/core/utils/content_filter.dart';
import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/pages/settings/content_filter_quick_sheet.dart';

/// 我的帖子/回复页面
class MyThreadPage extends StatefulWidget {
  /// 类型：null 或 '' 表示发帖，'reply' 表示回复
  final String? type;

  /// 目标用户 UID，为空表示当前登录用户
  final String? uid;

  const MyThreadPage({super.key, this.type, this.uid});

  @override
  State<MyThreadPage> createState() => _MyThreadPageState();
}

/// 行内展开的回复：**存原始楼层**，渲染时才按当前屏蔽配置过滤。
///
/// 若在拉取时就过滤（早期实现），用户在右上角面板里关掉屏蔽后必须重新展开一次
/// 才会看到被隐藏的楼层；存原文 + 渲染期过滤才能让开关即时生效。
/// 帖子列表侧的 `itemFilter` 也是同一套「本地投影」思路（见 docs/30）。
class _ExpandedReply {
  const _ExpandedReply({
    required this.posts,
    required this.boardName,
    required this.isHiddenThread,
  });

  /// 已做「楼主帖去重」的原始楼层（authorid 筛选会把楼主帖放在首位）
  final List<PostItem> posts;

  /// 主题板块名（详情解析从面包屑取；取不到为空串）
  final String boardName;

  /// 主题是否隐藏贴（`[appdata] locked` 或 `[hide]` 块）
  final bool isHiddenThread;
}

class _MyThreadPageState extends State<MyThreadPage> {
  late final ThreadListController _controller;

  /// 行内展开的回复：threadId → 原始楼层
  final Map<int, _ExpandedReply> _expandedReplies = {};
  final Set<int> _loadingReplies = {};
  final Map<int, String> _errorReplies = {};

  String get _title {
    if (widget.type == 'reply') return '最近回复';
    if (widget.uid != null && widget.uid!.isNotEmpty) return 'Ta的帖子';
    return '我的帖子';
  }

  /// 只有回帖列表会展开楼层，也只有那里用得到评论屏蔽
  bool get _isReplyList => widget.type == 'reply';

  @override
  void initState() {
    super.initState();
    _controller = ThreadListController(
      fetchFn: ({required int page}) => my_thread_api.getMyThreads(
        ApiService().dio,
        page: page,
        uid: widget.uid,
        type: widget.type,
      ),
    );
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (_controller.state == LoadState.loaded) {
      _recordHistory();
    }
  }

  void _recordHistory() {
    final recordType = widget.type == 'reply' ? 'reply' : 'mythread';
    final uid = widget.uid ?? context.read<AuthProvider>().uid;
    if (uid.isEmpty) return;
    final recordId = '${recordType}_$uid';
    final queryParams = <String, String>{};
    if (widget.type != null) queryParams['type'] = widget.type!;
    if (widget.uid != null) queryParams['uid'] = widget.uid!;
    final queryString = queryParams.isEmpty
        ? ''
        : '?${Uri(queryParameters: queryParams).query}';
    if (!context.mounted) return;
    context.read<HistoryProvider>().addRecord(
      BrowseRecord(
        id: '${SiteStore.instance.host}:$recordId',
        host: SiteStore.instance.host,
        type: recordType,
        routePath: '/my-threads$queryString',
        timestamp: DateTime.now(),
        info: {'uid': uid, 'page': _controller.page, 'type': widget.type ?? ''},
      ),
    );
  }

  /// 把原始楼层按**当前**屏蔽配置投影成可见列表。
  ///
  /// 每次 build 现算，所以面板里改完开关返回列表时，已展开的楼层立刻跟着变。
  Map<int, List<PostItem>> _visibleReplies(CommentFilterConfig f) {
    if (!f.enabled || f.isNoop) {
      return {for (final e in _expandedReplies.entries) e.key: e.value.posts};
    }
    return {
      for (final e in _expandedReplies.entries)
        e.key: filterPostItems(
          e.value.posts,
          f,
          boardName: e.value.boardName,
          isHiddenThread: e.value.isHiddenThread,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final uid = widget.uid ?? context.read<AuthProvider>().uid;
    // 必须 watch：右上角面板里改屏蔽开关后要立刻重算列表投影与楼层过滤，
    // 用 read 不会重建，旧结果留在屏幕上（表现为「开关没生效」，见 docs/30）。
    final settings = context.watch<SettingsProvider>();
    final scopeCfg = settings.threadScopeFilter(kThreadScopeUser);
    final commentCfg = settings.commentFilter;
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
            // 图标只反映「本页真正会隐藏东西」的那几层：帖子列表屏蔽永远相关，
            // 评论屏蔽只有回帖列表（会展开楼层）才算数，避免「帖子」页显示成开启态
            icon: Icon(
              scopeCfg.enabled || (_isReplyList && commentCfg.enabled)
                  ? Icons.filter_alt
                  : Icons.filter_alt_off,
              size: 20,
            ),
            tooltip: '屏蔽',
            onPressed: () => showContentFilterQuickSheet(
              context,
              scope: kThreadScopeUser,
              scopeTitle: threadScopeTitle(kThreadScopeUser),
              showCommentFilter: _isReplyList,
            ),
          ),
          PageActions(
            url:
                '${SiteStore.instance.baseUrl}/home.php?mod=space&do=thread'
                '${(widget.uid ?? '').isEmpty ? '' : '&uid=${widget.uid}'}'
                '${(widget.type ?? '').isEmpty ? '' : '&type=${widget.type}'}',
            onRefresh: () => _controller.refresh(),
            copyLabel: '复制帖子列表链接',
          ),
        ],
      ),
      body: ThreadGrid(
        controller: _controller,
        visible: true,
        // 功能①：本列表点的板块 + 标题关键词过滤（本地投影，各列表点独立配置）
        itemFilter: (items) => filterThreadItemsForScope(items, scopeCfg),
        // 屏蔽补页：该列表点启用屏蔽时，整页被屏蔽空自动向后扩窗拼接
        autoExtendOnDeficit: scopeCfg.enabled && !scopeCfg.isNoop,
        expandedReplies: _visibleReplies(commentCfg),
        loadingReplies: _loadingReplies,
        errorReplies: _errorReplies,
        onViewReplies: _isReplyList
            ? (item) => _toggleReplies(item, uid)
            : null,
      ),
    );
  }

  /// 展开 / 收起某条帖子的回复楼层
  void _toggleReplies(ThreadItem item, String uid) {
    final tid = item.threadId;
    if (tid == null || tid <= 0) return;
    // 已有展开或报错 → 收起
    if (_expandedReplies.containsKey(tid) || _errorReplies.containsKey(tid)) {
      setState(() {
        _expandedReplies.remove(tid);
        _errorReplies.remove(tid);
      });
      return;
    }
    // 正在加载 → 忽略
    if (_loadingReplies.contains(tid)) return;
    setState(() => _loadingReplies.add(tid));
    // 先确保表情已加载，回复内容里的表情才能还原
    EmojiService()
        .load()
        .then(
          (_) => detail_api.getThreadDetail(
            ApiService().dio,
            tid: tid.toString(),
            page: 1,
            authorid: uid,
          ),
        )
        .then((result) {
          if (!mounted) return;
          if (result['success'] != true) {
            final msg = result['message']?.toString() ?? '加载失败';
            setState(() {
              _loadingReplies.remove(tid);
              _errorReplies[tid] = msg;
            });
            return;
          }
          final data = ThreadViewData.fromMap(result, tid.toString());
          // 去重：如果第一条评论的 uid 与帖子卡片作者相同，
          // 说明是帖子本身（authorid 筛选导致第一条是楼主帖）
          var posts = data.posts;
          if (posts.isNotEmpty &&
              item.uid != null &&
              posts.first.uid == item.uid.toString()) {
            posts = posts.sublist(1);
          }
          // 去重必须在存原文之前完成：authorid 筛选下 isOp 全为 false，
          // 评论屏蔽的「楼主豁免」在这里不生效，首条只能靠 uid 对比去掉。
          // 屏蔽本身延后到渲染期（见 _visibleReplies），开关才能即时生效。
          final reply = _ExpandedReply(
            posts: posts,
            boardName: data.boardName,
            isHiddenThread: isHiddenThreadBbcode(data.mainPost?.bbcode ?? ''),
          );
          if (!mounted) return;
          setState(() {
            _loadingReplies.remove(tid);
            _errorReplies.remove(tid);
            _expandedReplies[tid] = reply;
          });
        })
        .catchError((e) {
          if (!mounted) return;
          setState(() {
            _loadingReplies.remove(tid);
            _errorReplies[tid] = e.toString();
          });
        });
  }
}
