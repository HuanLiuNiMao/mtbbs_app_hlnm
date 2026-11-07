import 'package:dio/dio.dart';
import 'package:mtbbs/api/helpers.dart';
import 'package:mtbbs/api/home/follow/http.dart' as http;
import 'package:mtbbs/api/home/follow/parse.dart' as parse;
import 'package:mtbbs/core/parser/xml_helper.dart';

/// 关注/粉丝列表 API 导出
///
/// [type]：'following'（关注/我收听的人）、'follower'（粉丝/我的听众）。
/// [uid] 为空 → 当前登录用户自己的列表；非空 → 查看该 uid 用户的列表。
Future<Map<String, dynamic>> getFollowList(
  Dio dio, {
  required String type,
  String uid = '',
  int page = 1,
}) async {
  final resp = await http.getFollowList(dio, type: type, uid: uid, page: page);
  return parseWithLog(resp, parse.parseResponse);
}

/// 关注（收听）
///
/// [fuid] 是**目标用户 uid**（Discuz `spacecp_follow.php` 里 `$_GET['fuid']`，
/// 为空直接 Access Denied）；[formhash] 是页面全局令牌，它同时充当 `hash`
/// （源码判据 `$_GET['hash'] != FORMHASH`）。
///
/// 两个参数都来自 `getFollowStatus` 的解析结果。
Future<Map<String, dynamic>> followUser(
  Dio dio, {
  required String fuid,
  required String formhash,
}) async {
  final resp = await http.submitFollow(
    dio,
    fuid: fuid,
    formhash: formhash,
  );
  final r = parseSubmitResponse(safeDecode(resp));
  return {'success': r.success, 'message': r.message};
}

/// 取消关注（取消收听）
///
/// [fuid] 同样是目标用户 uid（取关分支只校验它非空，不校验 hash）。
Future<Map<String, dynamic>> unfollowUser(
  Dio dio, {
  required String fuid,
  required String formhash,
}) async {
  final resp = await http.submitUnfollow(
    dio,
    fuid: fuid,
    formhash: formhash,
  );
  final r = parseSubmitResponse(safeDecode(resp));
  return {'success': r.success, 'message': r.message};
}

/// 查询关注状态与操作令牌（拉取他人主页 PC 页面并解析）
///
/// 返回：`isFollowing`（true/false/null=页面没有按钮）、`followHash`、
/// `formhash`、`fuid`（回显目标 uid，便于写操作直接用）。
Future<Map<String, dynamic>> getFollowStatus(Dio dio, String uid) async {
  final resp = await http.getFollowStatusPage(dio, uid);
  return parseWithLog(resp, parse.parseFollowStatus);
}
