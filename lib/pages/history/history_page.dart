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
import 'package:mtbbs/core/utils/history_filter.dart';
import 'package:mtbbs/widgets/common/filter_search_field.dart';
import 'package:mtbbs/widgets/dialog/confirm_dialog.dart';
import 'package:mtbbs/widgets/layout/state_views.dart';
import 'package:mtbbs/core/app/app_page_gate.dart';
import 'package:mtbbs/widgets/common/toast_utils.dart';
import 'package:mtbbs/pages/user/user_uid_picker_dialog.dart';

/// 浏览历史记录页面
///
/// 默认展示**全部站点**的记录，可按站点筛选；支持按类型过滤
/// （全部/帖子/用户/我的帖子/回复），支持关键词本地搜索（与站点筛选叠加，
/// 计数同步收窄），点击查看详情，滑动删除。
///
/// 第一个 Tab「稍后再看」展示本地书签（不按类型再分类），点击条目先看信息
/// 再决定查看/删除；它和浏览记录共用同一个站点筛选与搜索框，默认落在第二个
/// Tab「全部」（见 `initState` 的 `initialIndex`），所以老用户的进入路径不变。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  /// 搜索关键词（已 trim；大小写不敏感在 filter 内处理）
  String _query = '';
  final _searchController = TextEditingController();

  /// 站点筛选：null = 全部站点；否则为目标站点 host
  String? _siteFilter;

  /// Tab 顺序：稍后再看 + 5 个浏览记录类型
  static const _tabs = ['稍后再看', '全部', '帖子', '用户', '我的帖子', '回复'];

  /// 支持带 `site=` 在 App 内打开的页面类型。
  ///
  /// 「我的帖子 / 回复」走 `/my-threads`，页面未接入站点作用域，跨站打开会显示
  /// 当前站点的数据，故不允许跨站跳转（见 `_RecordDetailSheet` 与
  /// `_ReadLaterDetailSheet`）。
  static const _crossSiteTypes = {'thread', 'user'};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _tabs.length,
      vsync: this,
      // 默认选中「全部」：稍后再看排在第一个，但不作为默认落点
      initialIndex: 1,
    )..addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Tab 切换会影响「清除已读」是否显示，需要重建右上角菜单
  void _onTabChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 当前关键词 + 当前站点 + 指定类型的记录（列表与 Tab 计数共用）
  ///
  /// 传入 provider 实例而非在内部 `context.read`，保证 build 里 watch 到的
  /// 与过滤用的是同一份数据（Provider 更新时不会出现"计数旧、列表新"）。
  List<BrowseRecord> _filtered(
    HistoryProvider history,
    SettingsProvider settings,
    String type,
  ) {
    // 站点筛选与关键词叠加：先按「类型 + 站点」取，再按关键词过滤
    final source = history.query(type: type, host: _siteFilter);
    return filterBrowseRecords(
      source,
      _query,
      titleOf: (r) => r.displayTitle(_titleTemplateFor(settings, r.type)),
    );
  }

  /// 稍后再看同样吃关键词与站点筛选，口径与浏览记录一致（空白分词 + AND）
  List<ReadLaterItem> _filteredReadLater(ReadLaterProvider readLater) {
    return _filterReadLaterItems(
      readLater.items(host: _siteFilter),
      _query,
      readLater.siteLabel,
    );
  }

  /// Tab 序号 → 浏览记录类型（0 是「稍后再看」，没有对应类型）
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

  /// 站点筛选菜单与"清空后回落"共用的 host 列表（浏览记录 + 稍后再看）
  List<String> _allHosts(HistoryProvider history, ReadLaterProvider readLater) {
    final seen = <String>{};
    final hosts = <String>[];
    for (final host in [...history.recordHosts, ...readLater.hosts]) {
      if (seen.add(host)) hosts.add(host);
    }
    return hosts;
  }

  Future<void> _confirmClear(BuildContext context, int tabIndex) async {
    final history = context.read<HistoryProvider>();
    final readLater = context.read<ReadLaterProvider>();
    final isReadLater = tabIndex == 0;
    final type = isReadLater ? '' : _typeForIndex(tabIndex);
    final label = _tabs[tabIndex];
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

  /// 清除稍后再看里的已读条目（未读不受影响）
  Future<void> _confirmClearRead() async {
    final readLater = context.read<ReadLaterProvider>();
    final readCount =
        readLater.items(host: _siteFilter).where((i) => i.read).length;
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
    if (mounted && _siteFilter != null && !readLater.hosts.contains(_siteFilter)) {
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

  /// 匿名访问用户主页：输入 UID → 以**游客身份**打开该用户主页。
  ///
  /// 与「我的」页的同名入口逻辑一致（见 `ProfilePage._openAnonymousUserPage`）：
  /// 区别只在 `anon=1` 参数，页面用不带登录 cookie 的 Dio 请求，
  /// 站点侧看不到「谁来看过」，也不会因为「自己看自己」而走成本人视角。
  ///
  /// 放在浏览记录页是因为：用户在这里看「我刚看过谁」时，往往下一步就是想
  /// 「不露痕迹地再看一个」，比回「我的」页找入口顺手。
  ///
  /// 若「用户主页」被页面接管到内置浏览器，浏览器用的是登录态，
  /// 等于「匿名入口」变成实名访问 —— 先探测一次，命中就提示而不照跳。
  void _openAnonymousUserPage(BuildContext context) {
    void open(int uid) {
      final path = withAnonParam('/user/$uid');
      if (appPageRedirect(path) != null) {
        showToast('当前设置下用户主页由内置浏览器打开，无法匿名访问（可在 设置 → 页面接管 开启用户主页）');
        return;
      }
      context.push(path);
    }

    showDialog(
      context: context,
      builder: (_) => UidPickerDialog(
        title: '匿名访问用户主页',
        hintText: '输入要访问的 UID',
        confirmLabel: '匿名访问',
        onNavigateToUid: open,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // watch 三个 Provider：记录/书签增删与标题模板变化都要让计数与列表刷新
    final history = context.watch<HistoryProvider>();
    final readLater = context.watch<ReadLaterProvider>();
    final settings = context.watch<SettingsProvider>();

    // 各 Tab 的计数按当前关键词过滤后统计（搜索时计数同步收窄）
    final types = ['', 'thread', 'user', 'mythread', 'reply'];
    final counts = [
      for (final t in types) _filtered(history, settings, t).length,
    ];
    final readLaterItems = _filteredReadLater(readLater);
    final readCount = readLater.items(host: _siteFilter).where((i) => i.read).length;

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
              Tab(text: '稍后再看 (${readLaterItems.length})'),
              for (var i = 0; i < _tabs.length - 1; i++)
                Tab(text: '${_tabs[i + 1]} (${counts[i]})'),
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
                      '${history.siteLabel(host)} '
                      '(${history.count(host: host) + readLater.count(host: host)})',
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
              } else if (v == 'anon') {
                _openAnonymousUserPage(context);
              }
            },
            itemBuilder: (_) => [
              // 「清除已读」只在稍后再看 Tab 下有意义
              if (_tabController.index == 0) ...[
                PopupMenuItem(
                  value: 'clear_read',
                  enabled: readCount > 0,
                  child: Row(
                    children: [
                      Icon(
                        Icons.done_all,
                        size: 18,
                        color: readCount > 0 ? null : cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text('清除已读（$readCount）'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
              ],
              const PopupMenuItem(
                value: 'anon',
                child: Row(
                  children: [
                    Icon(Icons.visibility_off_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('匿名访问用户主页'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
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
      body: Column(
        children: [
          FilterSearchField(
            controller: _searchController,
            query: _query,
            hint: '搜索标题、作者、ID…',
            onChanged: (v) => setState(() => _query = v),
          ),
          if (_query.isNotEmpty)
            _SearchSummary(matched: counts[0], total: history.totalCount),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _ReadLaterList(
                  host: _siteFilter,
                  query: _query,
                  onShowDetail: _showReadLaterDetail,
                ),
                for (final type in types)
                  _RecordList(
                    type: type,
                    query: _query,
                    host: _siteFilter,
                    onShowDetail: _showDetail,
                  ),
              ],
            ),
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
                _infoRow(context, '类型', record.typeLabel),
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

// ==================== 搜索摘要 ====================

/// 搜索时显示"命中 N / 共 M 条"，让用户知道是过滤了还是本来就没记录
class _SearchSummary extends StatelessWidget {
  final int matched;
  final int total;
  const _SearchSummary({required this.matched, required this.total});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '命中 $matched / 共 $total 条',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

// ==================== 记录列表 ====================

/// 记录列表（本地关键词过滤后展示，点击查看详情）
class _RecordList extends StatelessWidget {
  final String type;

  /// 当前搜索关键词，空串表示不过滤
  final String query;

  /// 站点筛选：null = 全部站点（同时展示站点标签）
  final String? host;
  final void Function(BrowseRecord) onShowDetail;
  const _RecordList({
    required this.type,
    required this.query,
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final history = context.watch<HistoryProvider>();
    final settings = context.watch<SettingsProvider>();
    // 先按「类型 + 站点」取，再按关键词过滤——与 Tab 计数的 _filtered 口径一致
    final source = history.query(type: type, host: host);
    final records = filterBrowseRecords(
      source,
      query,
      titleOf: (r) => r.displayTitle(_titleTemplateFor(settings, r.type)),
    );

    if (records.isEmpty) {
      // 区分"本来就没记录"与"关键词没命中"
      return query.isEmpty
          ? const EmptyView(icon: Icons.history, text: '暂无浏览记录')
          : const EmptyView(icon: Icons.search_off, text: '未找到匹配的浏览记录');
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
                  record.typeLabel,
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

/// 稍后再看的本地关键词过滤。
///
/// 与 `filterBrowseRecords` 同一口径（空白分词、全部命中、大小写不敏感），
/// 但字段不同：书签没有 `info`，能搜的是标题、副标题、路由、目标 ID 与类型。
List<ReadLaterItem> _filterReadLaterItems(
  List<ReadLaterItem> items,
  String query,
  String Function(String host) siteLabelOf,
) {
  final tokens = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return items;
  return items.where((item) {
    final haystack = [
      item.title,
      item.subtitle,
      item.routePath,
      item.targetId,
      item.type,
      _ReadLaterList._typeLabel(item.type),
      if (item.host.isNotEmpty) siteLabelOf(item.host),
    ].join('\n').toLowerCase();
    return tokens.every(haystack.contains);
  }).toList();
}

/// 稍后再看列表（历史页第一个 Tab，不按类型再分类）
class _ReadLaterList extends StatelessWidget {
  /// 站点筛选：null = 全部站点
  final String? host;

  /// 当前搜索关键词，空串表示不过滤
  final String query;
  final void Function(ReadLaterItem) onShowDetail;
  const _ReadLaterList({
    this.host,
    this.query = '',
    required this.onShowDetail,
  });

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
    final items = _filterReadLaterItems(
      readLater.items(host: host),
      query,
      readLater.siteLabel,
    );

    if (items.isEmpty) {
      return query.isEmpty
          ? const EmptyView(
              icon: Icons.bookmarks_outlined,
              text: '暂无稍后再看内容\n在帖子、用户空间、版块或圈子页的菜单里加入',
            )
          : const EmptyView(icon: Icons.search_off, text: '未找到匹配的稍后再看');
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
                _infoRow(
                  context,
                  '标题',
                  item.title.isEmpty ? '（无标题）' : item.title,
                ),
                _infoRow(
                  context,
                  '类型',
                  _ReadLaterList._typeLabel(item.type),
                ),
                if (item.host.isNotEmpty)
                  _infoRow(context, '站点', readLater.siteLabel(item.host)),
                if (item.subtitle.isNotEmpty)
                  _infoRow(context, '摘要', item.subtitle),
                _infoRow(context, '路由', item.routePath),
                _infoRow(context, '加入时间', formatDateTimeFull(item.addedAt)),
                _infoRow(context, '状态', item.read ? '已读' : '未读'),
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
    final canOpen =
        !foreign || _HistoryPageState._crossSiteTypes.contains(item.type);
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
