import 'package:flutter/material.dart';
import 'package:mtbbs/config/notice_config.dart';
import 'package:mtbbs/config/toolbar_config.dart';
import 'package:mtbbs/core/app/avatar_url.dart';
import 'package:mtbbs/core/app/default_config.dart';
import 'package:mtbbs/core/utils/shortcut_helper.dart';
import 'package:mtbbs/models/managed_item.dart';
import 'package:mtbbs/models/settings/settings_defaults.dart';

/// 读取一个布尔设置，并区分「用户关掉了」与「这个开关是本次更新才新增的」。
///
/// 背景：以前的 `map['x'] as bool? ?? d.x` 把所有缺失键都当成「用代码默认值」。
/// 于是「激进跟随更新」没法实现——它需要知道某个键到底是**用户存的**还是
/// **压根没存过**（没存过 = 老版本没有这个功能 = 这是新增开关）。
///
/// 三个分支：
/// - 键存在 → 用户的选择，原样返回（旧开关永远不会被激进模式改动）；
/// - 键缺失 + 激进模式开 → 新功能，默认开 `true`；
/// - 键缺失 + 激进模式关 → 新功能，用代码默认值 [fallback]。
///
/// 注意 `map` 里存的是 JSON，键可能来自更老的版本，值类型不可信，
/// 因此只接受真正的 `bool`，其它类型按「没存过」处理。
bool boolOrNewFeature(
  Map<String, dynamic> map,
  String key, {
  required bool fallback,
  required bool aggressive,
}) {
  final raw = map[key];
  if (raw is bool) return raw;
  return aggressive || fallback;
}

/// 应用设置（与站点、账号无关）
///
/// 持久化为一份 JSON 文档，见 `SettingsRepository`。
class AppSettings {
  final int schemaVersion;
  final String currentSiteHost;

  final AppearanceSettings appearance;
  final StartupSettings startup;
  final ReadingSettings reading;
  final EditorSettings editor;
  final StorageSettings storage;
  final NoticeSettings notice;
  final ShareSettings share;
  final HistorySettings history;
  final AdvancedSettings advanced;

  const AppSettings({
    this.schemaVersion = 1,
    this.currentSiteHost = '',
    required this.appearance,
    required this.startup,
    required this.reading,
    required this.editor,
    required this.storage,
    required this.notice,
    required this.share,
    required this.history,
    required this.advanced,
  });

  static AppSettings defaults() => AppSettings(
    appearance: AppearanceSettings.defaults(),
    startup: StartupSettings.defaults(),
    reading: ReadingSettings.defaults(),
    editor: EditorSettings.defaults(),
    storage: StorageSettings.defaults(),
    notice: NoticeSettings.defaults(),
    share: ShareSettings.defaults(),
    history: HistorySettings.defaults(),
    advanced: AdvancedSettings.defaults(),
  );

  /// 局部替换（备份项只改一两个子文档时用，避免手抄十个子对象）
  AppSettings copyWith({
    String? currentSiteHost,
    AppearanceSettings? appearance,
    StartupSettings? startup,
    ReadingSettings? reading,
    EditorSettings? editor,
    StorageSettings? storage,
    NoticeSettings? notice,
    ShareSettings? share,
    HistorySettings? history,
    AdvancedSettings? advanced,
  }) => AppSettings(
    schemaVersion: schemaVersion,
    currentSiteHost: currentSiteHost ?? this.currentSiteHost,
    appearance: appearance ?? this.appearance,
    startup: startup ?? this.startup,
    reading: reading ?? this.reading,
    editor: editor ?? this.editor,
    storage: storage ?? this.storage,
    notice: notice ?? this.notice,
    share: share ?? this.share,
    history: history ?? this.history,
    advanced: advanced ?? this.advanced,
  );

  Map<String, dynamic> toMap() => {
    'schemaVersion': schemaVersion,
    'currentSiteHost': currentSiteHost,
    'appearance': appearance.toMap(),
    'startup': startup.toMap(),
    'reading': reading.toMap(),
    'editor': editor.toMap(),
    'storage': storage.toMap(),
    'notice': notice.toMap(),
    'share': share.toMap(),
    'history': history.toMap(),
    'advanced': advanced.toMap(),
  };

