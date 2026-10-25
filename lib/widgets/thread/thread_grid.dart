import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:go_router/go_router.dart';
import 'package:mtbbs/controllers/thread_list_controller.dart';
import 'package:mtbbs/core/app/site_scope.dart';
import 'package:mtbbs/models/thread_item.dart';
import 'package:mtbbs/models/thread_detail.dart';
import 'package:mtbbs/widgets/thread/thread_card.dart';
import 'package:mtbbs/widgets/dialog/page_jump_dialog.dart';
import 'package:mtbbs/widgets/layout/state_views.dart';

part 'thread_grid_build.dart';
part 'thread_grid_paginator.dart';

/// 通用帖子列表网格
///
/// 功能：
/// - 下拉刷新
/// - 分页器（上一页 / 页码 / 下一页），切换时滚动到顶部
/// - 响应式列数（手机 1 列，平板 2 列，桌面 3 列）
/// - 加载中骨架屏
/// - 空状态、错误状态显示
class ThreadGrid extends StatefulWidget {
  final ThreadListController controller;
  final bool visible;
  final void Function(ThreadItem item)? onViewReplies;
  final Map<int, List<PostItem>> expandedReplies;
  final Set<int> loadingReplies;
  final Map<int, String> errorReplies;

  /// 空列表时的提示文案 / 图标（搜索等场景可定制）
  final String emptyText;
  final IconData emptyIcon;

  /// 关键词高亮：非空时透传给 [ThreadCard]（搜索场景使用）
  final String highlight;
  /// 列表投影过滤器（功能①：板块/关键词过滤，本地隐藏，不改数据源）
  ///
  /// 为 null 时不过滤；过滤结果只用于渲染，`_onStateChanged` 仍以
  /// controller 原始列表做 identical 判等。
  final List<ThreadItem> Function(List<ThreadItem>)? itemFilter;
  /// 屏蔽补页（功能①扩展）：过滤后可见条数不足一页基准时自动向后扩窗。
  ///
  /// 仅在该列表点实际启用屏蔽时置 true（由页面按配置计算传入）；
  /// 未启用过滤的页面保持 false，避免对天然短页发起无谓请求。
  final bool autoExtendOnDeficit;

  /// 供"重复点击 Tab 回到顶部"取用：列表控制器 → 该列表的滚动控制器
  /// （滚动控制器在 State 里是私有的，外面够不着，只能这样暴露）
  static final Map<ThreadListController, ScrollController> scrollControllers =
      {};

  const ThreadGrid({
    super.key,
    required this.controller,
    this.visible = true,
    this.onViewReplies,
    this.expandedReplies = const {},
    this.loadingReplies = const {},
    this.errorReplies = const {},
    this.emptyText = '暂无帖子',
    this.emptyIcon = Icons.inbox_outlined,
    this.highlight = '',
    this.itemFilter,
    this.autoExtendOnDeficit = false,
  });

  @override
  State<ThreadGrid> createState() => _ThreadGridState();
}

class _ThreadGridState extends State<ThreadGrid>
    with AutomaticKeepAliveClientMixin {
  bool _everLoaded = false;
  final ScrollController _scrollController = ScrollController();
  List<ThreadItem>? _lastItems;
  int _lastPage = 1;
  LoadState _lastState = LoadState.initial;
  /// 缺额扩窗防抖标记（一次 build 周期最多发一次扩窗请求）
  bool _extendScheduled = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    ThreadGrid.scrollControllers[widget.controller] = _scrollController;
    widget.controller.addListener(_onStateChanged);
  }

  @override
  void didUpdateWidget(ThreadGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onStateChanged);
      widget.controller.addListener(_onStateChanged);
    }
    if (!oldWidget.visible && widget.visible) {
      _checkLoad();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.visible) {
      _checkLoad();
    }
  }

  @override
  void dispose() {
    ThreadGrid.scrollControllers.remove(widget.controller);
    widget.controller.removeListener(_onStateChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _checkLoad() {
    if (_everLoaded) return;
    if (widget.controller.state == LoadState.initial) {
      _everLoaded = true;
      widget.controller.loadInitial();
    }
  }

  void _onStateChanged() {
    if (!mounted) return;
    final ctrl = widget.controller;
    // 数据或状态任一变化时触发重建。列表用「对象身份」判断而非条数：
    // 刷新后新数据条数可能完全相同，只比条数会漏判 → UI 保留旧内容。
    if (identical(ctrl.items, _lastItems) &&
        ctrl.page == _lastPage &&
        ctrl.state == _lastState)
      return;
    _lastItems = ctrl.items;
    _lastPage = ctrl.page;
    _lastState = ctrl.state;
    setState(() {});
  }
/// 页面切换时滚动到顶部
  void _handlePageChange() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  /// 屏蔽补页缺额检测（功能①扩展）：过滤后可见条数不足一页基准时，
  /// 自动向后扩窗拉页拼接——避免「翻好几页全是被屏蔽的帖子」。
  ///
  /// [visibleCount] 为过滤后的可见条数；在 build 流程末尾调用。
  /// 仅在 [ThreadGrid.autoExtendOnDeficit] 开启时生效。
  void _maybeExtendWindow(int visibleCount, ThreadListController ctrl) {
    if (!widget.autoExtendOnDeficit) return;
    if (_extendScheduled) return;
    if (!ctrl.canExtendWindow) return;
    if (visibleCount >= ctrl.pageSizeHint) return;
    _extendScheduled = true;
    Future<void>(() async {
      try {
        await ctrl.extendWindow();
      } finally {
        _extendScheduled = false;
      }
    });
  }


  @override
  Widget build(BuildContext context) {
    // AutomaticKeepAliveClientMixin 要求 build 调用 super.build 以注册 keep-alive
    super.build(context);
    return _buildPage(context);
  }

  // ==================== 响应式列数 ====================

  int _crossAxisCount(double width) {
    if (width >= 900) return 3;
    if (width >= 600) return 2;
    return 1;
  }

  double _gridSpacing(double width) {
    return width >= 600 ? 8 : 0;
  }
}
