import 'package:flutter/foundation.dart';
import 'package:mtbbs/models/thread_item.dart';
import 'package:mtbbs/core/utils/logger.dart';

/// 帖子列表加载状态
enum LoadState { initial, loading, loaded, error }

/// 通用帖子列表控制器
///
/// 管理分页、刷新、内存缓存逻辑。
/// 无脑翻页：上一页/下一页始终可点击，无数据时显示空状态。
/// 通过 [fetchFn] 注入具体 API 调用，支持导读、版块、个人发帖等场景复用。
class ThreadListController extends ChangeNotifier {
  final Future<Map<String, dynamic>> Function({required int page}) fetchFn;

  List<ThreadItem> items = [];
  LoadState state = LoadState.initial;
  String? errorMessage;
  int page = 1;
  int totalPages = 0; // 仅供跳页弹窗显示，不影响翻页

  /// 内存缓存：page → items
  final Map<int, List<ThreadItem>> _pageCache = {};

  /// 最大缓存页数
  static const int _maxCachePages = 20;

  ThreadListController({required this.fetchFn});
  // ==================== 分页状态 ====================
  bool get hasPrev => page > 1;
  bool get hasNext => true; // 始终允许下一页
  // ==================== 屏蔽补页窗口（功能①扩展） ====================
  /// 当前展示窗口覆盖的服务端页区间 [windowStart, windowEnd]。
  ///
  /// 本地屏蔽把整页过滤空时，自动向后扩窗拉页拼接进 [items]，
  /// 凑满「一页的可见量」再渲染——用户不再需要连续翻好几页找幸存帖。
  int windowStart = 1;
  int windowEnd = 1;
  /// 一页的基准条数（首次加载后按实际首页条数校准；扩窗凑可见的目标量）
  int pageSizeHint = 20;
  /// 窗口最大宽度（服务端页数）——防止极端情况下把几十页全拉下来
  static const int maxWindowWidth = 5;
  /// 扩窗请求进行中（防重入；Grid 缺额检测据此跳过）
  bool _extending = false;
  bool get isExtending => _extending;
  int get windowWidth => windowEnd - windowStart + 1;
  /// 还能不能继续扩窗
  bool get canExtendWindow =>
      !_extending &&
      state != LoadState.loading &&
      windowWidth < maxWindowWidth &&
      (totalPages <= 0 || windowEnd < totalPages);

  // ==================== 加载 / 刷新 ====================

  /// 重置窗口为单页（loadInitial / refresh / goToPage 后调用）
  void _resetWindow() {
    windowStart = page;
    windowEnd = page;
  }
  /// 屏蔽补页：把 [windowEnd]+1 拉回来拼进 [items]，凑可见量。
  ///
  /// 由 Grid 的缺额检测触发（可见条数 < pageSizeHint 且可扩窗时）。
  Future<void> extendWindow() async {
    if (!canExtendWindow) return;
    _extending = true;
    notifyListeners();
    final nextPage = windowEnd + 1;
    try {
      final result = await fetchFn(page: nextPage);
      _throwIfFailed(result);
      final newItems = _parseItems(result);
      final tp = result['totalPages'] as int?;
      if (tp != null && tp > 0) totalPages = tp;
      // 按 threadId 去重后拼接
      final seen = items.map((i) => i.threadId).toSet();
      final merged = List<ThreadItem>.from(items);
      var added = 0;
      for (final it in newItems) {
        if (seen.add(it.threadId)) {
          merged.add(it);
          added++;
        }
      }
      items = merged;
      windowEnd = nextPage;
      if (newItems.isNotEmpty) _cachePage(nextPage, newItems);
      AppLogger.i(
        'PAGE',
        'extendWindow: +$added items from page $nextPage '
        '(window $windowStart-$windowEnd, items=${items.length})',
      );
    } catch (e) {
      // 扩窗失败静默降级：保留现有内容，不再扩（避免用户面见报错）
      AppLogger.w('PAGE', 'extendWindow failed: $e');
    }
    _extending = false;
    notifyListeners();
  }
  /// 下一窗：跳过当前窗口，直接翻到「窗口末页+1」
  Future<void> nextWindow() async {
    if (_extending) return;
    final target = windowEnd + 1;
    // 已知总页数且越界：不再请求不存在的页（旧 nextPage 越界会闪错误态）
    if (totalPages > 0 && target > totalPages) return;
    await goToPage(target);
  }

