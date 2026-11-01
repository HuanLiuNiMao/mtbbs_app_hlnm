import 'package:flutter/material.dart';

/// 备份项 id。
///
/// 只有**叶子项**会写进备份包（`payloadKey` 非空）；分组父（如
/// [browseHistory]）仅用于 UI 聚合，不产生 payload。
///
/// 枚举名会随「设置持久化」写进 `AppSettings.backup.selected`，因此
/// **不要改名**：改名等价于用户丢掉该项的勾选状态（会回落到默认值）。
/// 备份包内的键名另由 [BackupItemSpec.payloadKey] 定义，与枚举名解耦。
enum BackupItemId {
  appSettings,
  siteSettings,
  shortcuts,
  mtImageHistory,
  browseHistory,
  browseHistoryUser,
  browseHistoryPost,
  editorSettings,
  editorSnapshots,
  contentFilter,
  mcpConfig,
  accountCookies,
}

/// 单个备份项的静态声明。
class BackupItemSpec {
  const BackupItemSpec({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.defaultSelected = false,
    this.parent,
    this.payloadKey,
    this.requires = const [],
    this.sensitive = false,
  });

  /// 枚举 id
  final BackupItemId id;

  /// 设置页显示名
  final String title;

  /// 一句话说明「备份了什么」，用于复选框副标题
  final String subtitle;

  final IconData icon;

  /// 首次运行 / 重置时的默认勾选状态
  final bool defaultSelected;

  /// 所属分组（null = 顶层项）
  final BackupItemId? parent;

  /// 备份包 `modules` 里的键；null 表示这是分组头，不产生 payload
  final String? payloadKey;

  /// 勾选本项时自动勾选的依赖项
  final List<BackupItemId> requires;

  /// 含凭据（Cookie / MCP 令牌），导入前需二次确认
  final bool sensitive;

  bool get isGroup => payloadKey == null;
}

/// 备份项声明表 —— 唯一事实来源。
///
/// 新增功能时只改这里：UI 复选框、备份包键名、收集器注册表都以它为准。
abstract final class BackupCatalog {
  static const List<BackupItemSpec> all = [
    BackupItemSpec(
      id: BackupItemId.appSettings,
      title: '应用设置',
      subtitle: '外观、启动、阅读、通知、分享、历史格式、缓存与更新',
      icon: Icons.tune,
      defaultSelected: true,
      payloadKey: 'app_settings',
    ),
    BackupItemSpec(
      id: BackupItemId.siteSettings,
      title: '站点设置',
      subtitle: 'Referer、人机验证、页面接管、字数上限、默认用户、CDN',
      icon: Icons.dns_outlined,
      defaultSelected: true,
      payloadKey: 'site_settings',
    ),
    BackupItemSpec(
      id: BackupItemId.shortcuts,
      title: '快捷方式',
      subtitle: '各站点的快捷链接（名称 / URL / 图标 / 顺序 / 显隐）',
      icon: Icons.link,
      defaultSelected: true,
      payloadKey: 'shortcuts',
    ),
    BackupItemSpec(
      id: BackupItemId.mtImageHistory,
      title: 'MT 图床',
      subtitle: '上传历史（最多 200 条，含 BBCode 与外链）',
      icon: Icons.photo_library_outlined,
      defaultSelected: true,
      payloadKey: 'mt_image_history',
    ),
    BackupItemSpec(
      id: BackupItemId.browseHistory,
      title: '浏览记录',
      subtitle: '用户与帖子分开备份，跨站点全量',
      icon: Icons.history,
    ),
    BackupItemSpec(
      id: BackupItemId.browseHistoryUser,
      title: '浏览记录 · 用户',
      subtitle: '看过的用户空间（UID / 昵称 / 头像 / 链接）',
      icon: Icons.person_outline,
      parent: BackupItemId.browseHistory,
      defaultSelected: true,
      payloadKey: 'browse_history_user',
    ),
    BackupItemSpec(
      id: BackupItemId.browseHistoryPost,
      title: '浏览记录 · 帖子',
      subtitle: '看过的帖子 / 我的帖子 / 回复（含页码）',
      icon: Icons.article_outlined,
      parent: BackupItemId.browseHistory,
      defaultSelected: true,
      payloadKey: 'browse_history_post',
    ),
    BackupItemSpec(
      id: BackupItemId.editorSettings,
      title: '编辑框设置',
      subtitle: '工具栏、常用语、快捷键、快照策略、迷你编辑器',
      icon: Icons.edit_note,
      defaultSelected: true,
      payloadKey: 'editor_settings',
    ),
    BackupItemSpec(
      id: BackupItemId.editorSnapshots,
      title: '编辑框草稿',
      subtitle: '未发出的编辑器快照（含 formhash，可能已过期）',
      icon: Icons.restore_page_outlined,
      requires: [BackupItemId.editorSettings],
      payloadKey: 'editor_snapshots',
    ),
    BackupItemSpec(
      id: BackupItemId.contentFilter,
      title: '内容过滤',
      subtitle: '板块名单 / 标题关键词 / 评论屏蔽词 / 按列表点过滤',
      icon: Icons.filter_alt_outlined,
      defaultSelected: true,
      payloadKey: 'content_filter',
    ),
    BackupItemSpec(
      id: BackupItemId.mcpConfig,
      title: 'MCP 配置',
      subtitle: '开关 / 端口 / 令牌 / 能力分组（含令牌，勿外传）',
      icon: Icons.hub_outlined,
      sensitive: true,
      payloadKey: 'mcp_config',
    ),
    BackupItemSpec(
      id: BackupItemId.accountCookies,
      title: '账号与 Cookie',
      subtitle: '各站点账号列表 + Cookie（可跨设备恢复登录）',
      icon: Icons.cookie_outlined,
      requires: [BackupItemId.siteSettings],
      sensitive: true,
      payloadKey: 'account_cookies',
    ),
  ];