  factory AppSettings.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic> sub(String key) =>
        (map[key] as Map?)?.cast<String, dynamic>() ?? const {};
    final advancedMap = sub('advanced');
    // 必须先算出「激进跟随更新」，再解析其它子文档：子文档的 fromMap 要用它
    // 区分「用户主动存的 false」与「这个键本次更新才出现」。
    final aggressive = advancedMap['aggressiveFollowUpdates'] == true;
    return AppSettings(
      schemaVersion: (map['schemaVersion'] as num?)?.toInt() ?? 1,
      currentSiteHost: map['currentSiteHost']?.toString() ?? '',
      appearance: AppearanceSettings.fromMap(
        sub('appearance'),
        aggressive: aggressive,
      ),
      startup: StartupSettings.fromMap(sub('startup'), aggressive: aggressive),
      reading: ReadingSettings.fromMap(sub('reading'), aggressive: aggressive),
      editor: EditorSettings.fromMap(sub('editor'), aggressive: aggressive),
      storage: StorageSettings.fromMap(sub('storage'), aggressive: aggressive),
      notice: NoticeSettings.fromMap(sub('notice'), aggressive: aggressive),
      share: ShareSettings.fromMap(sub('share'), aggressive: aggressive),
      history: HistorySettings.fromMap(sub('history'), aggressive: aggressive),
      advanced: AdvancedSettings.fromMap(advancedMap),
    );
  }
}

class AppearanceSettings {
  final String themeMode;
  final int seedColor;
  final bool pureBlackTheme;
  final bool showAvatars;
  final String avatarSizeMode;
  final int maxImageWidth;

  const AppearanceSettings({
    required this.themeMode,
    required this.seedColor,
    required this.pureBlackTheme,
    required this.showAvatars,
    required this.avatarSizeMode,
    required this.maxImageWidth,
  });

  factory AppearanceSettings.defaults() => const AppearanceSettings(
    themeMode: 'system',
    seedColor: 0xFF9E9E9E,
    pureBlackTheme: false,
    showAvatars: true,
    avatarSizeMode: 'middle',
    maxImageWidth: 600,
  );

  ThemeMode get themeModeValue => ThemeMode.values.firstWhere(
    (m) => m.name == themeMode,
    orElse: () => ThemeMode.system,
  );

  Color get seedColorValue => Color(seedColor);

  AvatarSizeMode get avatarSizeModeValue =>
      AvatarSizeMode.fromValue(avatarSizeMode);

  Map<String, dynamic> toMap() => {
    'themeMode': themeMode,
    'seedColor': seedColor,
    'pureBlackTheme': pureBlackTheme,
    'showAvatars': showAvatars,
    'avatarSizeMode': avatarSizeMode,
    'maxImageWidth': maxImageWidth,
  };

  factory AppearanceSettings.fromMap(
    Map<String, dynamic> map, {
    bool aggressive = false,
  }) {
    final d = AppearanceSettings.defaults();
    return AppearanceSettings(
      themeMode: map['themeMode']?.toString() ?? d.themeMode,
      seedColor: (map['seedColor'] as num?)?.toInt() ?? d.seedColor,
      pureBlackTheme: boolOrNewFeature(
        map,
        'pureBlackTheme',
        fallback: d.pureBlackTheme,
        aggressive: aggressive,
      ),
      showAvatars: boolOrNewFeature(
        map,
        'showAvatars',
        fallback: d.showAvatars,
        aggressive: aggressive,
      ),
      avatarSizeMode: map['avatarSizeMode']?.toString() ?? d.avatarSizeMode,
      maxImageWidth: (map['maxImageWidth'] as num?)?.toInt() ?? d.maxImageWidth,
    );
  }
}

class StartupSettings {
  final int defaultTabIndex;
  final bool doubleBackExit;
  final List<ManagedItem> guideTabs;
  final List<ManagedItem> homeSections;
  final List<ManagedItem> noticeTabs;
  final bool autoFrequentTabs;
  final Map<String, Map<String, int>> tabUsage;

  const StartupSettings({
    required this.defaultTabIndex,
    required this.doubleBackExit,
    required this.guideTabs,
    required this.homeSections,
    required this.noticeTabs,
    required this.autoFrequentTabs,
    required this.tabUsage,
  });

