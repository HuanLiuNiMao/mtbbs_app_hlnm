import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:mtbbs/api/group/groupindex/export.dart' as group_api;
import 'package:mtbbs/core/app/site_store.dart';
import 'package:mtbbs/core/utils/cache_utils.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/services/api_service.dart';
import 'package:mtbbs/widgets/common/page_actions.dart';
import 'package:mtbbs/widgets/common/toast_utils.dart';
import 'package:mtbbs/models/read_later_item.dart';
import 'package:mtbbs/providers/read_later_provider.dart';
import 'package:mtbbs/widgets/layout/page_error_widget.dart';
import 'package:mtbbs/widgets/layout/pagination_bar.dart';
import 'package:mtbbs/widgets/layout/state_views.dart';

/// 圈子分类下的圈子列表（分页）
///
/// 路径: /groups/category?gid=&name=&page=
/// 数据源: `group.php?gid={gid}&page={page}`（桌面模板，游客可访问）。
class GroupCategoryPage extends StatefulWidget {
  final String gid;
  final String name;
  final int initialPage;

  const GroupCategoryPage({
    super.key,
    required this.gid,
    this.name = '',
    this.initialPage = 1,
  });

  @override
  State<GroupCategoryPage> createState() => _GroupCategoryPageState();
}

class _GroupCategoryPageState extends State<GroupCategoryPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _groups = [];
  late int _page = widget.initialPage;
  int _totalPages = 1;

  @override
  void initState() {
    super.initState();
    _fetch(_page);
  }

  Future<void> _fetch(int page) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await group_api.fetchCategoryGroups(
        ApiService().dio,
        gid: widget.gid,
        page: page,
      );
      if (!mounted) return;
      if (r['success'] != true) {
        setState(() {
          _error = r['message'] as String? ?? '加载失败';
          _loading = false;
        });
        return;
      }
      setState(() {
        _groups = (r['groups'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _page = r['currentPage'] as int? ?? page;
        _totalPages = r['totalPages'] as int? ?? 1;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      AppLogger.w('PAGE', 'GroupCategoryPage error: $e');
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 加入 / 移出「稍后再看」（圈子类型，纯本地）
  void _toggleReadLater(String title) {
    final host = SiteStore.instance.host;
    final id = ReadLaterItem.buildId(host, 'group', widget.gid);
    final provider = context.read<ReadLaterProvider>();
    if (provider.contains(id)) {
      provider.remove(id);
      showToast('已移出稍后再看');
    } else {
      provider.add(
        ReadLaterItem(
          id: id,
          host: host,
          type: 'group',
          targetId: widget.gid,
          routePath:
              '/groups/category?gid=${widget.gid}&name=${Uri.encodeQueryComponent(title)}',
          title: title,
          subtitle: '圈子',
          url: '${SiteStore.instance.baseUrl}/group.php?gid=${widget.gid}',
          addedAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      showToast('已加入稍后再看');
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = widget.name.isNotEmpty ? widget.name : '圈子分类';
    final readLaterId = ReadLaterItem.buildId(
      SiteStore.instance.host,
      'group',
      widget.gid,
    );
    final inReadLater = context
        .watch<ReadLaterProvider>()
        .contains(readLaterId);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        surfaceTintColor: cs.surface,
        elevation: 0.5,
        actions: [
          PageActions(
            url: '${SiteStore.instance.baseUrl}/group.php?gid=${widget.gid}',
            onRefresh: () => _fetch(_page),
            loading: _loading,
            copyLabel: '复制分类链接',
            extraItems: [
              PopupMenuItem<String>(
                value: 'read_later',
                child: Row(
                  children: [
                    Icon(
                      inReadLater
                          ? Icons.bookmark_added_outlined
                          : Icons.bookmark_add_outlined,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(inReadLater ? '移出稍后再看' : '稍后再看'),
                  ],
                ),
              ),
            ],
            onExtraSelected: (action) {
              if (action == 'read_later') _toggleReadLater(title);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody()),
          if (!_loading && _error == null && _totalPages > 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: PaginationBar(
                page: _page,
                totalPages: _totalPages,
                onGoToPage: (p) {
                  _fetch(p);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingView();
    if (_error != null) {
      return PageErrorWidget(message: _error!, onRetry: () => _fetch(_page));
    }
    if (_groups.isEmpty) {
      return const EmptyView(icon: Icons.groups_outlined, text: '该分类下暂无圈子');
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _groups.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 68),
      itemBuilder: (context, i) => _GroupTile(item: _groups[i]),
    );
  }
}

/// 圈子条目：图标 + 名称 + 简介 + 成员/主题数
class _GroupTile extends StatelessWidget {
  final Map<String, dynamic> item;

  const _GroupTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final gid = item['gid'] as String? ?? '';
    final name = item['name'] as String? ?? '';
    final icon = item['icon'] as String? ?? '';
    final desc = item['description'] as String? ?? '';
    final members = item['members'] as int? ?? 0;
    final threads = item['threads'] as int? ?? 0;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 44,
          height: 44,
          child: icon.isEmpty
              ? Icon(Icons.groups, color: cs.onSurfaceVariant)
              : CachedNetworkImage(
                  imageUrl: icon,
                  cacheManager: imageCacheManager,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) =>
                      Icon(Icons.groups, color: cs.onSurfaceVariant),
                ),
        ),
      ),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (desc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                desc,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            '成员 $members · 主题 $threads',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ),
      onTap: () {
        if (gid.isEmpty) return;
        final q = Uri(queryParameters: {'gid': gid, 'name': name}).query;
        context.push('/groups/content?$q');
      },
    );
  }
}