  /// 首次加载 / 重置加载
  Future<void> loadInitial() async {
    state = LoadState.loading;
    page = 1;
    _resetWindow();
    _pageCache.clear();
    notifyListeners();

    try {
      final result = await fetchFn(page: page);
      _throwIfFailed(result);
      items = _parseItems(result);
      totalPages = result['totalPages'] as int? ?? 0;
      // 校准一页基准条数（扩窗凑可见量的目标线）
      if (items.length > pageSizeHint) pageSizeHint = items.length;
      _cachePage(1, items);
      state = LoadState.loaded;
      AppLogger.i('PAGE', 'loaded ${items.length} items');
    } catch (e) {
      errorMessage = e.toString();
      state = LoadState.error;
      AppLogger.e('PAGE', 'load failed: $e');
    }
    notifyListeners();
  }

  /// 下拉刷新：清空缓存，重新加载第一页
  Future<void> refresh() async {
    if (state == LoadState.loading) return;
    _pageCache.clear();
    page = 1;
    _resetWindow();
    notifyListeners();

    try {
      final result = await fetchFn(page: 1);
      _throwIfFailed(result);
      final newItems = _parseItems(result);
      items = newItems;
      totalPages = result['totalPages'] as int? ?? 0;
      _cachePage(1, newItems);
      notifyListeners();
    } catch (e) {
      // 刷新失败保留当前列表，只记录：清空会让"一刷新就空白"
      AppLogger.w('PAGE', 'refresh failed: $e');
    }
  }

  // ==================== 翻页 ====================

  /// 跳转到指定页（缓存命中直接返回，否则请求）
  Future<void> goToPage(int targetPage) async {
    if (targetPage < 1 || targetPage == page) return;

    // 缓存命中
    if (_pageCache.containsKey(targetPage)) {
      items = List.from(_pageCache[targetPage]!);
      page = targetPage;
      _resetWindow();
      notifyListeners();
      return;
    }

    state = LoadState.loading;
    page = targetPage;
    _resetWindow();
    notifyListeners();

    try {
      final result = await fetchFn(page: targetPage);
      _throwIfFailed(result);
      final newItems = _parseItems(result);

      // 有无数据都停在此页，无数据时显示空状态（分页器仍在，可翻走）
      items = newItems;
      final tp = result['totalPages'] as int?;
      if (tp != null && tp > 0) totalPages = tp;
      if (newItems.isNotEmpty) _cachePage(targetPage, newItems);
      state = LoadState.loaded;
      notifyListeners();
    } catch (e) {
      errorMessage = e.toString();
      page = targetPage > 1 ? targetPage - 1 : 1;
      state = LoadState.error;
      notifyListeners();
    }
  }

  Future<void> nextPage() => goToPage(page + 1);
  Future<void> prevPage() => goToPage(page - 1);

  bool get hasCachedFirst => _pageCache.containsKey(1);

  // ==================== 内部 ====================

  void _cachePage(int p, List<ThreadItem> pageItems) {
    if (_pageCache.length >= _maxCachePages) {
      _pageCache.remove(_pageCache.keys.first);
    }
    _pageCache[p] = List.from(pageItems);
  }

  /// 把 API 层的 `success:false` 转成异常。
  ///
  /// 否则它会被当成"空列表"静默吞掉，用户看到的是"暂无帖子"而不是
  /// "需要先登录"（见 docs/07 经验教训：静默失败）。
  void _throwIfFailed(Map<String, dynamic> result) {
    if (result['success'] == false) {
      throw Exception(result['message']?.toString() ?? '加载失败');
    }
  }

  /// 逐项解析：单条坏数据不能让整个列表挂掉
  List<ThreadItem> _parseItems(Map<String, dynamic> result) {
    final list = result['threads'] as List<dynamic>?;
    if (list == null) return [];
    final items = <ThreadItem>[];
    var failed = 0;
    for (final j in list) {
      try {
        items.add(ThreadItem.fromJson(j as Map<String, dynamic>));
      } catch (e) {
        failed++;
      }
    }
    if (failed > 0) {
      AppLogger.w('PARSE', 'thread item degraded: $failed/${list.length}');
    }
    return items;
  }
}