  factory StartupSettings.defaults() => StartupSettings(
    defaultTabIndex: 0,
    doubleBackExit: true,
    guideTabs: defaultGuideTabs(),
    homeSections: defaultHomeSections(),
    noticeTabs: defaultNoticeTabs(),
    autoFrequentTabs: true,
    tabUsage: const {},
  );

  Map<String, dynamic> toMap() => {
    'defaultTabIndex': defaultTabIndex,
    'doubleBackExit': doubleBackExit,
    'guideTabs': guideTabs.map((e) => e.toJson()).toList(),
    'homeSections': homeSections.map((e) => e.toJson()).toList(),
    'noticeTabs': noticeTabs.map((e) => e.toJson()).toList(),
    'autoFrequentTabs': autoFrequentTabs,
    'tabUsage': tabUsage,
  };

  factory StartupSettings.fromMap(
    Map<String, dynamic> map, {
    bool aggressive = false,
  }) {
    final d = StartupSettings.defaults();
    List<ManagedItem> items(String key, List<ManagedItem> fallback) {
      final raw = map[key];
      if (raw is! List) return fallback;
      return raw
          .whereType<Map>()
          .map((e) => ManagedItem.fromJson(e.cast<String, dynamic>()))
          .where((e) => e.id.isNotEmpty)
          .toList();
    }

    final usage = <String, Map<String, int>>{};
    final rawUsage = map['tabUsage'];
    if (rawUsage is Map) {
      for (final e in rawUsage.entries) {
        final inner = e.value;
        if (inner is! Map) continue;
        usage[e.key.toString()] = {
          for (final kv in inner.entries)
            kv.key.toString(): (kv.value as num).toInt(),
        };
      }
    }
    return StartupSettings(
      defaultTabIndex:
          (map['defaultTabIndex'] as num?)?.toInt() ?? d.defaultTabIndex,
      doubleBackExit: boolOrNewFeature(
        map,
        'doubleBackExit',
        fallback: d.doubleBackExit,
        aggressive: aggressive,
      ),
      guideTabs: items(
        'guideTabs',
        d.guideTabs,
      ).where((e) => kSettingsTabLabels.containsKey(e.id)).toList(),
      homeSections: items(
        'homeSections',
        d.homeSections,
      ).where((e) => homeSectionIds.contains(e.id)).toList(),
      noticeTabs: items(
        'noticeTabs',
        d.noticeTabs,
      ).where((e) => noticeTabIds.contains(e.id)).toList(),
      autoFrequentTabs: boolOrNewFeature(
        map,
        'autoFrequentTabs',
        fallback: d.autoFrequentTabs,
        aggressive: aggressive,
      ),
      tabUsage: usage,
    );
  }
}

class ReadingSettings {
  final double fontSize;
  final int codeBlockMaxLines;
  final int ratingMaxRows;
  final bool autoDetectUrls;
  final Set<String> disabledBbcodeTags;

  const ReadingSettings({
    required this.fontSize,
    required this.codeBlockMaxLines,
    required this.ratingMaxRows,
    required this.autoDetectUrls,
    required this.disabledBbcodeTags,
  });

  factory ReadingSettings.defaults() => const ReadingSettings(
    fontSize: 16,
    codeBlockMaxLines: 18,
    ratingMaxRows: 10,
    autoDetectUrls: true,
    disabledBbcodeTags: {},
  );

  Map<String, dynamic> toMap() => {
    'fontSize': fontSize,
    'codeBlockMaxLines': codeBlockMaxLines,
    'ratingMaxRows': ratingMaxRows,
    'autoDetectUrls': autoDetectUrls,
    'disabledBbcodeTags': disabledBbcodeTags.toList(),
  };

