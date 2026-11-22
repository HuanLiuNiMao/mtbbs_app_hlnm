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
/// ## 借鉴上游的两点（不改变本仓库的参数契约）
///
/// 1. **`formhash` 可省略**：为空时自动拉一次资料页、从 `#followmod` 补齐。
///    调用方因此可以只在「点关注」时传 fuid，不必先等关注态加载完成。
/// 2. **幂等短路**：补齐时若资料页显示「已关注」，直接返回成功（`followed: true`），
///    不再发写请求 —— 避免重复点击时被服务端回「您已收听该用户」这种错误文案。
///
/// 注意：**自动补齐用到的解析是 `parseFollowStateResponse`**（只关心状态与 hash），
/// 与 `getFollowStatus` 用的 `parseFollowStatus`（要给 fuid / canFollow）不是一套，
/// 但两者都读同一张资料页，结果一致。
Future<Map<String, dynamic>> followUser(
  Dio dio, {
  required String fuid,
  String formhash = '',
}) async {
  var hash = formhash.trim();
  if (hash.isEmpty) {
    final profileResp = await http.getProfilePage(dio, uid: fuid);
    final state = parseWithLog(profileResp, parse.parseFollowStateResponse);
    if (state['success'] != true) return state;
    if (state['followed'] == true) {
      return {'success': true, 'followed': true, 'message': '已关注'};
    }
    hash = state['formhash']?.toString() ?? '';
  }
  if (hash.isEmpty) {
    return {'success': false, 'message': '缺少 formhash，请刷新页面后重试'};
  }

  final resp = await http.submitFollow(dio, fuid: fuid, formhash: hash);
  final r = parseSubmitResponse(safeDecode(resp));
  // 通用成功判据之外，再兜一层关注专用判据（部分站点成功文案不带 succeedhandle_）
  if (r.success) return {'success': true, 'message': r.message};
  final alt = parse.parseFollowResult(safeDecode(resp), resp.statusCode ?? 200, follow: true);
  return alt['success'] == true
      ? alt
      : {'success': false, 'message': r.message};
}

/// 取消关注（取消收听）
///
/// [fuid] 同样是目标用户 uid（取关分支只校验它非空，不校验 hash）。
/// [formhash] 同样可省略，省略时会拉资料页补齐（兼容开启额外校验的站点插件）。
Future<Map<String, dynamic>> unfollowUser(
  Dio dio, {
  required String fuid,
  String formhash = '',
}) async {
  var hash = formhash.trim();
  if (hash.isEmpty) {
    final profileResp = await http.getProfilePage(dio, uid: fuid);
    final state = parseWithLog(profileResp, parse.parseFollowStateResponse);
    if (state['success'] == true) {
      hash = state['formhash']?.toString() ?? '';
    }
  }
  final resp = await http.submitUnfollow(dio, fuid: fuid, formhash: hash);
  final r = parseSubmitResponse(safeDecode(resp));
  if (r.success) return {'success': true, 'message': r.message};
  final alt = parse.parseFollowResult(safeDecode(resp), resp.statusCode ?? 200, follow: false);
  return alt['success'] == true
      ? alt
      : {'success': false, 'message': r.message};
}

/// 查询关注状态与操作令牌（拉取他人主页 PC 页面并解析）
///
/// 返回：`isFollowing`（true/false/null=页面没有按钮）、`followHash`、
/// `formhash`、`fuid`（回显目标 uid，便于写操作直接用）、`canFollow`。
Future<Map<String, dynamic>> getFollowStatus(Dio dio, String uid) async {
  final resp = await http.getFollowStatusPage(dio, uid);
  return parseWithLog(resp, parse.parseFollowStatus);
}
