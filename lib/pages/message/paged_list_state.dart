import 'package:flutter/material.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/widgets/layout/load_more_footer.dart';
import 'package:mtbbs/widgets/layout/page_error_widget.dart';
import 'package:mtbbs/widgets/layout/state_views.dart';

/// 消息类列表 Tab 的公共分页状态：下拉刷新 + 触底加载更多 + 加载/错误/空态。
///
/// 子类只需实现 [fetchPage]，按需覆写 [onPageFetched] / [onItemsReplaced] /
/// [onItemsAppended] / [onSubtypeChanged] 钩子。
///
/// 注意：mixins 之间靠公共成员协作（不跨库访问私有成员），字段命名统一用
/// `isLoading` / `items` 这类清晰名字，子类不要重复声明。
mixin PagedListStateMixin<T extends StatefulWidget> on State<T> {
  final scrollController = ScrollController();
  List<Map<String, dynamic>> items = [];
  bool isLoading = true;
  bool isLoadingMore = false;
  bool hasMore = true;
  String? errorText;
  int pageNumber = 1;
  int totalPages = 1;

  /// 拉取指定页；返回 API 原始结果（须含 `success` / `items` /
  /// `currentPage` / `totalPages`）。
  Future<Map<String, dynamic>> fetchPage(int page);

  /// 成功拿到结果、写入列表前调用（如校正站内导航/子类型）
  void onPageFetched(Map<String, dynamic> result) {}

  /// 列表被整体替换后调用（如清空并重建帖子预览）
  void onItemsReplaced() {}

  /// 追加完成后调用，[start] 为新条目起始下标
  void onItemsAppended(int start) {}

  /// 子类型切换后调用（此时新列表尚未拉取）
  void onSubtypeChanged(String type) {}

  @override
  void initState() {
    super.initState();
    scrollController.addListener(_onScroll);
    load(1);
  }

  @override
  void dispose() {
    scrollController.removeListener(_onScroll);
    scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!scrollController.hasClients) return;
    if (scrollController.position.pixels >=
            scrollController.position.maxScrollExtent - 200 &&
        !isLoading &&
        !isLoadingMore &&
        hasMore) {
      loadMore();
    }
  }

  Future<void> load(int targetPage) async {
    setState(() {
      isLoading = true;
      isLoadingMore = false;
      errorText = null;
    });
    try {
      final result = await fetchPage(targetPage);
      if (!mounted) return;
      if (result['success'] != true) {
        setState(() {
          errorText = result['message'] as String? ?? '加载失败';
          isLoading = false;
        });
        return;
      }
      onPageFetched(result);
      if (!mounted) return;
      setState(() {
        items = (result['items'] as List<dynamic>? ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        pageNumber = result['currentPage'] as int? ?? targetPage;
        totalPages = result['totalPages'] as int? ?? 1;
        hasMore = pageNumber < totalPages;
        isLoading = false;
      });
      onItemsReplaced();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        errorText = e.toString();
        isLoading = false;
      });
    }
  }

  Future<void> loadMore() async {
    if (isLoading || isLoadingMore || !hasMore) return;
    setState(() => isLoadingMore = true);
    final next = pageNumber + 1;
    try {
      final result = await fetchPage(next);
      if (!mounted) return;
      if (result['success'] != true) {
        setState(() => isLoadingMore = false);
        return;
      }
      final start = items.length;
      setState(() {
        items.addAll(
          (result['items'] as List<dynamic>? ?? const []).map(
            (e) => Map<String, dynamic>.from(e as Map),
          ),
        );
        pageNumber = result['currentPage'] as int? ?? next;
        totalPages = result['totalPages'] as int? ?? totalPages;
        hasMore = pageNumber < totalPages;
        isLoadingMore = false;
      });
      onItemsAppended(start);
    } catch (e) {
      if (!mounted) return;
      AppLogger.w('PAGE', '$runtimeType loadMore error: $e');
      setState(() => isLoadingMore = false);
    }
  }

  /// 当前子类型的内容块：加载 / 错误 / 空 / 列表 + 分页。
  ///
  /// [itemVisible] 为本地投影：返回 false 的条目**整条不渲染**，但下标仍然
  /// 对应 [items]（`itemBuilder` 收到的仍是原始下标）。用于「命中屏蔽后整条
  /// 移除」的场景（消息 → 我的帖子），这样预览缓存、`_tryFetchPreview` 的
  /// 下标都不会因为过滤而错位。传 null 时全量渲染；过滤掉全部条目按空态处理。
  Widget buildPagedList({
    required Widget emptyView,
    required IndexedWidgetBuilder itemBuilder,
    bool Function(int index)? itemVisible,
  }) {
    if (isLoading) return const LoadingView();
    if (errorText != null) {
      return PageErrorWidget(
        message: errorText!,
        onRetry: () => load(1),
        showBack: false,
      );
    }
    final indices = itemVisible == null
        ? null
        : [
            for (var i = 0; i < items.length; i++)
              if (itemVisible(i)) i,
          ];
    final count = indices?.length ?? items.length;
    if (count == 0) return emptyView;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification) _onScroll();
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () => load(1),
        child: ListView.builder(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          itemCount: count + (isLoadingMore || !hasMore ? 1 : 0),
          itemBuilder: (context, i) {
            if (i >= count) {
              return LoadMoreFooter(loading: isLoadingMore, hasMore: hasMore);
            }
            return itemBuilder(context, indices == null ? i : indices[i]);
          },
        ),
      ),
    );
  }
}