  factory ReadingSettings.fromMap(
    Map<String, dynamic> map, {
    bool aggressive = false,
  }) {
    final d = ReadingSettings.defaults();
    final tags = map['disabledBbcodeTags'];
    return ReadingSettings(
      fontSize: (map['fontSize'] as num?)?.toDouble() ?? d.fontSize,
      codeBlockMaxLines:
          (map['codeBlockMaxLines'] as num?)?.toInt() ?? d.codeBlockMaxLines,
      ratingMaxRows: (map['ratingMaxRows'] as num?)?.toInt() ?? d.ratingMaxRows,
      autoDetectUrls: boolOrNewFeature(
        map,
        'autoDetectUrls',
        fallback: d.autoDetectUrls,
        aggressive: aggressive,
      ),
      disabledBbcodeTags: tags is List
          ? tags.map((e) => e.toString()).toSet()
          : d.disabledBbcodeTags,
    );
  }
}

class EditorSettings {
  /// 悬浮窗边长可调区间（逻辑像素）。
  ///
  /// 与 `EditorFabConfig.minSize` / `maxSize` 必须一致；这里另存一份是因为
  /// model 层不应 import widgets 层（否则反向依赖）。
  static const double minEditorFabSize = 36;

  /// 悬浮窗边长上限
  static const double maxEditorFabSize = 72;

  /// 自动贴边秒数上限（0 = 不贴边）
  static const int maxEditorFabSnapSeconds = 30;

  final bool threadMiniEditor;
  final bool editorStartupCheck;
  final bool toolbarShortcutWhenHidden;
  final List<ManagedItem> quickReplies;
  final List<ManagedItem> toolbarItems;

  /// 用户自定义格式（编辑器工具栏「自定义格式」按钮弹出的一套格式）。
  /// 每项 `data['template']` 含 `${selectText}` 占位符，与模板项同构；
  /// 与工具栏项分开存，便于独立增删排序，也不受工具栏重置影响。
  final List<ManagedItem> customFormats;

  /// 用户自己的「常用格式预设」（新增自定义格式时弹窗顶部那排一键按钮）。
  ///
  /// 结构与 [customFormats] 完全同构（`data['template']` / `data['label']`），
  /// 所以同样复用 `ManagedItem`，不用另造一套模型。
  ///
  /// **首次为空时回落到内置 [defaultFormatPresets]**（见 `config/toolbar_config.dart`
  /// 的 `kBbcodePresets`）：老用户升级后仍能看到那 11 个常见写法。
  /// 一旦用户增/删/改过，就以他自己这份为准 —— 包括**删空**也算已编辑，
  /// 不会再变回内置列表（靠 `toMap` 里始终写出 `formatPresets` 键来区分）。
  final List<ManagedItem> formatPresets;

  final Map<String, String> shortcuts;
  final Map<String, String> toolbarShortcuts;
  final int minSnapshotWordCount;
  final int autoSaveInterval;
  final int maxAutoSnapshots;

  /// 编辑器悬浮窗总开关（默认关）。
  ///
  /// 打开后在界面上常驻一个圆角方形按钮（主题色），点一下进编辑器。它是**应用内**悬浮窗
  /// （Flutter Overlay，不是系统级 WindowManager 窗口），所以不会像 MCP
  /// 悬浮球那样跑出本应用；再开 [editorFabBrowserOnly] 还可以只在内置浏览器
  /// 里出现。
  final bool editorFabEnabled;

  /// 悬浮窗是否只在「内置浏览器」页面显示（默认关 = 全应用可用）。
  ///
  /// 独立于 [editorFabEnabled]：先决定「要不要这个东西」，再决定「在哪出现」。
  /// 两个开关分开的好处是临时进浏览器抄东西时不用改总开关。
  final bool editorFabBrowserOnly;

  /// 悬浮窗边长（逻辑像素，见 `EditorFabConfig`）。
  final double editorFabSize;

  /// 拖动结束后多少秒自动贴边（0 = 不自动贴边）。
  final int editorFabSnapSeconds;

  const EditorSettings({
    required this.threadMiniEditor,
    required this.editorStartupCheck,
    required this.toolbarShortcutWhenHidden,
    required this.quickReplies,
    required this.toolbarItems,
    required this.customFormats,
    required this.formatPresets,
    required this.shortcuts,
    required this.toolbarShortcuts,
    required this.minSnapshotWordCount,
    required this.autoSaveInterval,
    required this.maxAutoSnapshots,
    this.editorFabEnabled = false,
    this.editorFabBrowserOnly = false,
    this.editorFabSize = 52,
    this.editorFabSnapSeconds = 3,
  });

