import 'package:flutter/widgets.dart';
import 'package:mtbbs/core/app/site_session.dart';
import 'package:mtbbs/core/app/site_store.dart';

/// 页面级「站点会话」作用域。
///
/// 路由层根据 location 上的 `site=<host>`（可选 `as=<账号>`）参数注入；
/// 页面用 `SiteScope.of(context)` 取代 `ApiService().dio` / `SiteStore.instance`
/// 的全局读取，从而让同一个页面既能打开当前站点，也能打开别的站点。
///
/// 没有作用域（或没有 `site` 参数）时返回主会话，行为与旧版完全一致。
class SiteScope extends InheritedWidget {
  final SiteSession session;

  const SiteScope({super.key, required this.session, required super.child});

  static SiteSession of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SiteScope>();
    return scope?.session ?? const GlobalSiteSession();
  }

  /// 不建立依赖的读取（异步回调里用，避免无谓重建）
  static SiteSession read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<SiteScope>();
    return scope?.session ?? const GlobalSiteSession();
  }

  /// 当前 location 是否指向"别的站点"
  static bool isCrossSiteLocation(Uri uri) {
    final site = uri.queryParameters['site'];
    return site != null && site.isNotEmpty && site != SiteStore.instance.host;
  }

  /// 在当前作用域下打开 App 内路径：跨站页面自动续接 `site=`，匿名页续接
  /// `anon=1`，全局页面原样返回。页面内部跳转（如用户主页 → 另一个用户）用它，
  /// 否则会把"目标站点 / 匿名身份"丢掉、退回全局身份。
  static String pathFor(BuildContext context, String appPath) {
    final session = read(context);
    // 匿名会话的 host 就是当前站点：不能再拼 `site=`（会被 sessionForLocation
    // 视作"无参数"退化为登录身份），必须拼 `anon=1` 才能延续匿名语义。
    if (session.anonymous) return withAnonParam(appPath);
    if (session.temporary) return withSiteParam(appPath, session.host);
    return appPath;
  }

  @override
  bool updateShouldNotify(SiteScope oldWidget) => oldWidget.session != session;
}

/// 给 App 内路径附加站点参数（跨站跳转传播用）。
///
/// 已有查询参数时用 `&` 续接；`/thread/1` → `/thread/1?site=52pojie.com`。
String withSiteParam(String appPath, String host, {String? account}) {
  if (host.isEmpty) return appPath;
  final sep = appPath.contains('?') ? '&' : '?';
  final base =
      '$appPath$sep'
      'site=${Uri.encodeQueryComponent(host)}';
  if (account == null || account.isEmpty) return base;
  return '$base&as=${Uri.encodeQueryComponent(account)}';
}

/// 给 App 内路径附加「匿名访问」标记（`anon=1`）。
///
/// 语义：本页以**当前站点的游客身份**读取，请求不带任何登录 cookie，只读。
/// 与 `site=` 互斥（`site=` 表示别的站点）；两者都不带 = 全局登录身份。
String withAnonParam(String appPath) {
  if (isAnonLocation(Uri.tryParse(appPath))) return appPath;
  final sep = appPath.contains('?') ? '&' : '?';
  return '$appPath${sep}anon=1';
}

/// 该 location 是否要求匿名访问
bool isAnonLocation(Uri? uri) => uri?.queryParameters['anon'] == '1';

/// 从 App 内路径里去掉站点参数（拼站内 URL / 复制链接时用）
String withoutSiteParam(String appPath) {
  final uri = Uri.tryParse(appPath);
  if (uri == null) return appPath;
  final q = Map<String, String>.from(uri.queryParameters);
  if (!q.containsKey('site') &&
      !q.containsKey('as') &&
      !q.containsKey('anon')) {
    return appPath;
  }
  q.remove('site');
  q.remove('as');
  // 匿名标记也不能进站内 URL（复制出的链接必须是站点真实地址）
  q.remove('anon');
  final query = q.isEmpty
      ? ''
      : '?${q.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
  return '${uri.path}$query';
}
