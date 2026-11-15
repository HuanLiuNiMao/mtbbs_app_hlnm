import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:mtbbs/core/app/site_scope.dart';
import 'package:mtbbs/core/app/site_store.dart';
import 'package:mtbbs/providers/history_provider.dart';
import 'package:mtbbs/providers/read_later_provider.dart';
import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/models/browse_record.dart';
import 'package:mtbbs/models/read_later_item.dart';
import 'package:mtbbs/core/utils/formatters.dart';
import 'package:mtbbs/widgets/dialog/confirm_dialog.dart';
import 'package:mtbbs/widgets/layout/state_views.dart';

/// 浏览历史记录页面
///
/// 默认展示**全部站点**的记录，可按站点筛选；支持按类型过滤（全部/帖子/用户/我的帖子/回复），
/// 第一个「稍后再看」Tab 展示本地书签（不按类型再分类），点击条目先看信息再决定查看/删除；
/// 默认落在第二个「全部」Tab。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  /// 站点筛选：null = 全部站点；否则为目标站点 host
  String? _siteFilter;

  static const _tabs = ['稍后再看', '全部', '帖子', '用户', '我的帖子', '回复'];

  /// 支持带 `site=` 在 App 内打开的页面类型。
  ///
  /// 「我的帖子 / 回复」走 `/my-threads`，页面未接入站点作用域，跨站打开会显示
  /// 当前站点的数据，故不允许跨站跳转（见 `_RecordDetailSheet`）。
  static const _crossSiteTypes = {'thread', 'user'};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _tabs.length,
      vsync: this,
      // 默认选中「全部」（稍后再看在第一个，但不作为默认落点）
      initialIndex: 1,
    )..addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  /// Tab 切换会影响「清除已读」是否显示，需要重建右上角菜单
  void _onTabChanged() {
    if (!mounted) return;
    setState(() {});
  }

  String _typeForIndex(int index) {
    switch (index) {
      case 2:
        return 'thread';
      case 3:
        return 'user';
      case 4:
        return 'mythread';
      case 5:
        return 'reply';
      default:
        return '';
    }
  }

  Future<void> _confirmClear(BuildContext context, int tabIndex) async {
    final history = context.read<HistoryProvider>();
    final readLater = context.read<ReadLaterProvider>();
    final isReadLater = tabIndex == 0;
    final type = isReadLater ? '' : _typeForIndex(tabIndex);
    final label = isReadLater ? '稍后再看' : _tabs[tabIndex];
    final scopeLabel = _siteFilter == null
        ? '全部站点'
        : history.siteLabel(_siteFilter!);
    final confirmed = await showConfirmDialog(
      context,
      title: isReadLater ? '清空稍后再看' : '清空记录',
      message: _siteFilter == null
          ? '确定清空「全部站点 · $label」的${isReadLater ? '内容' : '浏览记录'}吗？会删除所有站点的同类条目，且不可恢复。'
          : '确定清空「$scopeLabel · $label」的${isReadLater ? '内容' : '浏览记录'}吗？',
      confirmText: '清空',
      maxWidth: 400,
    );
    if (confirmed != true || !context.mounted) return;
    if (isReadLater) {
      await readLater.clearFiltered(host: _siteFilter);
    } else {
      await history.clearFiltered(host: _siteFilter, type: type);
    }
    // 该站点已无任何条目时自动回到「全部站点」，避免停在空列表
    if (mounted &&
        _siteFilter != null &&
        !_allHosts(history, readLater).contains(_siteFilter)) {
      setState(() => _siteFilter = null);
    }
  }

  /// 站点筛选菜单与"清空后回落"共用的 host 列表（浏览记录 + 稍后再看）
  List<String> _allHosts(HistoryProvider history, ReadLaterProvider readLater) {
    final seen = <String>{};
    final hosts = <String>[];
    for (final host in [...history.recordHosts, ...readLater.hosts]) {
      if (seen.add(host)) hosts.add(host);
    }
    return hosts;
  }

  /// 清除稍后再看里的已读条目（未读不受影响）
  Future<void> _confirmClearRead() async {
    final readLater = context.read<ReadLaterProvider>();
    final readCount = readLater
        .items(host: _siteFilter)
        .where((i) => i.read)
        .length;
    if (readCount == 0) return;
    final scope = _siteFilter == null
        ? '全部站点'
        : readLater.siteLabel(_siteFilter!);
    final confirmed = await showConfirmDialog(
      context,
      title: '清除已读',
      message: '确定清除「$scope」稍后再看里的 $readCount 条已读内容吗？未读条目会保留。',
      confirmText: '清除',
    );
    if (confirmed != true || !mounted) return;
    await readLater.clearRead(host: _siteFilter);
    if (mounted &&
        _siteFilter != null &&
        !readLater.hosts.contains(_siteFilter)) {
      setState(() => _siteFilter = null);
    }
  }

  /// 显示浏览记录详情底部弹窗
  void _showDetail(BrowseRecord record) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => _RecordDetailSheet(record: record),
    );
  }

  /// 稍后再看：先展示信息，再由用户决定查看或删除
  void _showReadLaterDetail(ReadLaterItem item) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => _ReadLaterDetailSheet(item: item),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final history = context.watch<HistoryProvider>();
    final readLater = context.watch<ReadLaterProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _siteFilter == null
              ? '浏览记录'
              : '浏览记录 · ${history.siteLabel(_siteFilter!)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        surfaceTintColor: cs.surface,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelPadding: const EdgeInsets.symmetric(horizontal: 12),
            indicatorPadding: EdgeInsets.zero,
            tabs: [
              Tab(
                text: '稍后再看 (${readLater.count(host: _siteFilter)})',
              ),
              Tab(text: '全部 (${history.count(host: _siteFilter)})'),
              Tab(
                text: '帖子 (${history.count(type: 'thread', host: _siteFilter)})',
              ),
              Tab(
                text: '用户 (${history.count(type: 'user', host: _siteFilter)})',
              ),
              Tab(
                text:
                    '我的帖子 (${history.count(type: 'mythread', host: _siteFilter)})',
              ),
              Tab(
                text: '回复 (${history.count(type: 'reply', host: _siteFilter)})',
              ),
            ],
            labelColor: Theme.of(context).colorScheme.onSurfaceVariant,
            unselectedLabelColor: cs.onSurfaceVariant,
            indicatorColor: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        actions: [
          // 站点筛选：默认「全部站点」，切换站点后计数与列表一起变化
          PopupMenuButton<String>(
            tooltip: _siteFilter == null
                ? '站点筛选：全部站点'
                : '站点筛选：${history.siteLabel(_siteFilter!)}',
            icon: const Icon(Icons.language, size: 20),
            padding: EdgeInsets.zero,
            onSelected: (v) =>
                setState(() => _siteFilter = v.isEmpty ? null : v),
            itemBuilder: (_) {
              final hosts = _allHosts(history, readLater);
              return [
                CheckedPopupMenuItem<String>(
                  value: '',
                  checked: _siteFilter == null,
                  child: Text(
                    '全部站点 (${history.count() + readLater.count()})',
                  ),
                ),
                if (hosts.isNotEmpty) const PopupMenuDivider(),
                for (final host in hosts)
                  CheckedPopupMenuItem<String>(
                    value: host,
                    checked: _siteFilter == host,
                    child: Text(
                      '${history.siteLabel(host)} (${history.count(host: host) + readLater.count(host: host)})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ];
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            padding: EdgeInsets.zero,
            onSelected: (v) {
              if (v == 'clear') {
                _confirmClear(context, _tabController.index);
              } else if (v == 'clear_read') {
                _confirmClearRead();
              }
            },
            itemBuilder: (_) => [
              if (_tabController.index == 0) ...[
                PopupMenuItem(
                  value: 'clear_read',
                  enabled: readLater
                      .items(host: _siteFilter)
                      .any((i) => i.read),
                  child: Text(
                    '清除已读（${readLater.items(host: _siteFilter).where((i) => i.read).length}）',
                  ),
                ),
                const PopupMenuDivider(),
              ],
              PopupMenuItem(
                value: 'clear',
                child: Text(
                  _siteFilter == null
                      ? '清空当前Tab（全部站点）'
                      : '清空当前Tab（${history.siteLabel(_siteFilter!)}）',
                ),
              ),
            ],
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _ReadLaterList(
            host: _siteFilter,
            onShowDetail: _showReadLaterDetail,
          ),
          _RecordList(type: '', host: _siteFilter, onShowDetail: _showDetail),
          _RecordList(
            type: 'thread',
            host: _siteFilter,
            onShowDetail: _showDetail,
          ),
          _RecordList(type: 'user', host: _siteFilter, onShowDetail: _showDetail),
          _RecordList(
            type: 'mythread',
            host: _siteFilter,
            onShowDetail: _showDetail,
          ),
          _RecordList(
            type: 'reply',
            host: _siteFilter,
            onShowDetail: _showDetail,
          ),
        ],
      ),
    );
  }
}

// ==================== 详情底部弹窗 ====================

/// 根据记录类型获取标题模板
String _titleTemplateFor(SettingsProvider s, String type) => switch (type) {
  'thread' => s.historyTitleFormatThread,
  'user' => s.historyTitleFormatUser,
  'mythread' => s.historyTitleFormatMythread,
  'reply' => s.historyTitleFormatReply,
  _ => '{typeLabel}',
};

class _RecordDetailSheet extends StatelessWidget {
  final BrowseRecord record;
  const _RecordDetailSheet({required this.record});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final info = record.info;
    final title = record.displayTitle(
      _titleTemplateFor(context.read<SettingsProvider>(), record.type),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '记录详情',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // 信息列表（可滚动区域，仅内容超出时显示滚动条）
          Flexible(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                _infoRow(context, '标题', title),
                _infoRow(context, '类型', _RecordList._typeLabel(record.type)),
                if (record.effectiveHost.isNotEmpty)
                  _infoRow(
                    context,
                    '站点',
                    context.read<HistoryProvider>().siteLabel(
                      record.effectiveHost,
                    ),
                  ),
                _infoRow(context, '路由', record.routePath),
                _infoRow(context, 'ID', record.id),
                _infoRow(context, '时间', formatDateTimeFull(record.timestamp)),
                if (info.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Text(
                    '原始数据',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final entry in info.entries)
                    _infoRow(context, entry.key, entry.value?.toString() ?? ''),
                ],
              ],
            ),
          ),

          // 操作按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      context.read<HistoryProvider>().remove(record.id);
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('删除'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: cs.error,
                      side: BorderSide(color: cs.error),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      final host = record.effectiveHost;
                      final foreign =
                          host.isNotEmpty && host != SiteStore.instance.host;
                      // 只允许带 `site=` 在 App 内打开的类型；「我的帖子 / 回复」
                      // 走 `/my-threads`，页面未接入站点作用域，跨站会看到当前站点数据
                      final canOpen =
                          !foreign ||
                          _HistoryPageState._crossSiteTypes.contains(
                            record.type,
                          );
                      // 先取路由与 ScaffoldMessenger：pop 之后本 context 已失效
                      final router = GoRouter.of(context);
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.of(context).pop();
                      if (!canOpen) {
                        messenger.showSnackBar(
                          const SnackBar(content: Text('该记录来自其它站点，暂不支持跨站打开')),
                        );
                        return;
                      }
                      router.push(
                        foreign
                            ? withSiteParam(record.routePath, host)
                            : record.routePath,
                      );
                    },
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('前往查看'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

// ==================== 记录列表 ====================

/// 记录列表（点击查看详情）
class _RecordList extends StatelessWidget {
  final String type;

  /// 站点筛选：null = 全部站点（同时展示站点标签）
  final String? host;

  final void Function(BrowseRecord) onShowDetail;
  const _RecordList({
    required this.type,
    this.host,
    required this.onShowDetail,
  });

  static IconData _typeIcon(String t) => switch (t) {
    'thread' => Icons.article_outlined,
    'user' => Icons.person_outline,
    'mythread' => Icons.list_alt,
    'reply' => Icons.reply,
    _ => Icons.history,
  };

  static String _typeLabel(String t) => switch (t) {
    'thread' => '帖子',
    'user' => '用户',
    'mythread' => '我的帖子',
    'reply' => '回复',
    _ => t,
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final history = context.watch<HistoryProvider>();
    final records = history.query(type: type, host: host);

    if (records.isEmpty) {
      return const EmptyView(icon: Icons.history, text: '暂无浏览记录');
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: records.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, indent: 56, color: cs.outlineVariant),
      itemBuilder: (context, index) {
        final record = records[index];
        final title = record.displayTitle(
          _titleTemplateFor(context.read<SettingsProvider>(), record.type),
        );
        // 「全部站点」模式下用站点标签区分同号记录（筛选单站点时无意义，省略）
        final showSite = host == null && record.effectiveHost.isNotEmpty;
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: cs.onSurfaceVariant.withValues(alpha: 0.1),
            child: Icon(
              _typeIcon(record.type),
              color: cs.onSurfaceVariant,
              size: 20,
            ),
          ),
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  _typeLabel(record.type),
                  style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                formatRelativeTime(record.timestamp),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              if (showSite) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    history.siteLabel(record.effectiveHost),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ],
          ),
          trailing: Icon(
            Icons.chevron_right,
            size: 18,
            color: cs.onSurfaceVariant,
          ),
          onTap: () => onShowDetail(record),
        );
      },
    );
  }
}