  factory EditorSettings.defaults() => EditorSettings(
    threadMiniEditor: true,
    editorStartupCheck: true,
    toolbarShortcutWhenHidden: true,
    quickReplies: defaultQuickReplies(),
    toolbarItems: const [],
    customFormats: const [],
    formatPresets: defaultFormatPresets(),
    shortcuts: Map.from(ShortcutHelper.defaults),
    toolbarShortcuts: defaultToolbarShortcuts(),
    minSnapshotWordCount: 10,
    autoSaveInterval: 30,
    maxAutoSnapshots: 10,
    editorFabEnabled: false,
    editorFabBrowserOnly: false,
    editorFabSize: 52,
    editorFabSnapSeconds: 3,
  );

  Map<String, dynamic> toMap() => {
    'threadMiniEditor': threadMiniEditor,
    'editorStartupCheck': editorStartupCheck,
    'toolbarShortcutWhenHidden': toolbarShortcutWhenHidden,
    'quickReplies': quickReplies.map((e) => e.toJson()).toList(),
    'toolbarItems': toolbarItems.map((e) => e.toJson()).toList(),
    'customFormats': customFormats.map((e) => e.toJson()).toList(),
    // 始终写出该键（哪怕空数组）：`fromMap` 靠「键不存在」判断是否回落内置预设，
    // 用户删空预设后必须留下 `[]`，否则内置列表会复活。
    'formatPresets': formatPresets.map((e) => e.toJson()).toList(),
    'shortcuts': shortcuts,
    'toolbarShortcuts': toolbarShortcuts,
    'minSnapshotWordCount': minSnapshotWordCount,
    'autoSaveInterval': autoSaveInterval,
    'maxAutoSnapshots': maxAutoSnapshots,
    'editorFabEnabled': editorFabEnabled,
    'editorFabBrowserOnly': editorFabBrowserOnly,
    'editorFabSize': editorFabSize,
    'editorFabSnapSeconds': editorFabSnapSeconds,
  };

  factory EditorSettings.fromMap(
    Map<String, dynamic> map, {
    bool aggressive = false,
  }) {
    final d = EditorSettings.defaults();
    List<ManagedItem> items(String key, List<ManagedItem> fallback) {
      final raw = map[key];
      if (raw is! List) return fallback;
      return raw
          .whereType<Map>()
          .map((e) => ManagedItem.fromJson(e.cast<String, dynamic>()))
          .where((e) => e.id.isNotEmpty)
          .toList();
    }

    Map<String, String> strMap(String key, Map<String, String> fallback) {
      final raw = map[key];
      if (raw is! Map) return fallback;
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }

    return EditorSettings(
      threadMiniEditor: boolOrNewFeature(
        map,
        'threadMiniEditor',
        fallback: d.threadMiniEditor,
        aggressive: aggressive,
      ),
      editorStartupCheck: boolOrNewFeature(
        map,
        'editorStartupCheck',
        fallback: d.editorStartupCheck,
        aggressive: aggressive,
      ),
      toolbarShortcutWhenHidden: boolOrNewFeature(
        map,
        'toolbarShortcutWhenHidden',
        fallback: d.toolbarShortcutWhenHidden,
        aggressive: aggressive,
      ),
      quickReplies: items('quickReplies', d.quickReplies),
      toolbarItems: items('toolbarItems', d.toolbarItems),
      customFormats: items('customFormats', d.customFormats),
      // 预设用「键是否存在」区分「从没编辑过」与「用户主动删空」：
      // 老设置文件里没有该键 → 保留 defaults() 内置的 11 个；
      // 有该键（哪怕是 `[]`）→ 严格按用户那份来，不再回落。
      formatPresets: map.containsKey('formatPresets')
          ? items('formatPresets', const [])
          : d.formatPresets,
      shortcuts: strMap('shortcuts', d.shortcuts),
      toolbarShortcuts: strMap('toolbarShortcuts', d.toolbarShortcuts),
      minSnapshotWordCount:
          (map['minSnapshotWordCount'] as num?)?.toInt() ??
          d.minSnapshotWordCount,
      autoSaveInterval:
          (map['autoSaveInterval'] as num?)?.toInt() ?? d.autoSaveInterval,
      maxAutoSnapshots:
          (map['maxAutoSnapshots'] as num?)?.toInt() ?? d.maxAutoSnapshots,
      editorFabEnabled: boolOrNewFeature(
        map,
        'editorFabEnabled',
        fallback: d.editorFabEnabled,
        aggressive: aggressive,
      ),
      editorFabBrowserOnly: boolOrNewFeature(
        map,
        'editorFabBrowserOnly',
        fallback: d.editorFabBrowserOnly,
        aggressive: aggressive,
      ),
      editorFabSize: editorFabSizeValue(map['editorFabSize'], d.editorFabSize),
      editorFabSnapSeconds: (map['editorFabSnapSeconds'] is num
          ? (map['editorFabSnapSeconds'] as num).toInt().clamp(
              0,
              maxEditorFabSnapSeconds,
            )
          : d.editorFabSnapSeconds),
    );
  }

