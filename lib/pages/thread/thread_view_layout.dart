part of 'thread_view_page.dart';

/// 帖子浏览页 — 布局与区块构建。
///
/// 通过 `part of` 与 thread_view_page.dart 共享库内私有成员。
extension on _ThreadViewPageState {
  // ==================== 布局 ====================

  Widget _buildWideLayout() {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: ListView(
            // 与窄屏共用同一 controller：点标题"回顶部"在两种布局下都生效；
            // 两种布局互斥（只挂一个），不会同时 attach 同一 controller。
            controller: _scrollController,
            padding: const EdgeInsets.all(8),
            children: [
              if (_data!.title.isNotEmpty) _buildTitleSection(),
              if (_data!.mainPost != null) _buildMainPostSection(),
            ],
          ),
        ),
        Container(width: 1, color: cs.outlineVariant),
        Expanded(flex: 2, child: _buildCommentColumn()),
      ],
    );
  }

  Widget _buildNarrowLayout() {
    final currentPosts = _commentPages[_currentPage];
    if ((currentPosts == null || currentPosts.isEmpty) &&
        _data!.mainPost == null &&
        !_pageLoading) {
      return const EmptyView(text: '暂无数据');
    }
    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          if (_isCacheMode) SliverToBoxAdapter(child: _buildCacheBanner()),
          if (_data!.title.isNotEmpty)
            SliverToBoxAdapter(child: _buildTitleSection()),
          if (_data!.mainPost != null) ...[
            SliverToBoxAdapter(child: _buildMainPostSection()),
            SliverToBoxAdapter(child: const Divider(height: 1)),
            // 评论区锚点 — 窄屏"滚动到评论区"的目标
            SliverToBoxAdapter(
              child: SizedBox(key: _commentAnchorKey, height: 1),
            ),
          ],
          SliverPersistentHeader(
            pinned: true,
            delegate: CommentHeaderDelegate(
              child: CommentSection.buildHeader(
                context: context,
                currentPage: _currentPage,
                totalPages: _totalPages,
                pageLoading: _pageLoading,
                onPrev: _canGoPrev ? _goPrevPage : null,
                // 扩窗模式：下一页跳「窗口末页+1」，避免重看已拼接内容
                onNext: (_isCacheMode ? _canGoNext : _windowEnd < _totalPages)
                    ? _goNextPageOrExtend
                    : null,
                onPageTap: _showPagePicker,
                onRefresh: _isCacheMode ? null : _refreshCurrentPage,
                windowEnd: _windowEnd,
                onTitleTap: _isCacheMode ? null : _showFloorJumpDialog,
                onlyOpAuthor: _isCacheMode ? null : _onlyOpAuthor,
                onToggleOnlyOpAuthor: _isCacheMode ? null : _toggleOnlyOpAuthor,
              ),
            ),
          ),
          SliverToBoxAdapter(child: _buildCommentContent()),
          SliverToBoxAdapter(
            child: SizedBox(height: MediaQuery.of(context).padding.bottom + 60),
          ),
        ],
      ),
    );
  }

  // ==================== 跨站点提示 ====================

  /// 跨站点临时身份提示条 —— 明确"这是别的站点的只读视图"
  Widget _buildCrossSiteBanner() {
    final cs = Theme.of(context).colorScheme;
    final siteName = SessionRegistry.instance.siteNameForHost(_session.host);
    final who = _session.username.isNotEmpty ? _session.username : '游客';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: cs.surfaceContainerHigh,
      child: Row(
        children: [
          Icon(Icons.public, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '正在以「$siteName」$who 身份只读浏览 · 发帖/评论请先切换站点',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: _switchToSessionSite,
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('立即切换站点', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// 把全局当前站点切换成这条跨站记录的来源站点，并在全局身份下重开本页
  Future<void> _switchToSessionSite() async {
    final index = SiteStore.instance.sites.indexWhere(
      (s) => s.host == _session.host,
    );
    if (index < 0) return;
    final orchestrator = AppOrchestrator(
      settings: context.read<SettingsProvider>(),
      auth: context.read<AuthProvider>(),
    );
    await orchestrator.switchSite(index);
    if (!mounted) return;
    // 当前 location 仍带旧的 site= 参数（指向刚变成作用域会话的站点），
    // 换成不带 site= 的同一帖子，即用新当前站点 + 全局账号打开
    final page = _currentPage > 1 ? '?page=$_currentPage' : '';
    context.pushReplacement('/thread/${widget.tid}$page');
  }

  // ==================== 评论区 ====================

  /// 切换「只看楼主」。
  ///
  /// 切换后列表立刻按新条件重算（build 里过滤），不需要重新请求。
  /// 楼主 uid 拿不到时（主帖未加载 / 解析异常）直接拒绝，否则会因空 uid
  /// 把整页评论筛成空白，用户会以为帖子出了问题。
  void _toggleOnlyOpAuthor() {
    if (_data?.mainPost?.uid.isEmpty ?? true) {
      showToast('楼主信息未加载，暂时无法只看楼主');
      return;
    }
    _setState(() => _onlyOpAuthor = !_onlyOpAuthor);
  }

  Widget _buildCommentContent() {
    var currentPosts = _commentPages[_currentPage];
    // 只读缓存：缺失页 = 未缓存，与「已缓存但无评论」区分
    if (_isCacheMode &&
        _cacheSnapshot?.commentPages.containsKey(_currentPage) != true) {
      return const SizedBox(height: 200, child: EmptyView(text: '该页未缓存'));
    }
    if (currentPosts == null && _pageLoading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    // 功能②：评论屏蔽（命中即隐藏整层楼；楼主/回复别人豁免）
    // 触发范围由配置决定：无触发方式 → 全局生效；「仅隐藏贴」→ 只有隐藏贴；
    // 「按板块」→ 只有本主题板块命中名单。板块名来自详情页面包屑。
    final settings = context.read<SettingsProvider>();
    final commentCfg = settings.commentFilter;
    final isHiddenThread = isHiddenThreadBbcode(_data?.mainPost?.bbcode ?? '');
    currentPosts = currentPosts == null
        ? null
        : filterPostItems(
            currentPosts,
            commentCfg,
            boardName: _data?.boardName,
            isHiddenThread: isHiddenThread,
          );
    // 功能②扩展：屏蔽补页缺额检测——过滤后可见不足一页基准时自动向后扩窗。
    // 闭包异步执行（不阻塞 build）；_pageLoading 在 _loadCommentPage 内部防重入。
    final commentFilterActive = commentFilterApplies(
      commentCfg,
      boardName: _data?.boardName,
      isHiddenThread: isHiddenThread,
    );
    if (commentFilterActive &&
        currentPosts != null &&
        currentPosts.length < _commentPageSizeHint &&
        (_windowEnd - _currentPage + 1) <
            _ThreadViewPageState._commentMaxWindowWidth) {
      Future<void>(() => _maybeExtendCommentWindow(currentPosts!.length));
    }
    // 只看楼主：按主帖作者 uid 过滤当前页评论（纯客户端筛选，见状态字段注释）。
    //
    // 必须放在**补页判定之后**：补页看的是「屏蔽后还剩多少」，若先按楼主筛，
    // 可见量天然远小于一页基准，会一直满足扩窗条件，白白多拉好几页网络请求，
    // 而扩来的页里绝大多数楼层仍会被筛掉。
    if (_onlyOpAuthor && currentPosts != null) {
      currentPosts = filterOnlyOpAuthor(
        currentPosts,
        _data?.mainPost?.uid ?? '',
      );
    }
    return CommentSection(
      posts: currentPosts ?? [],
      postKeys: _postKeys,
      currentPage: _currentPage,
      totalPages: _totalPages,
      pageLoading: _pageLoading,
      tid: widget.tid,
      opUid: _data?.mainPost?.uid ?? '',
      globalDisableStyle: _globalDisableStyle,
      readOnly: _isCacheMode || _session.temporary,
      onlyOpAuthor: _onlyOpAuthor,
      onReply: (post) => _replyToPost(post),
      onRecommend: _handleRecommend,
      onPopupAction: (action, post) {
        switch (action) {
          case PostCardAction.openInBrowser:
            _openPostInBrowser(post);
          case PostCardAction.showBbcode:
            _showPostSource(post);
          case PostCardAction.editPost:
            _editPost(post);
          case PostCardAction.viewTime:
            _fetchPostDetailInfo(post);
          case PostCardAction.rate:
            _handleRate(post);
          case PostCardAction.saveImage:
            _showShareImage(post);
        }
      },
    );
  }

  Widget _buildCommentColumn() {
    return Column(
      children: [
        CommentSection.buildHeader(
          context: context,
          currentPage: _currentPage,
          totalPages: _totalPages,
          pageLoading: _pageLoading,
          onPrev: _canGoPrev ? _goPrevPage : null,
          // 扩窗模式：下一页跳「窗口末页+1」，避免重看已拼接内容
          onNext: (_isCacheMode ? _canGoNext : _windowEnd < _totalPages)
              ? _goNextPageOrExtend
              : null,
          onPageTap: _showPagePicker,
          onRefresh: _isCacheMode ? null : _refreshCurrentPage,
          windowEnd: _windowEnd,
          onTitleTap: _isCacheMode ? null : _showFloorJumpDialog,
          // 只读缓存是整帖快照，筛选它没有意义
          onlyOpAuthor: _isCacheMode ? null : _onlyOpAuthor,
          onToggleOnlyOpAuthor: _isCacheMode ? null : _toggleOnlyOpAuthor,
        ),
        const Divider(height: 1),
        Expanded(child: SingleChildScrollView(child: _buildCommentContent())),
      ],
    );
  }

  // ==================== 主帖 ====================

  Widget _buildMainPostSection() {
    final post = _data!.mainPost!;
    return MainPostSection(
      post: post,
      isLoaded: _isCacheMode || _mainPostLoaded,
      isLiked: _liked,
      tid: widget.tid,
      globalDisableStyle: _globalDisableStyle,
      readOnly: _isCacheMode || _session.temporary,
      onTap: () => _setState(() => _mainPostLoaded = true),
      onRecommend: () => _handleRecommend(post),
      onPopupAction: (action) {
        switch (action) {
          case PostCardAction.openInBrowser:
            _openPostInBrowser(post);
          case PostCardAction.showBbcode:
            _showPostSource(post);
          case PostCardAction.editPost:
            _editPost(post);
          case PostCardAction.viewTime:
            _fetchPostDetailInfo(post);
          case PostCardAction.rate:
            _handleRate(post);
          case PostCardAction.saveImage:
            _showShareImage(post);
        }
      },
    );
  }

  // ==================== 杂项组件 ====================

  // ==================== 迷你编辑器 ====================

  /// 底部内嵌迷你编辑器（评论 / 回复某评论，可收起读帖、可展开为完整版）
  Widget _buildMiniEditor() {
    return MiniEditorBar(
      contentCtl: _editorSession.contentCtl,
      toolbarContext: MiniToolbarContext.thread,
      hintText: _replyTargetPid != null ? '回复评论…' : '说点什么…',
      submitting: _editorSubmitting,
      autofocus: true,
      onSubmit: _submitMiniEditor,
      onImage: _showForumImageUpload,
      onMtImage: _showMtImage,
      onCollapse: _collapseEditor,
      onExpandToFull: _expandToFull,
      targetLabel: _replyTargetName != null ? '回复 ${_replyTargetName}' : null,
      onTapTarget: _replyTargetPid != null ? _showReplyTargetPreview : null,
      // 图片角标：已上传的图片数（有角标时该项强制显示，与完整编辑器一致）
      badges: {if (_images.list.isNotEmpty) 'image': _images.list.length},
      captchaField: _editorSession.captchaRequired
          ? CaptchaFields(session: _editorSession)
          : null,
    );
  }

  Widget _buildReplyBar() {
    final cs = Theme.of(context).colorScheme;
    if (_data == null) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        top: 6,
        bottom: MediaQuery.of(context).padding.bottom + 6,
      ),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: _favoriting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    _favorited ? Icons.bookmark : Icons.bookmark_border,
                    size: 20,
                    color: _favorited ? cs.primary : cs.onSurfaceVariant,
                  ),
            tooltip: _favorited ? '已收藏' : '收藏帖子（可备注）',
            onPressed: _favoriting ? null : _handleFavorite,
          ),
          // 点赞（对帖子的操作，移到收藏旁）
          IconButton(
            icon: Icon(
              _liked ? Icons.thumb_up : Icons.thumb_up_outlined,
              size: 20,
              color: _liked ? cs.primary : cs.onSurfaceVariant,
            ),
            tooltip: _liked ? '已点赞' : '点赞',
            onPressed: () {
              final mainPost = _data?.mainPost;
              if (mainPost != null) _handleRecommend(mainPost);
            },
          ),
          // 评分（文字入口，移到收藏旁）
          if (_data?.mainPost != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _handleRate(_data!.mainPost!),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '评分',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Icon(Icons.reply_rounded, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: _navigateComment,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '说点什么...',
                  style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: Icon(Icons.send_rounded, color: cs.onSurfaceVariant),
            onPressed: _navigateComment,
          ),
        ],
      ),
    );
  }

  Widget _buildTitleSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Text(
        _data!.title,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
      ),
    );
  }
}
