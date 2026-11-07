import 'dart:io' show Directory, Platform;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:mtbbs/config/site_config.dart';

/// 应用文件路径集中管理
///
/// 所有磁盘路径统一由此类提供，避免各模块各自调用 [getApplicationSupportDirectory] /
/// [getTemporaryDirectory] / [Directory.systemTemp] 导致路径散落。
///
/// **⚠️ 禁止使用 [getApplicationDocumentsDirectory] 存储 App 数据**
/// 该 API 在 Windows 上返回用户的 Documents 文件夹（公共路径），
/// 所有 App 内部数据应使用 [getApplicationSupportDirectory]（应用私有目录）。
///
/// 目录结构：
/// ```
/// {appDataDir}/                 ← 见 [appDataDir]
///   cookies/{host}/              — CookieJar 持久化（游客）
///   cookies/{host}/{account}/    — CookieJar 持久化（登录用户）
///   mtbbs.sembast                — sembast 数据库（纯 Dart，无需原生依赖）
///
/// {tempDir}/                    ← getTemporaryDirectory()
///   emoji_cache/                 — CacheManager 表情
///   avatar_cache/                — CacheManager 头像
///   image_cache/                 — CacheManager 图片
///   mtbbs_clip/                  — ClipboardPasteService 临时文件
/// ```
class AppPaths {
  AppPaths._();

  // ==================== 应用私有数据目录 ====================

  /// 应用私有数据根目录
  ///
  /// Windows release: `%APPDATA%\qcxs\mtbbs\`
  /// Windows debug:   `%APPDATA%\qcxs\mtbbs_debug\`
  /// Android:         `/data/data/{package}/app_flutter/`
  static Future<String> get appDataDir async {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ?? '';
      final suffix = kDebugMode ? '_debug' : '';
      return '$appData\\qcxs\\mtbbs$suffix';
    }
    return (await getApplicationSupportDirectory()).path;
  }

  // ==================== 临时目录 ====================

  static Future<String> get tempDir async =>
      (await getTemporaryDirectory()).path;

  // ==================== 数据库 ====================

  /// `{appDataDir}/mtbbs.sembast`
  static Future<String> get databasePath async =>
      '${await appDataDir}${p.separator}mtbbs.sembast';

  /// 帖子缓存独立数据库 `{appDataDir}/threads.sembast`
  ///
  /// 刻意不经过 [databasePath] 的主库：缓存正文体积大，独立文件损坏时
  /// 不影响登录态、设置、历史等主库数据（见 docs/01 的持久化例外说明）。
  static Future<String> get threadDatabasePath async =>
      '${await appDataDir}${p.separator}threads.sembast';

  /// 导出兜底目录 `{appDataDir}/exports/`
  ///
  /// 平台「另存为」不可用时，导出文件写入此目录并提示路径。
  static Future<String> get exportsDir async =>
      '${await appDataDir}${p.separator}exports';

  /// 本地自动备份目录 `{appDataDir}/backups/`
  ///
  /// 为什么不是 `exports/`：导出目录是「用户主动另存为的落地兜底」，
  /// 本地自动备份是「后台按周期滚动的环形存档」，语义与生命周期都不同 ——
  /// 混在一起会让「清理旧备份」误删用户手动导出的文件。
  ///
  /// 放在应用私有目录（而非外置存储）：后台任务在 WorkManager 的独立
  /// isolate 里跑，没有 Activity 可用，无法弹 SAF 授权；私有目录不需要
  /// 任何运行时权限，卸载时随应用一起清除，也避免备份里的 Cookie 明文
  /// 落在其他应用可读的位置。
  static Future<String> get backupsDir async =>
      '${await appDataDir}${p.separator}backups';

  // ==================== Cookie ====================

  /// `{appDataDir}/cookies/`
  static Future<String> cookiesDir() async =>
      '${await appDataDir}/${SiteConfig.cookieDir}';

  /// `{appDataDir}/cookies/{host}/`
  static Future<String> cookiesDirForHost(String host) async =>
      '${await cookiesDir()}/$host';

  /// `{appDataDir}/cookies/{host}/{account}/`
  static Future<String> cookiesDirForAccount(
    String host,
    String account,
  ) async => '${await cookiesDirForHost(host)}/$account';

  /// 匿名浏览专用罐目录 `{appDataDir}/anon_cookies/{host}/`。
  ///
  /// 刻意**不与账号罐同根**（`cookies/{host}/`）：
  /// - 不能复用游客罐（`cookies/{host}/` 根）：那是全局 `switchToGuest` 用的罐，
  ///   两个 `PersistCookieJar` 指向同一目录会互相覆盖（见 docs/27）；
  /// - 也不能放在 `cookies/{host}/.anon/`：`accountJarDirsForHost` 会把"含子目录"
  ///   的条目当成账号罐，进而用**另一个** `PersistCookieJar` 实例往同一目录补写
  ///   客户端级 cookie —— 又变成两个实例互相覆盖。
  ///
  /// 独立根目录同时天然把匿名罐排除在账号罐扫描之外。
  static Future<String> anonCookiesDirForHost(String host) async =>
      '${await appDataDir}/anon_cookies/$host';

  /// 列出本站点所有**账号罐**目录（`cookies/{host}/{账号}/`）。
  ///
  /// 用于把「客户端级 cookie」（人机验证 / 防火墙）补写到每个罐：这类 cookie 与
  /// 账号无关，而罐按账号隔离 —— 只写活跃罐的话，切账号 / 切游客 / 重启落到别的
  /// 罐就要重新验证（见 docs/07 #73）。
  ///
  /// 游客罐的文件直接写在 `cookies/{host}/` **根上**，账号罐目录里才会再套一层
  /// `FileStorage` 的存储目录 —— 据此区分两者，无需硬编码存储目录名。
  static Future<List<String>> accountJarDirsForHost(String host) async {
    final root = Directory(await cookiesDirForHost(host));
    if (!await root.exists()) return const [];
    final dirs = <String>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      await for (final child in entity.list(followLinks: false)) {
        if (child is Directory) {
          dirs.add(entity.path);
          break;
        }
      }
    }
    return dirs;
  }

  // ==================== 剪贴板临时文件 ====================

  /// `{tempDir}/mtbbs_clip/`
  static Future<String> get clipboardDir async => '${await tempDir}/mtbbs_clip';

  // ==================== 缓存统计/清空 ====================

  /// 获取缓存 key 对应的完整目录路径
  ///
  /// CacheManager 默认将缓存存在 `{tempDir}/{configKey}/` 下。
  static Future<String> cachePath(String configKey) async =>
      '${await tempDir}/$configKey';
}