  /// 悬浮窗边长：钳到 `EditorFabConfig` 允许的区间，越界/脏数据回默认值。
  ///
  /// 拆成静态方法是因为它要做范围校验，写在 fromMap 里会把那一段拉得很长，
  /// 而且这里没有 `import` 悬浮窗配置的必要（避免 model 层依赖 widgets 层）。
  static double editorFabSizeValue(Object? raw, double fallback) {
    if (raw is! num) return fallback;
    return raw.toDouble().clamp(minEditorFabSize, maxEditorFabSize);
  }
}

class StorageSettings {
  final int avatarCacheDays;
  final int emojiCacheDays;
  final int imageCacheDays;
  final int medalCacheDays;
  final int threadCacheDays;
  final bool threadCacheEnabled;
  final int threadCacheMaxVersions;
  final int threadCacheMaxKB;

  /// 「注入文件提供器」开关（见 docs/29）。
  ///
  /// 默认 **false**：开启后本应用私有目录（含登录 Cookie）会通过系统 SAF 暴露给
  /// 第三方文件管理器（如 MT 管理器），属于排障用途，不该默认开着。
  final bool docProviderEnabled;

  const StorageSettings({
    required this.avatarCacheDays,
    required this.emojiCacheDays,
    required this.imageCacheDays,
    required this.medalCacheDays,
    required this.threadCacheDays,
    required this.threadCacheEnabled,
    required this.threadCacheMaxVersions,
    required this.threadCacheMaxKB,
    required this.docProviderEnabled,
  });

  factory StorageSettings.defaults() {
    final cache = DefaultConfig.instance.cacheExpireDays;
    final thread = DefaultConfig.instance.threadCacheConfig;
    return StorageSettings(
      avatarCacheDays: cache.avatar,
      emojiCacheDays: cache.emoji,
      imageCacheDays: cache.image,
      medalCacheDays: cache.medal,
      threadCacheDays: thread.expireDays,
      threadCacheEnabled: true,
      threadCacheMaxVersions: 3,
      threadCacheMaxKB: thread.maxBytesPerThread ~/ 1024,
      docProviderEnabled: false,
    );
  }

  Map<String, dynamic> toMap() => {
    'avatarCacheDays': avatarCacheDays,
    'emojiCacheDays': emojiCacheDays,
    'imageCacheDays': imageCacheDays,
    'medalCacheDays': medalCacheDays,
    'threadCacheDays': threadCacheDays,
    'threadCacheEnabled': threadCacheEnabled,
    'threadCacheMaxVersions': threadCacheMaxVersions,
    'threadCacheMaxKB': threadCacheMaxKB,
    'docProviderEnabled': docProviderEnabled,
  };