// ==================== 稍后再看 ====================

/// 稍后再看列表（历史页第 6 个 Tab，不按类型再分类）
class _ReadLaterList extends StatelessWidget {
  /// 站点筛选：null = 全部站点
  final String? host;

  final void Function(ReadLaterItem) onShowDetail;

  const _ReadLaterList({this.host, required this.onShowDetail});

  static IconData _typeIcon(String type) => switch (type) {
    'thread' => Icons.article_outlined,
    'user' => Icons.person_outline,
    'forum' => Icons.forum_outlined,
    'group' => Icons.groups_outlined,
    'page' => Icons.link_outlined,
    _ => Icons.bookmark_border,
  };

  static String _typeLabel(String type) => switch (type) {
    'thread' => '帖子',
    'user' => '空间',
    'forum' => '版块',
    'group' => '圈子',
    'page' => '页面',
    _ => type,
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final readLater = context.watch<ReadLaterProvider>();
    final items = readLater.items(host: host);

    if (items.isEmpty) {
      return const EmptyView(
        icon: Icons.bookmarks_outlined,
        text: '暂无稍后再看内容\n在帖子、用户空间、版块或圈子页的菜单里加入',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: items.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, indent: 56, color: cs.outlineVariant),
      itemBuilder: (context, index) {
        final item = items[index];
        final subtitleParts = <String>[
          item.read ? '已读' : '未读',
          _typeLabel(item.type),
          if (host == null && item.host.isNotEmpty)
            readLater.siteLabel(item.host),
          if (item.type == 'thread' || item.page > 1) '第 ${item.page} 页',
          formatRelativeTime(item.addedAt),
        ];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: cs.onSurfaceVariant.withValues(alpha: 0.1),
            child: Icon(
              _typeIcon(item.type),
              color: item.read
                  ? cs.onSurfaceVariant.withValues(alpha: 0.55)
                  : cs.onSurfaceVariant,
              size: 20,
            ),
          ),
          title: Text(
            item.title.isEmpty ? '（无标题）' : item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // 已读条目整体降饱和，和未读一眼分开
            style: TextStyle(
              fontSize: 14,
              color: item.read ? cs.onSurfaceVariant : null,
            ),
          ),
          subtitle: Text(
            subtitleParts.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          trailing: item.read
              ? Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant)
              : Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    shape: BoxShape.circle,
                  ),
                ),
          onTap: () => onShowDetail(item),
        );
      },
    );
  }
}

