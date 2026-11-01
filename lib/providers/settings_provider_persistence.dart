part of 'settings_provider.dart';

/// [SettingsProvider] 的整体加载与通用设置写操作
extension SettingsPersistence on SettingsProvider {
  // ==================== 加载 ====================

  /// 把应用设置中需要推送到全局服务的值同步一次。
  ///
  /// 启动时由 main 调用；导入设置后也调用，避免缓存天数/错峰间隔要等重启。
  void applyRuntimeConfig() {
    stagger_queue.setStaggerInterval(Duration(milliseconds: _staggerInterval));
    initCacheManagers(
      emojiDays: _emojiCacheDays,
      avatarDays: _avatarCacheDays,
      imageDays: _imageCacheDays,
      medalDays: _medalCacheDays,
    );
    AvatarRedirectStore.instance.cacheTtl = Duration(days: _avatarCacheDays);
    // 备份日志保留天数注入服务层（服务层不读 provider，避免循环依赖）
    applyBackupRuntimeConfig();
  }

  Future<void> load() async {
    // 1. 站点列表（站点身份仍存在 app_sites）
    final sitesJson = await _db.getSitesRaw();
    if (sitesJson != null && sitesJson.isNotEmpty) {
      final list = jsonDecode(sitesJson) as List<dynamic>;
      _sites = list
          .map((j) => Site.fromJson(j as Map<String, dynamic>))
          .toList();
    }
    if (_sites.isEmpty) {
      _sites = SiteConfig.defaultSites();
    }

    // 2. 应用设置 + 各站点设置（文档不存在时使用默认值）
    await _settings.loadAll(_sites.map((s) => s.host));
    _applyAppSettings(_settings.app);

    // 3. 当前站点：用 host 定位，站点排序/删除后不漂移
    final host = _settings.app.currentSiteHost;
    final idx = _sites.indexWhere((s) => s.host == host);
    _currentSiteIndex = (idx >= 0 ? idx : 0).clamp(0, _sites.length - 1);
    SiteStore.instance.replaceSites(_sites);
    SiteStore.instance.switchTo(_currentSiteIndex);

    // 4. 把应用设置同步给非 UI 服务
    ThreadCacheService.instance.configure(
      ttlDays: _threadCacheDays,
      maxBytesPerThread: _threadCacheMaxKB * 1024,
      maxVersions: _threadCacheMaxVersions,
    );

    _notify();

    // ==================== 内容过滤（功能①②，与 AppSettings 文档并行的独立 KV） ====================
    // 布尔：黑/白名单模式（默认黑名单）
    _threadFilterModeBlock =
        (await _db.getSettingBool('threadFilterModeBlock')) ?? true;
    // 三个名单：JSON 数组持久化，损坏/缺省时回退默认（[] / 不过滤）
    _threadFilterBoards = _decodeStringList(
      await _db.getSetting('threadFilterBoards'),
    );
    _threadFilterKeywords = _decodeStringList(
      await _db.getSetting('threadFilterKeywords'),
    );
    _commentFilterKeywords = _decodeStringList(
      await _db.getSetting('commentFilterKeywords'),
    );
    // 评论屏蔽总开关（默认开，对齐 mtlite「评论屏蔽」）
    _commentBlockEnabled =
        (await _db.getSettingBool('commentBlockEnabled')) ?? true;
    // 评论屏蔽词预填：首次运行/内置词表版本升级时，把内置词表合并成的
    // 一条正则写进设置（对齐 mtlite「屏蔽词预置」机制——旧内置正则以
    // 「康康看下|」开头据此剔除，用户自定义词保留，可自由删改）。
    final wordsVersion = await _db.getSetting('commentBlockWordsVersion');
    if (wordsVersion != kCommentBlockWordsVersion) {
      final keep = _commentFilterKeywords
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('康康看下|'))
          .toList();
      keep.add(kCommentBlockWordsRegex);
      _commentFilterKeywords = keep;
      await _db.setSetting(
        'commentFilterKeywords',
        jsonEncode(_commentFilterKeywords),
      );
      await _db.setSetting(
        'commentBlockWordsVersion',
        kCommentBlockWordsVersion,
      );
    }
    // ==================== 按列表点的帖子屏蔽配置（功能①扩展） ====================
    // 逐点加载 JSON 配置；损坏/缺省时回退空配置（不过滤）
    _threadScopeFilters = {};
    for (final scope in SettingsProvider._kThreadScopes) {
      final raw = await _db.getSetting('threadScopeFilter_$scope');
      if (raw == null || raw.isEmpty) continue;
      try {
        _threadScopeFilters[scope] = ThreadScopeFilter.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (_) {
        // 单点损坏不影响其他点
      }
    }
    // 旧全局配置自动迁移：threadScopeFilter_* 均未写入且旧键有内容时，
    // 把旧全局配置复制为四个列表点的初始配置（只迁移一次）
    if (_threadScopeFilters.isEmpty &&
        (_threadFilterBoards.isNotEmpty || _threadFilterKeywords.isNotEmpty)) {
      for (final scope in SettingsProvider._kThreadScopes) {
        final f = ThreadScopeFilter(
          enabled: true,
          modeBlock: _threadFilterModeBlock,
          boards: List.of(_threadFilterBoards),
          keywords: List.of(_threadFilterKeywords),
        );
        _threadScopeFilters[scope] = f;
        await _db.setSetting(
          'threadScopeFilter_$scope',
          jsonEncode(f.toJson()),
        );
      }
    }
    _notify();
  }

