import 'package:html/dom.dart' as dom;
import 'package:mtbbs/api/helpers.dart';
import 'package:mtbbs/core/app/page_helper.dart';

/// 关注/粉丝列表响应解析
///
/// 页面：`home.php?mod=follow&do={following|follower}[&uid={uid}][&page={page}]`
/// - following = 收听（关注）列表；follower = 听众（粉丝）列表
/// - uid 为空 = 当前登录用户自己的列表（Discuz 链接同样省略 uid）
///
/// DOM 结构（两页一致，`#ct li.cl`，均经真实页面验证）：
/// ```html
/// <li class="cl">
///   <a href="space-uid-1155.html" title="posier" class="flw_avt">
///     <img src="uc_server/avatar.php?uid=1155&size=small"></a>
///   <a id="a_followmod_1155" class="flw_btn_unfo">取消收听</a>  <!-- 粉丝页为 flw_btn_fo "收听" -->
///   <h6 class="pbn xs2">
///     <a href="space-uid-1155.html" title="posier" class="xi2">posier</a>
///     <span id="followbkame_1155" class="xg1 xs1 xw0">专做逆向教程的元老</span>  <!-- 仅自己收听页 -->
///   </h6>
///   <p><span class="xg1">最近动作: </span>【新MT管理器教程】第五课...</p>
///   <p class="ptm xg1">
///     来自: 海外  &nbsp;听众: <a href="…do=follower&uid=1155"><strong>318</strong></a>人 &nbsp;
///     收听: <a href="…do=following&uid=1155"><strong>2</strong></a>人 &nbsp;  <!-- 仅自己收听页含备注/特别收听链接 -->
///   </p>
/// </li>
/// ```
///
/// 变体差异（不影响解析）：
/// - 自己的收听页标题"我收听的人"，含 取消收听 按钮、备注、来自、修改备注/添加特别收听
/// - 自己的粉丝页标题"我的听众"，按钮为 收听
/// - 他人页标题"他收听的人/他的听众"，无备注/来自（按钮取决于当前账号与该用户的关系）
///
/// 分页复用 [extractPagination]（标准 .pg，strong 当前页 + 共 N 页 label）。

Map<String, dynamic> parseResponse(String body, int statusCode) {
  final pre = prepareDoc(body, statusCode);
  if (pre.error != null) return pre.error!;
  final doc = pre.doc!;

  final items = <Map<String, dynamic>>[];
  for (final li in doc.querySelectorAll('#ct li.cl')) {
    final item = _parseItem(li);
    if (item.isNotEmpty) items.add(item);
  }

  return {
    'success': true,
    'items': items,
    'count': items.length,
    ...pagedFields(doc),
  };
}

/// 解析单个关注/粉丝 <li>（两页结构一致，兼容自己/他人变体）
Map<String, dynamic> _parseItem(dom.Element li) {
  final item = <String, dynamic>{};

  // 头像
  final avatarImg = li.querySelector('a.flw_avt img');
  if (avatarImg != null) {
    item['avatar'] = avatarImg.attributes['src'];
  }

  // 用户名 + uid（h6 内 .xi2 链接，title 优先）
  final nameLink = li.querySelector('h6 a.xi2');
  if (nameLink != null) {
    final title = sanitizeText(nameLink.attributes['title']);
    final text = sanitizeText(nameLink.text);
    final name = title.isNotEmpty ? title : text;
    if (name.isNotEmpty) item['username'] = name;

    final m = RegExp(
      r'uid-(\d+)',
    ).firstMatch(nameLink.attributes['href'] ?? '');
    if (m != null) item['uid'] = m.group(1);
  }

  // 备注（仅自己的收听页有：h6 内 span[id^=followbkame_]）
  final noteEl = li.querySelector('h6 span[id^="followbkame_"]');
  if (noteEl != null) {
    final note = sanitizeText(noteEl.text);
    if (note.isNotEmpty) item['note'] = note;
  }

  // <p> 两个：无 class 的为“最近动作”，class 含 ptm 的为统计（来自/听众/收听）
  for (final p in li.querySelectorAll('p')) {
    final text = sanitizeText(p.text);
    if (p.classes.contains('ptm')) {
      // 统计：来自: X / 听众: N人 / 收听: N人
      final fromMatch = RegExp(r'来自:\s*([^\|]*?)\s*(?:听众:|$)').firstMatch(text);
      if (fromMatch != null) {
        final from = fromMatch.group(1)?.trim();
        if (from != null && from.isNotEmpty) item['from'] = from;
      }
      final follower = p.querySelector('a[href*="do=follower"] strong');
      if (follower != null) {
        item['followerCount'] = follower.text.replaceAll(RegExp(r'\D'), '');
      }
      final following = p.querySelector('a[href*="do=following"] strong');
      if (following != null) {
        item['followingCount'] = following.text.replaceAll(RegExp(r'\D'), '');
      }
    } else if (text.isNotEmpty) {
      // 最近动作：去掉前缀“最近动作: ”
      final action = text.replaceFirst(RegExp(r'^最近动作:\s*'), '').trim();
      if (action.isNotEmpty) item['recentAction'] = action;
    }
  }

  return item;
}

