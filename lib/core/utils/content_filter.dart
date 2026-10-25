/// 内容过滤工具（功能①②共用）
///
/// - 板块过滤（功能①）：黑名单优先（默认 `modeBlock = true`，命中的板块
///   隐藏），可切换白名单（只有命中的板块才显示）；名单为空时不生效。
/// - 帖子标题关键词过滤（功能①）：简单子串包含匹配（大小写不敏感），
///   不引入正则，避免用户输入非法正则导致运行时崩溃。
/// - 评论关键词过滤（功能②）：对齐 mtlite-tweaks 的「评论屏蔽」语义——
///   每行一条屏蔽词，合法正则按正则匹配（包含语义、大小写不敏感），
///   非法正则退化为子串匹配；正文（剥引用、去空白）超过 10 字不屏蔽；
///   纯 ASCII 可打印且不含 `.` 的短评直接屏蔽（灌水特征）；楼主帖与
///   「回复别人」的楼层豁免（引用内容容易误伤）；内置词表随版本号
///   预填一次（见 [kCommentBlockWordsVersion]），用户可自由删改，
///   升级时旧内置行被替换、自定义词保留。
library;
import 'package:mtbbs/models/thread_detail.dart';
import 'package:mtbbs/models/thread_item.dart';

// ==================== 内置评论屏蔽词（对齐 mtlite-tweaks 版本 3） ====================

/// 内置评论屏蔽词表。
///
/// 首次运行/版本升级时合并为一条 `|` 正则追加进「评论屏蔽词」设置；
/// 用户删掉或改掉后，只要版本号不变就不会再写回。
const List<String> kCommentBlockWords = [
  '康康看下', '看一下', '看一看', '看下隐藏', '看看隐藏', '看看内容', '看隐藏',
  '看着吧好东西', '好东西', '试用一下', '超级喜欢',
  '感谢分享', '感谢大佬分享', '感谢楼主', '感谢感谢', '谢谢谢谢', '谢谢分享',
  '学习学习', '学习下', '学习一下', '膜拜大佬', '大佬牛批', '牛批牛批',
  '厉害厉害', '太给力了', '恭喜恭喜', '支持下', '支持一下',
  '论坛有你更美好', '论坛有你更精彩', '试试看吧', '太棒了', '太强了', '太好了',
  '太强啦', '太棒啦', '拿走了', '快快', '大佬牛逼', '大佬厉害', '厉害了',
  '瞅瞅', '学习', '看看', '试试', '优秀', '谢谢', '大佬', '测试', '好的',
  '给力', '来了', '感谢', 'look', '看下', '不错', '牛', '厉害', '路过',
];

/// 内置词表版本号（对齐 mtlite「屏蔽词预置」）。
///
/// 修改 [kCommentBlockWords] 时必须同步 +1；升级时据此把旧内置正则
/// 替换为新表，用户自定义词保留。
const String kCommentBlockWordsVersion = '3';

/// 内置词表合并后的单条正则（`|` 表示或，含匹配而非完全匹配）。
String get kCommentBlockWordsRegex => kCommentBlockWords.join('|');
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

/// 对评论（楼层）做关键词过滤：命中即隐藏整层楼。
///
/// - [enabled] 为「评论屏蔽」总开关（默认开）；关闭或词表为空时原样返回；
/// - 楼主帖（`isOp`）不参与屏蔽；
/// - 「回复别人」的楼层（带非提示类引用块）不屏蔽，避免引用内容误伤；
/// - 匹配正文（剥引用、去空白），规则见 [shouldBlockComment]。
List<PostItem> filterPostItems(
  List<PostItem> posts,
  List<String> keywords, {
  bool enabled = true,
}) {
  if (!enabled || keywords.isEmpty) return posts;
  final matchers = buildCommentMatchers(keywords);
  return posts.where((p) {
    if (p.isOp) return true; // 楼主帖不参与屏蔽
    final code = p.bbcode;
    if (isReplyToOther(code)) return true; // 回复别人的楼层不屏蔽
    final t = commentBodyText(code);
    if (t.isEmpty) return true;
    return !shouldBlockComment(t, matchers);
  }).toList();
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
        boards:
            ((j['boards'] as List<dynamic>?) ?? const [])
                .map((e) => e.toString())
                .toList(),
        keywords:
            ((j['keywords'] as List<dynamic>?) ?? const [])
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