  /// 应用设置文档 → Provider 字段
  void _applyAppSettings(AppSettings a) {
    _fontSize = a.reading.fontSize;
    _codeBlockMaxLines = a.reading.codeBlockMaxLines;
    _ratingMaxRows = a.reading.ratingMaxRows;
    _autoDetectUrls = a.reading.autoDetectUrls;
    _disabledBbcodeTags = a.reading.disabledBbcodeTags
        .where(bbcodeStyleTagIds.contains)
        .toSet();

    _themeMode = a.appearance.themeModeValue;
    _seedColor = a.appearance.seedColorValue;
    _isPureBlackTheme = a.appearance.pureBlackTheme;
    _showAvatars = a.appearance.showAvatars;
    _avatarSizeMode = a.appearance.avatarSizeModeValue;
    _maxImageWidth = a.appearance.maxImageWidth;

    _defaultTabIndex = a.startup.defaultTabIndex;
    _doubleBackExit = a.startup.doubleBackExit;
    _guideTabs = a.startup.guideTabs;
    _homeSections = a.startup.homeSections;
    _noticeTabs = a.startup.noticeTabs;
    _autoFrequentTabs = a.startup.autoFrequentTabs;
    _tabUsage = a.startup.tabUsage;

    _threadMiniEditor = a.editor.threadMiniEditor;
    _editorStartupCheck = a.editor.editorStartupCheck;
    _toolbarShortcutWhenHidden = a.editor.toolbarShortcutWhenHidden;
    _quickReplies = a.editor.quickReplies;
    _toolbarItems = syncToolbarWithDefaults(
      a.editor.toolbarItems,
      defaultToolbarItems(),
    );
    _shortcuts = a.editor.shortcuts;
    _toolbarShortcuts = a.editor.toolbarShortcuts;
    _minSnapshotWordCount = a.editor.minSnapshotWordCount;
    _autoSaveInterval = a.editor.autoSaveInterval;
    _maxAutoSnapshots = a.editor.maxAutoSnapshots;

    _avatarCacheDays = a.storage.avatarCacheDays;
    _emojiCacheDays = a.storage.emojiCacheDays;
    _imageCacheDays = a.storage.imageCacheDays;
    _medalCacheDays = a.storage.medalCacheDays;
    _threadCacheDays = a.storage.threadCacheDays.clamp(1, 365);
    _threadCacheEnabled = a.storage.threadCacheEnabled;
    _threadCacheMaxVersions = a.storage.threadCacheMaxVersions.clamp(
      ThreadCacheService.minMaxVersions,
      ThreadCacheService.maxMaxVersions,
    );
    _threadCacheMaxKB = a.storage.threadCacheMaxKB.clamp(
      ThreadCacheService.minMaxKB,
      ThreadCacheService.maxMaxKB,
    );

    _noticeBadgeMode = NoticeBadgeMode
        .values[a.notice.badgeMode.clamp(0, NoticeBadgeMode.values.length - 1)];
    _noticeCheckEnabled = a.notice.checkEnabled;
    _noticeBadgeGroups = a.notice.badgeGroups;

    _shareImageMaxHeight = a.share.maxHeight;
    _shareImageContentOnly = a.share.contentOnly;

    _historyMaxCount = a.history.maxCount;
    _historyFormatThread = a.history.formatThread;
    _historyFormatUser = a.history.formatUser;
    _historyTitleFormatThread = a.history.titleFormatThread;
    _historyTitleFormatUser = a.history.titleFormatUser;
    _historyTitleFormatMythread = a.history.titleFormatMythread;
    _historyTitleFormatReply = a.history.titleFormatReply;

    _autoCheckUpdate = a.advanced.autoCheckUpdate;
    _skippedUpdateVersion = a.advanced.skippedUpdateVersion;
    _lastUpdateCheckAt = a.advanced.lastUpdateCheckAt;
    _developerMode = a.advanced.developerMode;
    // 备份/恢复设置（勾选项、Web 服务器、日志保留天数）：从文档读回，
    // 漏了这一行会表现为「重启后勾选状态与服务器配置全丢」
    _backup = a.backup;
    BackupService.instance.keepDays = _backup.logKeepDays;
  }

