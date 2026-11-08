/// 内容过滤工具（功能①②共用）
///
/// - 板块过滤（功能①）：黑名单优先（默认 `modeBlock = true`，命中的板块
///   隐藏），可切换白名单（只有命中的板块才显示）；名单为空时不生效。
/// - 帖子标题关键词过滤（功能①）：简单子串包含匹配（大小写不敏感），
///   不引入正则，避免用户输入非法正则导致运行时崩溃。
/// - 评论屏蔽（功能②）：对齐 mtlite-tweaks 的「评论屏蔽」语义——
///   每行一条屏蔽词，合法正则按正则匹配（包含语义、大小写不敏感），
///   非法正则退化为子串匹配；正文（剥引用、去空白）超过 10 字不屏蔽；
///   纯 ASCII 可打印且不含 `.` 的短评直接屏蔽（灌水特征）；楼主帖与
///   「回复别人」的楼层豁免（引用内容容易误伤）。
///
/// 屏蔽词**不再内置默认词表**：`keywords` 完全由用户维护，缺省为空 =
/// 不屏蔽任何评论。触发范围由 [CommentFilterConfig] 表达，支持两种触发
/// 方式（都不设置时屏蔽词全局生效，与旧行为一致）：
/// - 「仅隐藏贴触发」：只有当前主题是隐藏贴（回复可见）时才应用屏蔽词；
/// - 「按板块触发」：只有当前主题所属板块命中名单时才应用屏蔽词
///   （黑名单 = 名单内生效，白名单 = 名单外生效，UI 与板块屏蔽同源）。
library;

import 'package:mtbbs/models/thread_detail.dart';
import 'package:mtbbs/models/thread_item.dart';

// ==================== 隐藏贴判据 ====================

/// 主帖「回复可见」占位：未回复时 Discuz 只下发 `.locked`（🔒 提示），
/// 回复后才会换成正文（见 `lib/core/parser/post_parser.dart`）。
///
/// 与「回复后重取主帖」共用同一份正则（见 `thread_view_actions.dart`），
/// 避免两处判据漂移。
final RegExp kLockedAppdataRe = RegExp(
  r'\[appdata\]\{"type":"locked".*?\}\[/appdata\]',
);

/// BBCode 隐藏内容块（回复后可见的正文段落，见 `bbcode_blocks.dart`）
final RegExp _hideBlockRe = RegExp(
  r'\[hide(?:=[^\]]*)?\][\s\S]*?\[/hide\]',
  caseSensitive: false,
);

/// 该主题是否为「隐藏贴」——回复可见类主题。
///
/// 两种形态都算：未回复时的 `[appdata] locked` 占位，以及已解锁但正文里
/// 仍保留的 `[hide]...[/hide]` 块。两者都是解析层已产出的稳定标记，
/// 不依赖额外的网页请求。
bool isHiddenThreadBbcode(String bbcode) =>
    kLockedAppdataRe.hasMatch(bbcode) || _hideBlockRe.hasMatch(bbcode);

// ==================== 功能①：板块 / 标题过滤 ====================

/// 判断 [title] 是否命中关键词名单。
///
/// 与评论屏蔽同款语义：每条关键词先按正则编译（包含匹配、大小写不
/// 敏感），非法正则自动退化为子串匹配，不会因用户输入崩溃。
bool matchKeyword(String title, List<String> keywords) {
  if (keywords.isEmpty) return false;
  for (final m in buildCommentMatchers(keywords)) {
    if (m.matches(title)) return true;
  }
  return false;
}

/// 判断 [boardName] 是否落在板块名单内（按黑/白名单语义决定去留）
///
/// 返回 `true` 表示该条目应被**过滤掉（隐藏）**：
/// - 黑名单模式（`modeBlock = true`）：名单内命中 → 隐藏；
/// - 白名单模式：名单非空且未命中 → 隐藏。
bool filterByBoard(String boardName, List<String> boards, bool modeBlock) {
  if (boards.isEmpty) return false;
  final hit = boards.contains(boardName);
  return modeBlock ? hit : !hit;
}

/// 对帖子列表做板块 + 关键词过滤，返回过滤后的列表
List<ThreadItem> filterThreadItems(
  List<ThreadItem> items,
  List<String> boards,
  bool modeBlock,
  List<String> keywords,
) {
  if (boards.isEmpty && keywords.isEmpty) return items;
  return items
      .where(
        (it) =>
            !filterByBoard(it.boardName ?? '', boards, modeBlock) &&
            !matchKeyword(it.title ?? '', keywords),
      )
      .toList();
}

