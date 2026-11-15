import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mtbbs/core/app/site_store.dart';
import 'package:mtbbs/models/read_later_item.dart';
import 'package:mtbbs/providers/read_later_provider.dart';
import 'package:mtbbs/widgets/common/toast_utils.dart';

/// 页面级「稍后再看」：把**当前页面**存为 `type=page` 的本地书签。
///
/// 帖子 / 用户空间 / 版块 / 圈子有各自的结构化快照；关注、好友、留言板、
/// 积分记录这类"页面本身值得临时记录"的入口统一走这里。key 用 `host:page:routePath`，
/// 同一页面重复加入幂等，不同查询参数（如 关注 / 粉丝）互不覆盖。
/// 去掉 `page` 查询参数：条目 key 与保存的路由都不含页码，
/// 页码单独存 [ReadLaterItem.page]，打开时再拼回去 —— 否则翻页会变成另一条 key。
String _stripPageParam(String routePath) {
  final uri = Uri.tryParse(routePath);
  if (uri == null || !uri.hasQuery) return routePath;
  final params = Map<String, String>.from(uri.queryParameters)..remove('page');
  if (params.isEmpty) return uri.path;
  return '${uri.path}?${Uri(queryParameters: params).query}';
}

String readLaterPageId(String routePath) => ReadLaterItem.buildId(
  SiteStore.instance.host,
  'page',
  _stripPageParam(routePath),
);

bool isPageInReadLater(BuildContext context, String routePath) =>
    context.read<ReadLaterProvider>().contains(readLaterPageId(routePath));

/// PageActions 用的菜单项
PopupMenuEntry<String> readLaterMenuItem({required bool inReadLater}) {
  return PopupMenuItem<String>(
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
  );
}

/// 加入 / 移出当前页面；调用方在完成后自行 setState 刷新菜单文案
Future<void> togglePageReadLater(
  BuildContext context, {
  required String routePath,
  required String title,
  required String url,
  String subtitle = '页面',
  int page = 1,
}) async {
  final normalized = _stripPageParam(routePath);
  final id = ReadLaterItem.buildId(
    SiteStore.instance.host,
    'page',
    normalized,
  );
  final provider = context.read<ReadLaterProvider>();
  if (provider.contains(id)) {
    await provider.remove(id);
    showToast('已移出稍后再看');
    return;
  }
  final now = DateTime.now();
  await provider.add(
    ReadLaterItem(
      id: id,
      host: SiteStore.instance.host,
      type: 'page',
      targetId: normalized,
      routePath: normalized,
      title: title,
      subtitle: subtitle,
      url: url,
      page: page,
      addedAt: now,
      updatedAt: now,
    ),
  );
  showToast('已加入稍后再看');
}
