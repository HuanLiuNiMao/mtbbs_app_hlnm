import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:mtbbs/core/app/site_scope.dart';
import 'package:mtbbs/core/app/site_store.dart';
import 'package:mtbbs/providers/history_provider.dart';
import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/models/browse_record.dart';
import 'package:mtbbs/core/utils/formatters.dart';
import 'package:mtbbs/core/utils/history_filter.dart';
import 'package:mtbbs/widgets/common/filter_search_field.dart';
import 'package:mtbbs/widgets/dialog/confirm_dialog.dart';
import 'package:mtbbs/widgets/layout/state_views.dart';

/// 浏览历史记录页面
///
/// 默认展示**全部站点**的记录，可按站点筛选；支持按类型过滤（全部/帖子/用户/我的帖子/回复），
/// 支持关键词本地搜索（与站点筛选叠加，计数同步收窄），点击查看详情，滑动删除。
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

  static const _tabs = ['全部', '帖子', '用户', '我的帖子', '回复'];

  /// 支持带 `site=` 在 App 内打开的页面类型。
  ///
  /// 「我的帖子 / 回复」走 `/my-threads`，页面未接入站点作用域，跨站打开会显示
  /// 当前站点的数据，故不允许跨站跳转（见 `_RecordDetailSheet`）。
  static const _crossSiteTypes = {'thread', 'user'};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
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

  String _typeForIndex(int index) {
    switch (index) {
      case 1:
        return 'thread';
      case 2:
        return 'user';
      case 3:
        return 'mythread';
      case 4:
        return 'reply';
      default:
        return '';
    }
  }

  Future<void> _confirmClear(BuildContext context, int tabIndex) async {
    final history = context.read<HistoryProvider>();
    final type = _typeForIndex(tabIndex);
    final label = _tabs[tabIndex];
    final scopeLabel = _siteFilter == null
        ? '全部站点'
        : history.siteLabel(_siteFilter!);
    final confirmed = await showConfirmDialog(
      context,
      title: '清空记录',
      message: _siteFilter == null
          ? '确定清空「全部站点 · $label」的浏览记录吗？会删除所有站点的同类记录，且不可恢复。'
          : '确定清空「$scopeLabel · $label」的浏览记录吗？',
      confirmText: '清空',
      maxWidth: 400,
    );
    if (confirmed == true && context.mounted) {
      await history.clearFiltered(host: _siteFilter, type: type);
      // 该站点已无任何记录时自动回到「全部站点」，避免停在空列表
      if (mounted &&
          _siteFilter != null &&
          !history.recordHosts.contains(_siteFilter)) {
        setState(() => _siteFilter = null);
      }
    }
  }

  /// 显示浏览记录详情底部弹窗
  void _showDetail(BrowseRecord record) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => _RecordDetailSheet(record: record),
    );
  }

  @override
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

  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // watch 两个 Provider：记录增删与标题模板变化都要让计数/列表刷新
    final history = context.watch<HistoryProvider>();
    final settings = context.watch<SettingsProvider>();

    // 各 Tab 的计数按当前关键词过滤后统计（搜索时计数同步收窄）
    final types = ['', 'thread', 'user', 'mythread', 'reply'];
    final counts = [
      for (final t in types) _filtered(history, settings, t).length,
    ];

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
              for (var i = 0; i < _tabs.length; i++)
                Tab(text: '${_tabs[i]} (${counts[i]})'),
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
              final hosts = history.recordHosts;
              return [
                CheckedPopupMenuItem<String>(
                  value: '',
                  checked: _siteFilter == null,
                  child: Text('全部站点 (${history.count()})'),
                ),
                if (hosts.isNotEmpty) const PopupMenuDivider(),
                for (final host in hosts)
                  CheckedPopupMenuItem<String>(
                    value: host,
                    checked: _siteFilter == host,
                    child: Text(
                      '${history.siteLabel(host)} (${history.count(host: host)})',
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
              } else if (v == 'anon') {
                _openAnonymousUserPage(context);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'anon',
                child: const Row(
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
                for (final type in ['', 'thread', 'user', 'mythread', 'reply'])
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