/// 帖子列表投影过滤器的闭包工厂（功能①：板块 + 标题关键词过滤）。
///
/// 给 ThreadGrid.itemFilter 直接使用；从 [SettingsProvider] 读名单，设置
/// 变化时由 provider 的 notifyListeners 驱动页面重建，过滤器随之生效。
List<ThreadItem> Function(List<ThreadItem>) threadItemFilter(
  List<String> boards,
  bool modeBlock,
  List<String> keywords,
) {
  if (boards.isEmpty && keywords.isEmpty) return (items) => items;
  return (items) => filterThreadItems(items, boards, modeBlock, keywords);
}

// ==================== 功能②：评论屏蔽（对齐 mtlite 语义） ====================

/// BBCode 引用块（非贪婪匹配单层 `[quote]...[/quote]`）
final RegExp _quoteRe = RegExp(
  r'\[quote\][\s\S]*?\[/quote\]',
  caseSensitive: false,
);

/// 「回复可见」类提示 —— 引用块里是这类提示时，该楼不算「回复别人」
/// （对齐 mtlite 原版排除正则：`/查看本帖隐藏|回复可见|回复后可见|隐藏内容/`）
final RegExp _hideHintRe = RegExp(r'查看本帖隐藏|回复可见|回复后可见|隐藏内容');

/// 全 ASCII 可打印字符（\x20-\x7E，不含中文等非 ASCII 字符）
final RegExp _printableAsciiRe = RegExp(r'^[\x20-\x7E]+$');

/// 屏蔽词 / 关键词匹配器：合法正则按正则匹配（包含语义、大小写不敏感），
/// 非法正则自动退化为子串匹配，避免用户输入导致运行时崩溃。
/// （评论屏蔽词与帖子标题关键词共用同一套匹配语义）
class CommentWordMatcher {
  final String raw;
  final RegExp? _re;

  CommentWordMatcher(this.raw) : _re = _tryCompile(raw);

  static RegExp? _tryCompile(String w) {
    try {
      return RegExp(w, caseSensitive: false);
    } on FormatException {
      return null;
    }
  }

  bool matches(String text) {
    final re = _re;
    if (re != null) {
      try {
        return re.hasMatch(text);
      } catch (_) {
        return text.contains(raw);
      }
    }
    return text.contains(raw);
  }
}

/// 词表编译缓存（避免每次 build 重复编译正则）
List<CommentWordMatcher>? _matcherCache;
String? _matcherCacheKey;

/// 把屏蔽词表编译成匹配器列表（带内容缓存，词表不变时直接复用）
List<CommentWordMatcher> buildCommentMatchers(List<String> keywords) {
  final key = keywords.join('\u0000');
  if (_matcherCacheKey == key && _matcherCache != null) {
    return _matcherCache!;
  }
  final ms = <CommentWordMatcher>[];
  for (final w in keywords) {
    final t = w.trim();
    if (t.isNotEmpty) ms.add(CommentWordMatcher(t));
  }
  _matcherCache = ms;
  _matcherCacheKey = key;
  return ms;
}

