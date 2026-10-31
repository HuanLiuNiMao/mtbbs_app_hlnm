import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/models/special_thanks.dart';

/// 致谢名单条目 — 由 `assets/config/credits.json` 配置，改内容无需动代码。
///
/// 与 [SpecialThanks] 的区别：本名单面向「开源项目 / 技术栈 / 底层依赖」，
/// 条目没有论坛帖子标题，只有名称、一句说明与仓库链接；[uid] 存在时
/// 额外渲染论坛头像（用于作者/维护者这类真实用户）。
class CreditEntry {
  const CreditEntry({
    required this.name,
    required this.desc,
    required this.link,
    this.uid = '',
    this.siteHost = SpecialThanks.defaultSiteHost,
  });

  /// 项目/技术名称（如 `Dart`、`dio`、`MTBBS 上游项目`）
  final String name;

  /// 一句话说明：这个项目在本应用里负责什么
  final String desc;

  /// 仓库/官网链接，点击条目时复制该链接
  final String link;

  /// 论坛 uid（仅真实用户条目有值），用于渲染头像
  final String uid;

  /// 头像所属站点
  final String siteHost;

  bool get hasAvatar => uid.isNotEmpty;

  factory CreditEntry.fromJson(Map<String, dynamic> json) => CreditEntry(
    name: json['name']?.toString() ?? '',
    desc: json['desc']?.toString() ?? '',
    link: json['link']?.toString() ?? '',
    uid: json['uid']?.toString() ?? '',
    siteHost: (json['site']?.toString().trim().isNotEmpty ?? false)
        ? json['site'].toString().trim()
        : SpecialThanks.defaultSiteHost,
  );
}

/// 致谢分组（如「项目与上游」「语言与框架」）
class CreditSection {
  const CreditSection({required this.title, required this.entries});

  final String title;
  final List<CreditEntry> entries;

  factory CreditSection.fromJson(Map<String, dynamic> json) => CreditSection(
    title: json['title']?.toString() ?? '',
    entries: (json['entries'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(CreditEntry.fromJson)
        .where((e) => e.name.isNotEmpty)
        .toList(),
  );
}

/// 致谢名单 — 读取 `assets/config/credits.json`。
///
/// 与鸣谢名单同样采取「配置写错只记日志、返回空列表」的策略：
/// 致谢属于装饰性内容，不能因为 JSON 出错就让页面打不开。
abstract final class Credits {
  static const String assetPath = 'assets/config/credits.json';

  static Future<List<CreditSection>> load() async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      final decoded = jsonDecode(raw);
      final sections = decoded is Map<String, dynamic>
          ? (decoded['sections'] as List<dynamic>? ?? const [])
          : (decoded is List ? decoded : const []);
      return sections
          .whereType<Map<String, dynamic>>()
          .map(CreditSection.fromJson)
          .where((s) => s.entries.isNotEmpty)
          .toList();
    } catch (e) {
      AppLogger.w('Credits', '加载 $assetPath 失败：$e');
      return const [];
    }
  }
}
