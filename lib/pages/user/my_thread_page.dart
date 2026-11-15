import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mtbbs/controllers/thread_list_controller.dart';
import 'package:mtbbs/widgets/thread/thread_grid.dart';
import 'package:mtbbs/widgets/common/page_actions.dart';
import 'package:mtbbs/widgets/common/read_later_page_action.dart';
import 'package:mtbbs/services/api_service.dart';
import 'package:mtbbs/api/home/mythread/export.dart' as my_thread_api;
import 'package:mtbbs/api/forum/viewthread/detail/export.dart' as detail_api;
import 'package:mtbbs/models/thread_detail.dart';
import 'package:mtbbs/providers/history_provider.dart';
import 'package:mtbbs/providers/read_later_provider.dart';
import 'package:mtbbs/auth/providers/auth_provider.dart';
import 'package:mtbbs/models/browse_record.dart';
import 'package:mtbbs/core/app/emoji_loader.dart';
import 'package:mtbbs/core/app/site_store.dart';

/// 我的帖子/回复页面
class MyThreadPage extends StatefulWidget {
  /// 类型：null 或 '' 表示发帖，'reply' 表示回复
  final String? type;

  /// 目标用户 UID，为空表示当前登录用户
  final String? uid;

  /// 初始页码（从「稍后再看」等入口带 `page=` 恢复阅读进度）
  final int initialPage;

  const MyThreadPage({
    super.key,
    this.type,
    this.uid,
    this.initialPage = 1,
  });

  @override
  State<MyThreadPage> createState() => _MyThreadPageState();
}

class _MyThreadPageState extends State<MyThreadPage> {
  late final ThreadListController _controller;

  /// 行内展开的回复：threadId → 回复列表
  final Map<int, List<PostItem>> _expandedReplies = {};
  final Set<int> _loadingReplies = {};
  final Map<int, String> _errorReplies = {};

  String get _title {
    if (widget.type == 'reply') return '最近回复';
    if (widget.uid != null && widget.uid!.isNotEmpty) return 'Ta的帖子';
    return '我的帖子';
  }

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
    // 恢复页码：直接进目标页，避免先闪烁一次第 1 页
    if (widget.initialPage > 1) {
      _controller.goToPage(widget.initialPage);
    }
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
    // 同步「稍后再看」的阅读进度（条目不存在时静默忽略）
    context
        .read<ReadLaterProvider>()
        .markRead(readLaterPageId('/my-threads$queryString'), page: _controller.page);
  }

  @override
  Widget build(BuildContext context) {
    final uid = widget.uid ?? context.read<AuthProvider>().uid;
    final queryParams = <String, String>{};
    if (widget.type != null) queryParams['type'] = widget.type!;
    if (widget.uid != null) queryParams['uid'] = widget.uid!;
    final queryString = queryParams.isEmpty
        ? ''
        : '?${Uri(queryParameters: queryParams).query}';
    final routePath = '/my-threads$queryString';
    final url =
        '${SiteStore.instance.baseUrl}/home.php?mod=space&do=thread'
        '${(widget.uid ?? '').isEmpty ? '' : '&uid=${widget.uid}'}'
        '${(widget.type ?? '').isEmpty ? '' : '&type=${widget.type}'}';
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          PageActions(
            url: url,
            onRefresh: () => _controller.refresh(),
            copyLabel: '复制帖子列表链接',
            extraItems: [
              readLaterMenuItem(
                inReadLater: isPageInReadLater(context, routePath),
              ),
            ],
            onExtraSelected: (action) async {
              if (action != 'read_later') return;
              await togglePageReadLater(
                context,
                routePath: routePath,
                title: _title,
                url: url,
                subtitle: widget.type == 'reply' ? '最近回复' : '我的帖子',
                page: _controller.page,
              );
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: ThreadGrid(
        controller: _controller,
        visible: true,
        expandedReplies: _expandedReplies,
        loadingReplies: _loadingReplies,
        errorReplies: _errorReplies,
        onViewReplies: widget.type == 'reply'
            ? (item) {
                final tid = item.threadId;
                if (tid == null || tid <= 0) return;
                // 已有展开或报错 → 收起
                if (_expandedReplies.containsKey(tid) ||
                    _errorReplies.containsKey(tid)) {
                  setState(() {
                    _expandedReplies.remove(tid);
                    _errorReplies.remove(tid);
                  });
                  return;
                }
                // 正在加载 → 忽略
                if (_loadingReplies.contains(tid)) return;
                // 开始加载
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
                      final data = ThreadViewData.fromMap(
                        result,
                        tid.toString(),
                      );
                      // 去重：如果第一条评论的 uid 与帖子卡片作者相同，
                      // 说明是帖子本身（authorid 筛选导致第一条是楼主帖）
                      var posts = data.posts;
                      if (posts.isNotEmpty &&
                          item.uid != null &&
                          posts.first.uid == item.uid.toString()) {
                        posts = posts.sublist(1);
                      }
                      setState(() {
                        _loadingReplies.remove(tid);
                        _errorReplies.remove(tid);
                        _expandedReplies[tid] = posts;
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
            : null,
      ),
    );
  }
}