/// 楼层正文（剥掉引用块后折叠空白）—— 对齐 mtlite `bodyText()`
String commentBodyText(String bbcode) {
  final t = bbcode.replaceAll(_quoteRe, '');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 该楼层是否「回复别人」：带引用块，且引用内容不是「回复可见」类提示。
///
/// 回复别人的楼层不参与屏蔽（引用内容容易误伤）——对齐 mtlite
/// `isReplyToOther()`。
bool isReplyToOther(String bbcode) {
  for (final m in _quoteRe.allMatches(bbcode)) {
    final qt = m.group(0) ?? '';
    if (qt.isEmpty) continue;
    if (_hideHintRe.hasMatch(qt)) continue; // 引用里是提示，不算回复
    return true;
  }
  return false;
}

/// 单条评论是否屏蔽 —— 对齐 mtlite `blockReason()`：
///
/// 1. 去空白后为空 → 不屏蔽；
/// 2. 去空白后超过 10 字 → 不屏蔽（水贴都是短句，长回复不受影响）；
/// 3. 纯 ASCII 可打印且不含 `.` → 屏蔽（灌水特征；含 `.` 可能是链接）；
/// 4. 命中任一屏蔽词（正则或子串）。
bool shouldBlockComment(String text, List<CommentWordMatcher> matchers) {
  final t = text.replaceAll(RegExp(r'\s+'), '');
  if (t.isEmpty) return false;
  if (t.length > 10) return false;
  if (_printableAsciiRe.hasMatch(t) && !t.contains('.')) return true;
  for (final m in matchers) {
    if (m.matches(t)) return true;
  }
  return false;
}

// ==================== 功能②：屏蔽词触发范围 ====================

/// 评论屏蔽配置：开关 + 两种触发方式 + 屏蔽词。
///
/// 与 [ThreadScopeFilter] 对称（同款 `enabled` / `modeBlock` / `boards` /
/// `keywords` 语义，另加 `onlyHiddenThread`），持久化为 JSON。
///
/// **没有内置默认词表**：`keywords` 完全由用户维护，为空即不过滤。
class CommentFilterConfig {
  /// 评论屏蔽总开关（关闭 = 评论完全不过滤）
  final bool enabled;

  /// 触发方式①：只有「隐藏贴」（回复可见类主题）才应用屏蔽词
  final bool onlyHiddenThread;

  /// 触发方式②的名单模式：true = 黑名单（名单内板块才应用），
  /// false = 白名单（名单内板块不应用，其余板块应用）
  final bool modeBlock;

  /// 触发方式②的板块名单（空 = 不按板块触发）
  final List<String> boards;

  /// 屏蔽词（每行一条，支持正则；空 = 不屏蔽任何评论）
  final List<String> keywords;

  /// 命中屏蔽后是否在「消息 → 我的帖子」的回帖预览处保留一条提示占位。
  ///
  /// 默认 **false**：那里原本会渲染一整行「回帖内容已屏蔽（命中评论屏蔽词）」，
  /// 在卡片里视觉上就是一个突兀的大框，比直接不显示更打扰。想保留提示
  /// （至少知道「这里本来有内容」）的用户可以在评论屏蔽设置里打开。
  ///
  /// 只影响这一处占位提示；帖子详情页的楼层屏蔽始终是整层隐藏、不留占位。
  final bool showBlockedPlaceholder;

  const CommentFilterConfig({
    this.enabled = true,
    this.onlyHiddenThread = false,
    this.modeBlock = true,
    this.boards = const [],
    this.keywords = const [],
    this.showBlockedPlaceholder = false,
  });

  /// 两种触发方式都没设置（此时屏蔽词全局生效，与旧行为一致）
  bool get isGlobalTrigger => !onlyHiddenThread && boards.isEmpty;

  /// 去掉触发方式限制（屏蔽词按「全局生效」语义判定）。
  ///
  /// 给拿不到主题上下文的调用点用（如「消息 → 我的帖子」的回帖预览：那里
  /// 只有单条 bbcode，既无板块名也无隐藏贴标记）。触发方式是为浏览帖子时
  /// 的评论区做精细控制用的，在这些位置无法判定，若沿用会被判为「无法
  /// 命中」而导致该处永久不过滤——与「消息里也过滤」的需求相悖。
  CommentFilterConfig withoutTrigger() =>
      copyWith(onlyHiddenThread: false, boards: const []);

  /// 没有屏蔽词 → 什么都不会被屏蔽（供「屏蔽补页」判断用）
  bool get isNoop => keywords.isEmpty;

  CommentFilterConfig copyWith({
    bool? enabled,
    bool? onlyHiddenThread,
    bool? modeBlock,
    List<String>? boards,
    List<String>? keywords,
    bool? showBlockedPlaceholder,
  }) => CommentFilterConfig(
    enabled: enabled ?? this.enabled,
    onlyHiddenThread: onlyHiddenThread ?? this.onlyHiddenThread,
    modeBlock: modeBlock ?? this.modeBlock,
    boards: boards ?? this.boards,
    keywords: keywords ?? this.keywords,
    showBlockedPlaceholder:
        showBlockedPlaceholder ?? this.showBlockedPlaceholder,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'onlyHiddenThread': onlyHiddenThread,
    'modeBlock': modeBlock,
    'boards': boards,
    'keywords': keywords,
    'showBlockedPlaceholder': showBlockedPlaceholder,
  };

  factory CommentFilterConfig.fromJson(Map<String, dynamic> j) =>
      CommentFilterConfig(
        enabled: (j['enabled'] as bool?) ?? true,
        onlyHiddenThread: (j['onlyHiddenThread'] as bool?) ?? false,
        modeBlock: (j['modeBlock'] as bool?) ?? true,
        boards: ((j['boards'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        keywords: ((j['keywords'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        showBlockedPlaceholder:
            (j['showBlockedPlaceholder'] as bool?) ?? false,
      );
}

/// 旧版内置词表合并成的那条正则的前缀。
///
/// 旧版会把整份内置词表压成一条 `康康看下|…` 正则预填进屏蔽词，用户升级后
/// 必须剔除它 —— 否则表现为「内置词没删掉」。
const String kLegacyBuiltinKeywordPrefix = '康康看下|';

/// 把旧版裸词表（`commentFilterKeywords`）继承进新版配置的屏蔽词。
///
/// 纯函数，便于测试；实际读写在 `SettingsProvider.load` 里。
///
/// 规则：
/// 1. 逐条 trim，丢空串；
/// 2. 剔除旧版内置词（以 [kLegacyBuiltinKeywordPrefix] 开头的那条）；
/// 3. 与 [current] 去重合并，**旧词在前**（旧词更早建立，用户对顺序有记忆），
///    已在新配置里的同名词不会重复出现。
///
/// 传空 [legacy] 时原样返回 [current]（幂等：旧键已被删掉时不会改变现状）。
List<String> mergeLegacyKeywords(List<String> legacy, List<String> current) {
  final cleaned = legacy
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith(kLegacyBuiltinKeywordPrefix))
      .toList();
  if (cleaned.isEmpty) return List<String>.of(current);

  final merged = <String>[];
  final seen = <String>{};
  for (final w in [...cleaned, ...current]) {
    if (seen.add(w)) merged.add(w);
  }
  return merged;
}

/// 屏蔽词当前是否应作用于「这个主题」。
///
/// - 总开关关闭 → false；
/// - 两种触发方式都没设置 → true（全局生效，旧行为）；
/// - 设置了触发方式 → 任一条件命中即生效（「仅隐藏贴」命中隐藏贴、
///   「按板块」命中 [filterByBoard] 的板块）；
/// - 触发条件已设置但调用方拿不到对应信息（如消息预览只有单条正文，
///   既无板块也无隐藏贴标记）→ 该条件视为无法命中，保守不屏蔽。
bool commentFilterApplies(
  CommentFilterConfig f, {
  String? boardName,
  bool? isHiddenThread,
}) {
  if (!f.enabled) return false;
  if (f.isGlobalTrigger) return true;
  if (f.onlyHiddenThread && isHiddenThread == true) return true;
  if (f.boards.isNotEmpty &&
      boardName != null &&
      filterByBoard(boardName, f.boards, f.modeBlock)) {
    return true;
  }
  return false;
}

/// 单条评论正文是否屏蔽（供拿不到 [PostItem] 的调用点使用，如消息预览）。
///
/// 判定链与 [filterPostItems] 一致，只是入口是裸 bbcode：
/// 触发范围 → 「回复别人」豁免 → 正文为空豁免 → [shouldBlockComment]。
bool shouldBlockCommentBbcode(
  String bbcode,
  CommentFilterConfig f, {
  String? boardName,
  bool? isHiddenThread,
}) {
  if (!commentFilterApplies(
    f,
    boardName: boardName,
    isHiddenThread: isHiddenThread,
  )) {
    return false;
  }
  if (f.keywords.isEmpty) return false;
  if (isReplyToOther(bbcode)) return false; // 回复别人的楼层不屏蔽
  final t = commentBodyText(bbcode);
  if (t.isEmpty) return false;
  return shouldBlockComment(t, buildCommentMatchers(f.keywords));
}

/// 「消息 → 我的帖子」的一条提醒是否应**整条隐藏**（连卡片一起移除）。
///
/// 该列表的每条提醒就是「某人回复了你的帖子」+ 回帖预览。命中屏蔽词时只把
/// 正文换成提示、卡片照旧留着，用户看到的是「消息还在」，等于屏蔽没生效。
/// 所以默认连卡片一起移除；只有用户显式打开「命中后保留提示」
/// （[CommentFilterConfig.showBlockedPlaceholder]）才保留整卡 + 一行提示。
///
/// [bbcode] 为回帖预览正文；null（还没拉到 / 拉取失败）或为空时**不隐藏**：
/// 无从判定就不动，等预览回来再决定，避免「一进页面整片消失、随后又冒出来」。
///
/// 触发方式不参与（[CommentFilterConfig.withoutTrigger]）：这里只有 tid/pid，
/// 拿不到板块名与隐藏贴标记，沿用会让该列表在设置触发方式后永久不过滤。
bool isMypostEntryBlocked(String? bbcode, CommentFilterConfig f) {
  if (bbcode == null || bbcode.isEmpty) return false;
  return shouldBlockCommentBbcode(bbcode, f.withoutTrigger());
}

/// 是否把整条提醒从列表里移除 = 命中屏蔽词 且 用户没开「命中后保留提示」。
bool shouldHideMypostEntry(String? bbcode, CommentFilterConfig f) =>
    !f.showBlockedPlaceholder && isMypostEntryBlocked(bbcode, f);

/// 对评论（楼层）做屏蔽词过滤：命中即隐藏整层楼。
///
/// - [f] 为评论屏蔽配置（开关 + 触发方式 + 屏蔽词）；
/// - [boardName] / [isHiddenThread] 为当前主题上下文，供触发方式判定；
/// - 楼主帖（`isOp`）不参与屏蔽；
/// - 「回复别人」的楼层（带非提示类引用块）不屏蔽，避免引用内容误伤；
/// - 匹配正文（剥引用、去空白），规则见 [shouldBlockComment]。
List<PostItem> filterPostItems(
  List<PostItem> posts,
  CommentFilterConfig f, {
  String? boardName,
  bool? isHiddenThread,
}) {
  if (!commentFilterApplies(
    f,
    boardName: boardName,
    isHiddenThread: isHiddenThread,
  )) {
    return posts;
  }
  if (f.keywords.isEmpty) return posts;
  final matchers = buildCommentMatchers(f.keywords);
  return posts.where((p) {
    if (p.isOp) return true; // 楼主帖不参与屏蔽
    final code = p.bbcode;
    if (isReplyToOther(code)) return true; // 回复别人的楼层不屏蔽
    final t = commentBodyText(code);
    if (t.isEmpty) return true;
    return !shouldBlockComment(t, matchers);
  }).toList();
}

// ==================== 只看楼主 ====================

/// 只保留楼主（主题作者）发的楼层。
///
/// 用于帖子详情页「评论区」的「只看楼主」筛选。
///
/// 与 `authorid` 服务端筛选的区别：服务端筛选会让返回结果里**没有主帖**
/// （`authorid` 非空时解析层把第一楼也当评论），页面上的主帖会整块消失；
/// 这里只筛评论楼层，主帖照常显示，且不需要额外请求。
///
/// [opUid] 为空（主帖未加载 / 解析不到作者 uid）时原样返回，不做筛选——
/// 否则会因 `p.uid == ''` 匹配不到任何楼层而显示空白。
List<PostItem> filterOnlyOpAuthor(List<PostItem> posts, String opUid) {
  if (opUid.isEmpty) return posts;
  return posts.where((p) => p.isOp || p.uid == opUid).toList();
}

// ==================== 功能①扩展：按列表点的独立屏蔽配置 ====================

/// 帖子列表点标识：社区页（含标签页）
const String kThreadScopeCommunity = 'community';

/// 帖子列表点标识：导读页
const String kThreadScopeGuide = 'guide';

/// 帖子列表点标识：站内搜索结果页
const String kThreadScopeSearch = 'search';

/// 帖子列表点标识：个人主页主题/回帖列表
const String kThreadScopeUser = 'user';

/// 单个列表点的屏蔽配置：开关 + 黑/白名单模式 + 板块名单 + 标题关键词。
///
/// 持久化为 JSON（key = 列表点标识）；首次升级时由旧全局配置
/// （threadFilterModeBlock/Boards/Keywords）自动迁移为各点初始值。
class ThreadScopeFilter {
  /// 该列表点的屏蔽总开关（关闭 = 该列表完全不过滤）
  final bool enabled;

  /// 板块名单模式：true = 黑名单（命中隐藏），false = 白名单（仅命中显示）
  final bool modeBlock;
  final List<String> boards;
  final List<String> keywords;

  const ThreadScopeFilter({
    this.enabled = true,
    this.modeBlock = true,
    this.boards = const [],
    this.keywords = const [],
  });

  /// 名单全空 → 实际不过滤（与旧全局配置「空 = 不过滤」语义一致）
  bool get isNoop => boards.isEmpty && keywords.isEmpty;

  ThreadScopeFilter copyWith({
    bool? enabled,
    bool? modeBlock,
    List<String>? boards,
    List<String>? keywords,
  }) => ThreadScopeFilter(
    enabled: enabled ?? this.enabled,
    modeBlock: modeBlock ?? this.modeBlock,
    boards: boards ?? this.boards,
    keywords: keywords ?? this.keywords,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'modeBlock': modeBlock,
    'boards': boards,
    'keywords': keywords,
  };

  factory ThreadScopeFilter.fromJson(Map<String, dynamic> j) =>
      ThreadScopeFilter(
        enabled: (j['enabled'] as bool?) ?? true,
        modeBlock: (j['modeBlock'] as bool?) ?? true,
        boards: ((j['boards'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        keywords: ((j['keywords'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// 按列表点过滤帖子列表：开关关闭或名单全空时原样返回
List<ThreadItem> filterThreadItemsForScope(
  List<ThreadItem> items,
  ThreadScopeFilter f,
) {
  if (!f.enabled || f.isNoop) return items;
  return filterThreadItems(items, f.boards, f.modeBlock, f.keywords);
}
