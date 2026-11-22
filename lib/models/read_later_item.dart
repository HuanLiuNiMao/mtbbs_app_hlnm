/// 「稍后再看」条目
///
/// 与浏览记录（有上限、会被新记录挤走）和收藏（服务端、需登录、仅帖子）
/// 刻意分离：本地持久化、**无自动淘汰**，只有用户手动删除才会消失。
///
/// [id] 规则：`host:type:targetId`（如 `bbs.example.com:thread:123`），
/// 天然幂等，且不同站点的同号 tid/uid/fid 不会互相覆盖。
class ReadLaterItem {
  final String id;

  /// 条目所属站点 host（跨站打开时用于续接 `site=` 参数）
  final String host;

  /// 类型：`thread` 帖子 / `user` 用户空间 / `forum` 版块 / `group` 圈子
  final String type;

  /// 类型对应的站内 ID（tid / uid / fid / gid）
  final String targetId;

  /// App 路由路径（不含 `site=`，打开时按需附加）
  final String routePath;

  /// 加入时的标题快照（列表离线可渲染；打开后以服务端为准）
  final String title;

  /// 副标题快照：帖子作者 / 版块或圈子名称
  final String subtitle;

  /// 帖子作者 uid（其余类型为空）
  final String authorUid;

  /// 网页地址（"在浏览器打开"、复制链接用）
  final String url;

  /// 帖子：上次看到第几页；其余类型恒为 1
  final int page;

  /// 是否打开过（列表显示未读圆点）
  final bool read;

  /// 加入时间（排序依据，重复加入不变）
  final DateTime addedAt;

  /// 最近一次快照/进度更新时间
  final DateTime updatedAt;

  const ReadLaterItem({
    required this.id,
    required this.host,
    required this.type,
    required this.targetId,
    required this.routePath,
    required this.title,
    this.subtitle = '',
    this.authorUid = '',
    this.url = '',
    this.page = 1,
    this.read = false,
    required this.addedAt,
    required this.updatedAt,
  });

  static String buildId(String host, String type, String targetId) =>
      '$host:$type:$targetId';

  ReadLaterItem copyWith({
    String? title,
    String? subtitle,
    String? authorUid,
    String? url,
    String? routePath,
    int? page,
    bool? read,
    DateTime? addedAt,
    DateTime? updatedAt,
  }) {
    return ReadLaterItem(
      id: id,
      host: host,
      type: type,
      targetId: targetId,
      routePath: routePath ?? this.routePath,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      authorUid: authorUid ?? this.authorUid,
      url: url ?? this.url,
      page: page ?? this.page,
      read: read ?? this.read,
      addedAt: addedAt ?? this.addedAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'host': host,
    'type': type,
    'targetId': targetId,
    'routePath': routePath,
    'title': title,
    'subtitle': subtitle,
    'authorUid': authorUid,
    'url': url,
    'page': page,
    'read': read,
    'addedAt': addedAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ReadLaterItem.fromJson(Map<String, dynamic> json) => ReadLaterItem(
    id: json['id']?.toString() ?? '',
    host: json['host']?.toString() ?? '',
    type: json['type']?.toString() ?? '',
    targetId: json['targetId']?.toString() ?? '',
    routePath: json['routePath']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    subtitle: json['subtitle']?.toString() ?? '',
    authorUid: json['authorUid']?.toString() ?? '',
    url: json['url']?.toString() ?? '',
    page: int.tryParse(json['page']?.toString() ?? '') ?? 1,
    read: json['read'] == true,
    addedAt:
        DateTime.tryParse(json['addedAt']?.toString() ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
        DateTime.now(),
  );
}