  /// 顶层项（含分组头）
  static List<BackupItemSpec> get roots =>
      all.where((e) => e.parent == null).toList();

  static List<BackupItemSpec> childrenOf(BackupItemId parent) =>
      all.where((e) => e.parent == parent).toList();

  static BackupItemSpec byId(BackupItemId id) =>
      all.firstWhere((e) => e.id == id);

  /// 依赖 [id] 的项（取消 [id] 时需要级联取消它们）
  static List<BackupItemId> dependentsOf(BackupItemId id) =>
      all.where((e) => e.requires.contains(id)).map((e) => e.id).toList();

  /// 全部叶子项（能进备份包的项）
  static List<BackupItemSpec> get leaves =>
      all.where((e) => !e.isGroup).toList();

  /// 默认勾选集合
  static Set<BackupItemId> get defaults => {
    for (final e in leaves)
      if (e.defaultSelected) e.id,
  };

  /// 枚举 id → 备份包键名
  static String keyOf(BackupItemId id) => byId(id).payloadKey ?? id.name;

  /// 备份包键名 → 声明（未知键返回 null，供「向前兼容」静默跳过）
  static BackupItemSpec? byKey(String key) {
    for (final e in all) {
      if (e.payloadKey == key) return e;
    }
    return null;
  }

  /// 导入时的应用顺序（被依赖项在前）。
  ///
  /// 顺序错会导致：站点设置晚于快捷方式写入 → 快捷方式被覆盖；
  /// Cookie 早于站点设置写入 → 找不到 host 的 baseUrl。
  static const List<String> applyOrder = [
    'site_settings',
    'app_settings',
    'shortcuts',
    'editor_settings',
    'editor_snapshots',
    'content_filter',
    'mt_image_history',
    'browse_history_user',
    'browse_history_post',
    'mcp_config',
    'account_cookies',
  ];

  /// 按 [applyOrder] 排序；不在表内的键排在最后（保持传入顺序）
  static List<String> sortKeys(Iterable<String> keys) {
    final list = keys.toList();
    int rank(String k) {
      final i = applyOrder.indexOf(k);
      return i < 0 ? applyOrder.length : i;
    }

    list.sort((a, b) => rank(a).compareTo(rank(b)));
    return list;
  }
}

/// 勾选状态（不可变）。只存叶子项 id；分组父的勾选由子项推导。
@immutable
class BackupSelection {
  const BackupSelection(this.ids);

  final Set<BackupItemId> ids;

  factory BackupSelection.defaults() => BackupSelection(BackupCatalog.defaults);

  /// 从持久化的枚举名集合恢复；空集合回落到默认项，未知名字丢弃。
  factory BackupSelection.fromNames(Iterable<String> names) {
    final set = <BackupItemId>{};
    for (final n in names) {
      for (final e in BackupCatalog.leaves) {
        if (e.id.name == n) set.add(e.id);
      }
    }
    return BackupSelection(set.isEmpty ? BackupCatalog.defaults : set);
  }

  bool contains(BackupItemId id) => ids.contains(id);

  bool groupFully(BackupItemId parent) {
    final kids = BackupCatalog.childrenOf(parent);
    return kids.isNotEmpty && kids.every((e) => ids.contains(e.id));
  }

  bool groupPartial(BackupItemId parent) {
    final kids = BackupCatalog.childrenOf(parent);
    return kids.any((e) => ids.contains(e.id)) && !groupFully(parent);
  }

  /// 点单项：分组父 → 整组开关；叶子 → 勾选时补依赖，取消时级联取消依赖者。
  BackupSelection toggled(BackupItemId id) {
    final spec = BackupCatalog.byId(id);
    if (spec.isGroup) return setGroup(id, !groupFully(id));
    final next = Set<BackupItemId>.from(ids);
    if (next.remove(id)) {
      for (final dep in BackupCatalog.dependentsOf(id)) {
        next.remove(dep);
      }
    } else {
      next.add(id);
      next.addAll(spec.requires);
    }
    return BackupSelection(next);
  }

  BackupSelection setGroup(BackupItemId parent, bool on) {
    final next = Set<BackupItemId>.from(ids);
    for (final kid in BackupCatalog.childrenOf(parent)) {
      if (on) {
        next.add(kid.id);
        next.addAll(kid.requires);
      } else {
        next.remove(kid.id);
      }
    }
    return BackupSelection(next);
  }

  BackupSelection get all =>
      BackupSelection({for (final e in BackupCatalog.leaves) e.id});

  BackupSelection get inverted => BackupSelection({
    for (final e in BackupCatalog.leaves)
      if (!ids.contains(e.id)) e.id,
  });

  int get count => ids.length;

  int get total => BackupCatalog.leaves.length;

  Set<String> toNames() => {for (final id in ids) id.name};

  /// 选中项对应的备份包键名（已按导入顺序排序）
  List<String> toPayloadKeys() =>
      BackupCatalog.sortKeys({for (final id in ids) BackupCatalog.keyOf(id)});
}