  factory StorageSettings.fromMap(
    Map<String, dynamic> map, {
    bool aggressive = false,
  }) {
    final d = StorageSettings.defaults();
    return StorageSettings(
      avatarCacheDays:
          (map['avatarCacheDays'] as num?)?.toInt() ?? d.avatarCacheDays,
      emojiCacheDays:
          (map['emojiCacheDays'] as num?)?.toInt() ?? d.emojiCacheDays,
      imageCacheDays:
          (map['imageCacheDays'] as num?)?.toInt() ?? d.imageCacheDays,
      medalCacheDays:
          (map['medalCacheDays'] as num?)?.toInt() ?? d.medalCacheDays,
      threadCacheDays:
          (map['threadCacheDays'] as num?)?.toInt() ?? d.threadCacheDays,
      threadCacheEnabled: boolOrNewFeature(
        map,
        'threadCacheEnabled',
        fallback: d.threadCacheEnabled,
        aggressive: aggressive,
      ),
      threadCacheMaxVersions:
          (map['threadCacheMaxVersions'] as num?)?.toInt() ??
          d.threadCacheMaxVersions,
      threadCacheMaxKB:
          (map['threadCacheMaxKB'] as num?)?.toInt() ?? d.threadCacheMaxKB,
      docProviderEnabled: boolOrNewFeature(
        map,
        'docProviderEnabled',
        fallback: d.docProviderEnabled,
        aggressive: aggressive,
      ),
    );
  }
}

class NoticeSettings {
  final int badgeMode;
  final bool checkEnabled;
  final Set<String> badgeGroups;

  const NoticeSettings({
    required this.badgeMode,
    required this.checkEnabled,
    required this.badgeGroups,
  });

  factory NoticeSettings.defaults() => NoticeSettings(
    badgeMode: NoticeBadgeMode.number.index,
    checkEnabled: true,
    badgeGroups: noticeGroupIds,
  );

  Map<String, dynamic> toMap() => {
    'badgeMode': badgeMode,
    'checkEnabled': checkEnabled,
    'badgeGroups': badgeGroups.toList(),
  };

  factory NoticeSettings.fromMap(
    Map<String, dynamic> map, {
    bool aggressive = false,
  }) {
    final d = NoticeSettings.defaults();
    final groups = map['badgeGroups'];
    return NoticeSettings(
      badgeMode: (map['badgeMode'] as num?)?.toInt() ?? d.badgeMode,
      checkEnabled: boolOrNewFeature(
        map,
        'checkEnabled',
        fallback: d.checkEnabled,
        aggressive: aggressive,
      ),
      badgeGroups: groups is List
          ? groups
                .map((e) => e.toString())
                .where(noticeGroupIds.contains)
                .toSet()
          : d.badgeGroups,
    );
  }
}

class ShareSettings {
  final int maxHeight;
  final bool contentOnly;

  const ShareSettings({required this.maxHeight, required this.contentOnly});

  factory ShareSettings.defaults() =>
      const ShareSettings(maxHeight: 8000, contentOnly: false);

  Map<String, dynamic> toMap() => {
    'maxHeight': maxHeight,
    'contentOnly': contentOnly,
  };

  factory ShareSettings.fromMap(
    Map<String, dynamic> map, {
    bool aggressive = false,
  }) {
    final d = ShareSettings.defaults();
    return ShareSettings(
      maxHeight: (map['maxHeight'] as num?)?.toInt() ?? d.maxHeight,
      contentOnly: boolOrNewFeature(
        map,
        'contentOnly',
        fallback: d.contentOnly,
        aggressive: aggressive,
      ),
    );
  }
}

class HistorySettings {
  final int maxCount;
  final String formatThread;
  final String formatUser;
  final String titleFormatThread;
  final String titleFormatUser;
  final String titleFormatMythread;
  final String titleFormatReply;

  const HistorySettings({
    required this.maxCount,
    required this.formatThread,
    required this.formatUser,
    required this.titleFormatThread,
    required this.titleFormatUser,
    required this.titleFormatMythread,
    required this.titleFormatReply,
  });

  factory HistorySettings.defaults() => const HistorySettings(
    maxCount: 200,
    formatThread: '{title}',
    formatUser: '{nickname}',
    titleFormatThread: '{title}',
    titleFormatUser: '{nickname}',
    titleFormatMythread: '{typeLabel}(UID={uid}, 第{page}页)',
    titleFormatReply: '{typeLabel}(UID={uid}, 第{page}页)',
  );

  Map<String, dynamic> toMap() => {
    'maxCount': maxCount,
    'formatThread': formatThread,
    'formatUser': formatUser,
    'titleFormatThread': titleFormatThread,
    'titleFormatUser': titleFormatUser,
    'titleFormatMythread': titleFormatMythread,
    'titleFormatReply': titleFormatReply,
  };

