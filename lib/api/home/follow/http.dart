import 'package:dio/dio.dart';
import 'package:mtbbs/config/site_config.dart';
import 'package:mtbbs/core/app/site_store.dart';

/// 关注/粉丝列表 HTTP 请求 — 基于 Dio
///
/// baseUrl / UA 由 ApiService 的 BaseOptions 统一提供。
///
/// [type]：'following'（我收听的人/关注）、'follower'（我的听众/粉丝）。
/// [uid] 为空 → 当前登录用户自己的列表；非空 → 查看指定 uid 用户的列表。
Future<Response<String>> getFollowList(
  Dio dio, {
  required String type,
  String uid = '',
  int page = 1,
}) {
  final base = '/home.php?mod=follow&do=$type';
  if (uid.isNotEmpty) {
    return dio.get<String>('$base&uid=$uid&page=$page');
  }
  return dio.get<String>('$base&page=$page');
}

/// 关注/取关写接口 — 站点为阿里云 ESA WAF 前置，
/// 写操作必须 PC UA + form 编码 + X-Requested-With
/// （与 home/wall/http.dart 同一约定，否则被 WAF 拦成挑战页）。
///
/// [hashUid] 为加密后的目标 uid（Discuz "收听"操作使用 hash 过的 uid，
/// 从他人主页 HTML 解析获得）。
/// [formhash] 为页面全局令牌，同样从他人主页 HTML 解析获得。
Future<Response<String>> submitFollow(
  Dio dio, {
  required String hashUid,
  required String formhash,
}) {
  return dio.post<String>(
    '/home.php?mod=spacecp&ac=follow&op=add&hash=$hashUid&inajax=1',
    data: {
      'formhash': formhash,
      'followsubmit': 'true',
    },
    options: Options(
      headers: {
        'User-Agent': Site.uaPc,
        'Content-Type': Headers.formUrlEncodedContentType,
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': '${SiteStore.instance.baseUrl}/',
      },
    ),
  );
}

/// 取消关注
Future<Response<String>> submitUnfollow(
  Dio dio, {
  required String hashUid,
  required String formhash,
}) {
  return dio.post<String>(
    '/home.php?mod=spacecp&ac=follow&op=del&hash=$hashUid&inajax=1',
    data: {
      'formhash': formhash,
    },
    options: Options(
      headers: {
        'User-Agent': Site.uaPc,
        'Content-Type': Headers.formUrlEncodedContentType,
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': '${SiteStore.instance.baseUrl}/',
      },
    ),
  );
}

/// 拉取他人主页（PC 模板）以解析关注态与令牌。
///
/// 与关注/取关写接口使用同一 UA，保证取到的 formhash 与服务器端
/// 校验一致。
Future<Response<String>> getFollowStatusPage(Dio dio, String uid) {
  return dio.get<String>(
    '/home.php?mod=space&uid=$uid&do=profile',
    options: Options(headers: {'User-Agent': Site.uaPc}),
  );
}