  AppSettings _buildAppSettings() => AppSettings(
    currentSiteHost: _sites.isEmpty
        ? ''
        : _sites[_currentSiteIndex.clamp(0, _sites.length - 1)].host,
    appearance: AppearanceSettings(
      themeMode: _themeMode.name,
      seedColor: _seedColor.toARGB32(),
      pureBlackTheme: _isPureBlackTheme,
      showAvatars: _showAvatars,
      avatarSizeMode: _avatarSizeMode.value,
      maxImageWidth: _maxImageWidth,
    ),
    startup: StartupSettings(
      defaultTabIndex: _defaultTabIndex,
      doubleBackExit: _doubleBackExit,
      guideTabs: _guideTabs,
      homeSections: _homeSections,
      noticeTabs: _noticeTabs,
      autoFrequentTabs: _autoFrequentTabs,
      tabUsage: _tabUsage,
    ),
    reading: ReadingSettings(
      fontSize: _fontSize,
      codeBlockMaxLines: _codeBlockMaxLines,
      ratingMaxRows: _ratingMaxRows,
      autoDetectUrls: _autoDetectUrls,
      disabledBbcodeTags: _disabledBbcodeTags,
    ),
    editor: EditorSettings(
      threadMiniEditor: _threadMiniEditor,
      editorStartupCheck: _editorStartupCheck,
      toolbarShortcutWhenHidden: _toolbarShortcutWhenHidden,
      quickReplies: _quickReplies,
      toolbarItems: _toolbarItems,
      shortcuts: _shortcuts,
      toolbarShortcuts: _toolbarShortcuts,
      minSnapshotWordCount: _minSnapshotWordCount,
      autoSaveInterval: _autoSaveInterval,
      maxAutoSnapshots: _maxAutoSnapshots,
    ),
    storage: StorageSettings(
      avatarCacheDays: _avatarCacheDays,
      emojiCacheDays: _emojiCacheDays,
      imageCacheDays: _imageCacheDays,
      medalCacheDays: _medalCacheDays,
      threadCacheDays: _threadCacheDays,
      threadCacheEnabled: _threadCacheEnabled,
      threadCacheMaxVersions: _threadCacheMaxVersions,
      threadCacheMaxKB: _threadCacheMaxKB,
    ),
    notice: NoticeSettings(
      badgeMode: _noticeBadgeMode.index,
      checkEnabled: _noticeCheckEnabled,
      badgeGroups: _noticeBadgeGroups,
    ),
    share: ShareSettings(
      maxHeight: _shareImageMaxHeight,
      contentOnly: _shareImageContentOnly,
    ),
    history: HistorySettings(
      maxCount: _historyMaxCount,
      formatThread: _historyFormatThread,
      formatUser: _historyFormatUser,
      titleFormatThread: _historyTitleFormatThread,
      titleFormatUser: _historyTitleFormatUser,
      titleFormatMythread: _historyTitleFormatMythread,
      titleFormatReply: _historyTitleFormatReply,
    ),
    advanced: AdvancedSettings(
      autoCheckUpdate: _autoCheckUpdate,
      skippedUpdateVersion: _skippedUpdateVersion,
      lastUpdateCheckAt: _lastUpdateCheckAt,
      developerMode: _developerMode,
    ),
    backup: _backup,
  );