  factory HistorySettings.fromMap(
    Map<String, dynamic> map, {
    bool aggressive = false,
  }) {
    final d = HistorySettings.defaults();
    return HistorySettings(
      maxCount: (map['maxCount'] as num?)?.toInt() ?? d.maxCount,
      formatThread: map['formatThread']?.toString() ?? d.formatThread,
      formatUser: map['formatUser']?.toString() ?? d.formatUser,
      titleFormatThread:
          map['titleFormatThread']?.toString() ?? d.titleFormatThread,
      titleFormatUser: map['titleFormatUser']?.toString() ?? d.titleFormatUser,
      titleFormatMythread:
          map['titleFormatMythread']?.toString() ?? d.titleFormatMythread,
      titleFormatReply:
          map['titleFormatReply']?.toString() ?? d.titleFormatReply,
    );
  }
}

class AdvancedSettings {
  final bool autoCheckUpdate;

  /// 「激进跟随更新」：更新新增的功能开关**默认就开着**。
  ///
  /// 只影响「本次更新才出现的设置项」，用户已经动过的旧开关一律不动。
  /// 实现上靠「设置文档里有没有这个键」判定新旧（见 [boolOrNewFeature]）——
  /// 用法比维护一份 schemaVersion 迁移表简单得多，也不会漏项。
  final bool aggressiveFollowUpdates;

  final String skippedUpdateVersion;

  /// 上次检查更新的时间（Unix 秒，0 = 从未检查）；用于 1 小时启动限流
  final int lastUpdateCheckAt;
  final bool developerMode;

  /// 用户选择的更新渠道；空串 = 跟随构建（不覆盖构建期注入的渠道）。
  ///
  /// 存 `release` / `beta` 字符串而不是枚举，避免 models 层反向依赖
  /// `config/update_config.dart`；解析统一走 `UpdateConfig.parseChannel`
  /// （它同时兼容 `latest` / `prerelease` 与历史值 `debug`）。
  ///
  /// 它只决定**检查哪一类发布**（Latest / Pre-release），不改 applicationId。
  final String updateChannel;

  const AdvancedSettings({
    required this.autoCheckUpdate,
    required this.skippedUpdateVersion,
    required this.lastUpdateCheckAt,
    required this.developerMode,
    this.updateChannel = '',
    this.aggressiveFollowUpdates = false,
  });

  factory AdvancedSettings.defaults() => const AdvancedSettings(
    autoCheckUpdate: true,
    skippedUpdateVersion: '',
    lastUpdateCheckAt: 0,
    developerMode: false,
    updateChannel: '',
    aggressiveFollowUpdates: false,
  );

  Map<String, dynamic> toMap() => {
    'autoCheckUpdate': autoCheckUpdate,
    'skippedUpdateVersion': skippedUpdateVersion,
    'lastUpdateCheckAt': lastUpdateCheckAt,
    'developerMode': developerMode,
    'updateChannel': updateChannel,
    'aggressiveFollowUpdates': aggressiveFollowUpdates,
  };

  factory AdvancedSettings.fromMap(
    Map<String, dynamic> map, {
    bool aggressive = false,
  }) {
    final d = AdvancedSettings.defaults();
    return AdvancedSettings(
      autoCheckUpdate: boolOrNewFeature(
        map,
        'autoCheckUpdate',
        fallback: d.autoCheckUpdate,
        aggressive: aggressive,
      ),
      skippedUpdateVersion:
          map['skippedUpdateVersion']?.toString() ?? d.skippedUpdateVersion,
      lastUpdateCheckAt:
          (map['lastUpdateCheckAt'] as num?)?.toInt() ?? d.lastUpdateCheckAt,
      developerMode: boolOrNewFeature(
        map,
        'developerMode',
        fallback: d.developerMode,
        aggressive: aggressive,
      ),
      updateChannel: map['updateChannel']?.toString() ?? d.updateChannel,
      aggressiveFollowUpdates:
          map['aggressiveFollowUpdates'] as bool? ?? d.aggressiveFollowUpdates,
    );
  }
}
