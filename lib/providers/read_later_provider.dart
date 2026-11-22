import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mtbbs/core/app/event_bus.dart';
import 'package:mtbbs/core/app/site_store.dart';
import 'package:mtbbs/core/utils/database_helper.dart';
import 'package:mtbbs/models/read_later_item.dart';

/// 「稍后再看」管理
///
/// 本地 sembast（`read_later` 表）持久化，内存缓存 + 增量写入。
/// 与浏览记录的根本差异：**没有数量上限、没有自动淘汰**，只有 [remove] /
/// [clearFiltered] 才会删数据。跨站点全量保留，页面默认展示全部站点并可筛选。
class ReadLaterProvider extends ChangeNotifier {
  ReadLaterProvider() {
    _siteSub = EventBus.stream
        .where((e) => e is SiteChangedEvent)
        .listen((_) => notifyListeners());
  }

  StreamSubscription<AppEvent>? _siteSub;

  /// 全量条目（跨站点），始终按加入时间倒序
  List<ReadLaterItem> _items = [];

  /// 按类型 / 站点筛选（[host] 为 null 表示全部站点），按加入时间倒序
  List<ReadLaterItem> items({String type = '', String? host}) {
    return _items.where((i) {
      if (host != null && i.host.isNotEmpty && i.host != host) return false;
      return type.isEmpty || i.type == type;
    }).toList();
  }

  /// 按类型 / 站点统计条数（口径同 [items]）
  int count({String type = '', String? host}) =>
      items(type: type, host: host).length;

  /// 有内容的站点（按最近一条条目倒序、去重）
  List<String> get hosts {
    final seen = <String>{};
    final result = <String>[];
    for (final item in _items) {
      if (item.host.isEmpty || !seen.add(item.host)) continue;
      result.add(item.host);
    }
    return result;
  }

  /// 站点显示名（未配置的 host 原样返回）
  String siteLabel(String host) {
    for (final site in SiteStore.instance.sites) {
      if (site.host == host) return site.name;
    }
    return host;
  }

  bool contains(String id) => _items.any((i) => i.id == id);

  ReadLaterItem? byId(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// 加入稍后再看（幂等）
  ///
  /// 已存在时只刷新快照与阅读进度，**保留原加入时间与已读状态**，
  /// 避免重复加入把条目顶到列表最前面。
  Future<void> add(ReadLaterItem item) async {
    final index = _items.indexWhere((i) => i.id == item.id);
    final now = DateTime.now();
    if (index >= 0) {
      final old = _items[index];
      _items[index] = item.copyWith(
        addedAt: old.addedAt,
        read: old.read,
        updatedAt: now,
      );
    } else {
      _items.add(item.copyWith(updatedAt: now));
      _items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    }
    await DatabaseHelper.instance.upsertReadLater(
      _items.firstWhere((i) => i.id == item.id),
    );
    notifyListeners();
  }

  /// 打开条目时回写阅读进度并置已读（条目不存在时静默忽略）
  Future<void> markRead(String id, {int? page}) async {
    final index = _items.indexWhere((i) => i.id == id);
    if (index < 0) return;
    final old = _items[index];
    final next = old.copyWith(
      read: true,
      page: page ?? old.page,
      updatedAt: DateTime.now(),
    );
    if (next.read == old.read && next.page == old.page) return;
    _items[index] = next;
    await DatabaseHelper.instance.upsertReadLater(next);
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _items.removeWhere((i) => i.id == id);
    await DatabaseHelper.instance.deleteReadLater(id);
    notifyListeners();
  }

  Future<void> removeMany(Iterable<String> ids) async {
    final targets = ids.toSet();
    if (targets.isEmpty) return;
    _items.removeWhere((i) => targets.contains(i.id));
    await DatabaseHelper.instance.deleteReadLaterMany(targets.toList());
    notifyListeners();
  }

  /// 按页面选定的范围清空：`host == null` 表示全部站点，[type] 为空表示全部类型
  Future<void> clearFiltered({String? host, String type = ''}) async {
    final targets = _items
        .where(
          (i) =>
              (host == null || i.host.isEmpty || i.host == host) &&
              (type.isEmpty || i.type == type),
        )
        .map((i) => i.id)
        .toList();
    await removeMany(targets);
  }

  /// 清除已读条目（可限定站点）；未读条目不受影响
  Future<void> clearRead({String? host}) async {
    final targets = _items
        .where(
          (i) =>
              i.read && (host == null || i.host.isEmpty || i.host == host),
        )
        .map((i) => i.id)
        .toList();
    await removeMany(targets);
  }

  /// 从 sembast 恢复
  Future<void> load() async {
    _items = await DatabaseHelper.instance.getAllReadLater();
    notifyListeners();
  }

  @override
  void dispose() {
    _siteSub?.cancel();
    super.dispose();
  }
}