  Future<void> _persistApp() => _settings.setApp(_buildAppSettings());

  // ==================== 站点设置写入 ====================

  SiteSettings get _currentSite => _settings.site(SiteStore.instance.host);

  Future<void> _updateCurrentSite(
    SiteSettings Function(SiteSettings current) update,
  ) async {
    await _settings.updateSite(SiteStore.instance.host, update);
    _notify();
  }

  Future<void> setSimulateBrowserHeaders(bool enabled) => _updateCurrentSite(
    (s) => s.copyWith(
      network: s.network.copyWith(simulateBrowserHeaders: enabled),
    ),
  );

  Future<void> setInterstitialAutoVerify(bool enabled) => _updateCurrentSite(
    (s) => s.copyWith(
      network: s.network.copyWith(interstitialAutoVerify: enabled),
    ),
  );

  Future<void> setAcwForceWebview(bool enabled) => _updateCurrentSite(
    (s) => s.copyWith(network: s.network.copyWith(acwForceWebview: enabled)),
  );

  Future<void> setAppPageEnabled(String id, bool enabled) =>
      _updateCurrentSite((s) {
        final ids = Set<String>.from(s.pages.disabledPageIds);
        if (enabled) {
          ids.remove(id);
        } else {
          ids.add(id);
        }
        return s.copyWith(pages: s.pages.copyWith(disabledPageIds: ids));
      });

  Future<void> setBrowserOnlyMode(bool enabled) => _updateCurrentSite(
    (s) => s.copyWith(pages: s.pages.copyWith(browserOnly: enabled)),
  );

  Future<void> setSpaceSource(String value) => _updateCurrentSite(
    (s) => s.copyWith(content: s.content.copyWith(spaceSource: value)),
  );

  Future<void> setPostMaxLength(int value) => _updateCurrentSite(
    (s) => s.copyWith(
      content: s.content.copyWith(postMaxLength: value.clamp(1, 1000000)),
    ),
  );

  // ==================== 应用设置写入 ====================

  /// 开关"帖子页使用内嵌迷你编辑器"
  Future<void> setThreadMiniEditorEnabled(bool enabled) async {
    _threadMiniEditor = enabled;
    await _persistApp();
    _notify();
  }

  /// 开关"返回键双击退出"
  Future<void> setDoubleBackExit(bool enabled) async {
    _doubleBackExit = enabled;
    await _persistApp();
    _notify();
  }

  /// 消息未读标记样式（隐藏 / 红点 / 数字）
  Future<void> setNoticeBadgeMode(NoticeBadgeMode mode) async {
    _noticeBadgeMode = mode;
    await _persistApp();
    _notify();
  }

  Future<void> setNoticeCheckEnabled(bool enabled) async {
    _noticeCheckEnabled = enabled;
    await _persistApp();
    _notify();
  }

  Future<void> setNoticeBadgeGroups(Set<String> groups) async {
    _noticeBadgeGroups = Set.from(groups);
    await _persistApp();
    _notify();
  }

  Future<void> setDeveloperMode(bool enabled) async {
    _developerMode = enabled;
    await _persistApp();
    _notify();
  }

  Future<void> setAutoCheckUpdate(bool enabled) async {
    _autoCheckUpdate = enabled;
    await _persistApp();
    _notify();
  }

  Future<void> setSkippedUpdateVersion(String tag) async {
    _skippedUpdateVersion = tag;
    await _persistApp();
    _notify();
  }

  Future<void> setLastUpdateCheckAt(int unixSeconds) async {
    if (_lastUpdateCheckAt == unixSeconds) return;
    _lastUpdateCheckAt = unixSeconds;
    await _persistApp();
  }