/// 解析他人主页的关注状态与操作令牌。
///
/// 页面：`home.php?mod=space&uid={uid}&do=profile`（他人视角，PC 模板）。
///
/// ## 按钮形态（实测 bbs.binmt.cc）
///
/// ```html
/// <!-- 未收听 -->
/// <a href="home.php?mod=spacecp&amp;ac=follow&amp;op=add&amp;hash=639ec483&amp;fuid=14088&amp;mobile=2"
///    id="a_followmod_14088" class="flw_btn_fo">收听TA</a>
/// <!-- 已收听 -->
/// <a href="home.php?mod=spacecp&amp;ac=follow&amp;op=del&amp;hash=639ec483&amp;fuid=14088"
///    id="a_followmod_14088" class="flw_btn_unfo">取消收听</a>
/// ```
///
/// 早期版本只认 `#ct a.flw_btn_*`，一旦模板把按钮渲染在 `#ct` 之外（或
/// 类名/id 有差异）就解析不到，`isFollowing` 恒为 null，UI 便**整块隐藏**
/// 关注入口——表现为「用户主页没有关注按钮」。现在的策略：
///
/// 1. 先在 `#ct` 内找 `a.flw_btn_unfo` / `a.flw_btn_fo`（原有形态）；
/// 2. 再退到全文档按 `a[id^="a_followmod_"]`（Discuz 标准 id）找；
/// 3. 最后按 `href` 含 `ac=follow` 且 `op=add|del` 找（模板改类名也能命中）。
///
/// 关注态优先看 `href` 的 `op=`（比 class 更可靠）：`op=del` → 已收听，
/// `op=add` → 未收听；两者都没有时才回退到 class。
///
/// 返回：
/// - `isFollowing`：当前是否已关注（true / false / null=页面确实没有关注按钮，
///   例如看自己、游客、或站点关闭了收听功能）
/// - `followHash`：`hash=` 后的值（= 页面 FORMHASH）
/// - `formhash`：`input[name=formhash]` 的值（写操作必填）
/// - `fuid`：从 href 的 `fuid=` 解析出的目标 uid；解析不到时由调用方用页面 uid 兜底
/// - `canFollow`：是否解析到了可用的关注入口（= `fuid` 非空且 `formhash` 非空）
Map<String, dynamic> parseFollowStatus(String body, int statusCode) {
  final pre = prepareDoc(body, statusCode);
  if (pre.error != null) return pre.error!;
  final doc = pre.doc!;

  // 页面全局令牌
  final formhashInput = doc.querySelector('input[name="formhash"]');
  final formhash = formhashInput?.attributes['value'] ?? '';

  // ---- 定位关注按钮（三级回退）----
  dom.Element? btn = doc.querySelector('#ct a.flw_btn_unfo') ??
      doc.querySelector('#ct a.flw_btn_fo');
  btn ??= doc.querySelector('a[id^="a_followmod_"]');
  btn ??= doc.querySelector('a[id^="followmod_"]');
  if (btn == null) {
    for (final a in doc.querySelectorAll('a[href*="ac=follow"]')) {
      final h = a.attributes['href'] ?? '';
      if (h.contains('op=add') || h.contains('op=del')) {
        btn = a;
        break;
      }
    }
  }

  bool? isFollowing;
  String followHash = '';
  String fuid = '';
  if (btn != null) {
    final href = btn.attributes['href'] ?? '';
    // 关注态：href 的 op= 最可靠（按钮 class 可能被模板改掉）
    if (href.contains('op=del')) {
      isFollowing = true;
    } else if (href.contains('op=add')) {
      isFollowing = false;
    } else {
      isFollowing = btn.classes.contains('flw_btn_unfo');
    }
    // hash= 后的十六进制串（Discuz 里它就等于 FORMHASH）
    final hashMatch = RegExp(r'[?&]hash=([0-9a-zA-Z]+)').firstMatch(href);
    if (hashMatch != null) followHash = hashMatch.group(1)!;
    // fuid= 目标用户 uid（写操作必需）
    final fuidMatch = RegExp(r'[?&]fuid=(\d+)').firstMatch(href);
    if (fuidMatch != null) fuid = fuidMatch.group(1)!;
  }

  // href 里没有 hash 时用 formhash 兜底：源码判据就是 hash == FORMHASH
  if (followHash.isEmpty) followHash = formhash;

  return {
    'success': true,
    'isFollowing': isFollowing,
    'followHash': followHash,
    'formhash': formhash,
    'fuid': fuid,
    'canFollow': fuid.isNotEmpty && formhash.isNotEmpty,
  };
}