/// 稍后再看详情弹窗：先看信息，再决定「前往查看」或「删除」
class _ReadLaterDetailSheet extends StatelessWidget {
  final ReadLaterItem item;
  const _ReadLaterDetailSheet({required this.item});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final readLater = context.read<ReadLaterProvider>();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '稍后再看详情',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                _infoRow(context, '标题', item.title.isEmpty ? '（无标题）' : item.title),
                _infoRow(
                  context,
                  '类型',
                  _ReadLaterList._typeLabel(item.type),
                ),
                if (item.host.isNotEmpty)
                  _infoRow(context, '站点', readLater.siteLabel(item.host)),
                _infoRow(context, '路由', item.routePath),
                _infoRow(
                  context,
                  '加入时间',
                  formatDateTimeFull(item.addedAt),
                ),
                _infoRow(
                  context,
                  '状态',
                  item.read ? '已读' : '未读',
                ),
                if (item.type == 'thread' || item.page > 1)
                  _infoRow(context, '阅读进度', '第 ${item.page} 页'),
                if (item.url.isNotEmpty) _infoRow(context, '链接', item.url),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      readLater.remove(item.id);
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('删除'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: cs.error,
                      side: BorderSide(color: cs.error),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _open(context),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('前往查看'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 置已读后按站点规则打开（跨站仅帖子/空间支持）
  void _open(BuildContext context) {
    final readLater = context.read<ReadLaterProvider>();
    readLater.markRead(item.id);
    final host = item.host;
    final foreign = host.isNotEmpty && host != SiteStore.instance.host;
    final canOpen = !foreign || const {'thread', 'user'}.contains(item.type);
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    if (!canOpen) {
      messenger.showSnackBar(
        const SnackBar(content: Text('该条目来自其它站点，暂不支持跨站打开')),
      );
      return;
    }
    var path = item.routePath;
    if (item.page > 1) {
      path = '$path${path.contains('?') ? '&' : '?'}page=${item.page}';
    }
    router.push(foreign ? withSiteParam(path, host) : path);
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