  Future<void> setStaggerInterval(int ms) async {
    _staggerInterval = ms.clamp(20, 300);
    await _persistApp();
    _notify();
  }

  Future<void> setAvatarCacheDays(int days) async {
    _avatarCacheDays = days.clamp(-1, 365);
    await _persistApp();
    _notify();
  }

  Future<void> setEmojiCacheDays(int days) async {
    _emojiCacheDays = days.clamp(-1, 365);
    await _persistApp();
    _notify();
  }

  Future<void> setImageCacheDays(int days) async {
    _imageCacheDays = days.clamp(-1, 365);
    await _persistApp();
    _notify();
  }

  Future<void> setMedalCacheDays(int days) async {
    _medalCacheDays = days.clamp(-1, 365);
    await _persistApp();
    _notify();
  }

  /// 帖子自动缓存过期天数：下限 1 天
  Future<void> setThreadCacheDays(int days) async {
    _threadCacheDays = days.clamp(1, 365);
    await _persistApp();
    ThreadCacheService.instance.configure(ttlDays: _threadCacheDays);
    _notify();
  }

  /// 帖子自动缓存总开关
  Future<void> setThreadCacheEnabled(bool enabled) async {
    _threadCacheEnabled = enabled;
    await _persistApp();
    _notify();
  }

  /// 每帖保留的正文版本数（1~10）
  Future<void> setThreadCacheMaxVersions(int v) async {
    _threadCacheMaxVersions = v.clamp(
      ThreadCacheService.minMaxVersions,
      ThreadCacheService.maxMaxVersions,
    );
    await _persistApp();
    ThreadCacheService.instance.configure(maxVersions: _threadCacheMaxVersions);
    _notify();
  }

  /// 单帖最大缓存大小（KB）
  Future<void> setThreadCacheMaxKB(int kb) async {
    _threadCacheMaxKB = kb.clamp(
      ThreadCacheService.minMaxKB,
      ThreadCacheService.maxMaxKB,
    );
    await _persistApp();
    ThreadCacheService.instance.configure(
      maxBytesPerThread: _threadCacheMaxKB * 1024,
    );
    _notify();
  }

  Future<void> setMinSnapshotWordCount(int v) async {
    _minSnapshotWordCount = v.clamp(1, 100);
    await _persistApp();
    _notify();
  }

  Future<void> setAutoSaveInterval(int seconds) async {
    _autoSaveInterval = seconds.clamp(5, 300);
    await _persistApp();
    _notify();
  }

  Future<void> setMaxAutoSnapshots(int v) async {
    _maxAutoSnapshots = v.clamp(1, 50);
    await _persistApp();
    _notify();
  }

  Future<void> setDefaultTabIndex(int index) async {
    _defaultTabIndex = index.clamp(0, 3);
    await _persistApp();
    _notify();
  }

  Future<void> setHistoryFormatThread(String format) async {
    _historyFormatThread = format;
    await _persistApp();
    _notify();
  }

  Future<void> setHistoryFormatUser(String format) async {
    _historyFormatUser = format;
    await _persistApp();
    _notify();
  }

  Future<void> setHistoryTitleFormatThread(String format) async {
    _historyTitleFormatThread = format;
    await _persistApp();
    _notify();
  }

  Future<void> setHistoryTitleFormatUser(String format) async {
    _historyTitleFormatUser = format;
    await _persistApp();
    _notify();
  }

  Future<void> setHistoryTitleFormatMythread(String format) async {
    _historyTitleFormatMythread = format;
    await _persistApp();
    _notify();
  }

  Future<void> setHistoryTitleFormatReply(String format) async {
    _historyTitleFormatReply = format;
    await _persistApp();
    _notify();
  }
}

/// 解析 JSON 数组字符串为 List<String>；null / 损坏时返回空列表
List<String> _decodeStringList(String? raw) {
  if (raw == null || raw.isEmpty) return [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.whereType<String>().toList();
    }
  } catch (_) {
    // 损坏数据 → 回退为空（不过滤），不中断启动
  }
  return [];
}
