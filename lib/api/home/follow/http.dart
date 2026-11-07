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
/// ## 参数来源（对齐 Discuz 官方 `source/include/spacecp/spacecp_follow.php`）
///
/// ```php
/// // op=add
/// $followuid = intval($_GET['fuid']);
/// if($_GET['hash'] != FORMHASH || empty($followuid)) exit('Access Denied');
/// // op=del
/// $delfollowuid = intval($_GET['fuid']);
/// if(empty($delfollowuid)) exit('Access Denied');
/// ```
///
/// 两条硬约束：
/// 1. **`fuid` 是目标用户 uid，必填** —— 只给 hash 不给 fuid 会被判 Access Denied，
///    这也是早期版本「点了没反应」的根因。
/// 2. **`hash` 不是独立令牌，它必须等于页面 formhash**（`$_GET['hash'] != FORMHASH`）。
///    因此调用方把同一个 formhash 同时作为 `hash` 与 `formhash` 传入即可；
///    从按钮 href 里解析出的 hash 与 `input[name=formhash]` 是同一个值，
///    但**以 formhash 为准**更稳（href 可能被模板省略）。
Future<Response<String>> submitFollow(
  Dio dio, {
  required String fuid,
  required String formhash,
}) {
  return dio.post<String>(
    '/home.php?mod=spacecp&ac=follow&op=add'
    '&hash=$formhash&fuid=$fuid&handlekey=followmod&inajax=1',
    data: {'formhash': formhash, 'followsubmit': 'true'},
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
///
/// 取关分支不校验 hash（只校验 fuid 非空），但仍带上 formhash，
/// 以兼容开启了额外校验的站点/插件。
Future<Response<String>> submitUnfollow(
  Dio dio, {
  required String fuid,
  required String formhash,
}) {
  return dio.post<String>(
    '/home.php?mod=spacecp&ac=follow&op=del'
    '&hash=$formhash&fuid=$fuid&handlekey=followmod&inajax=1',
    data: {'formhash': formhash},
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
