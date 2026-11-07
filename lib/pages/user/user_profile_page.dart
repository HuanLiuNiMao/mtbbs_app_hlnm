import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:mtbbs/config/brand_colors.dart';
import 'package:mtbbs/core/app/app_capabilities.dart';
import 'package:mtbbs/core/app/site_session.dart';
import 'package:mtbbs/core/app/site_scope.dart';
import 'package:mtbbs/core/app/verification_gate.dart';
import 'package:mtbbs/core/settings/settings_repository.dart';
import 'package:mtbbs/core/utils/cache_utils.dart';
import 'package:mtbbs/core/utils/string_utils.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/api/home/space/export.dart' as space_api;
import 'package:mtbbs/api/home/follow/export.dart' as follow_api;
import 'package:mtbbs/auth/providers/auth_provider.dart';
import 'package:mtbbs/models/user_profile.dart';
import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/models/browse_record.dart';
import 'package:mtbbs/providers/history_provider.dart';
import 'package:mtbbs/widgets/common/user_avatar.dart';
import 'package:mtbbs/widgets/common/pie_chart.dart';
import 'package:mtbbs/widgets/common/page_actions.dart';
import 'package:mtbbs/widgets/bbcode/post_html_widget.dart';
import 'package:mtbbs/widgets/common/toast_utils.dart';
import 'package:mtbbs/widgets/layout/page_error_widget.dart';
import 'package:mtbbs/widgets/layout/state_views.dart';
import 'package:mtbbs/pages/user/user_uid_picker_dialog.dart';
import 'package:mtbbs/pages/user/user_share_page.dart';

part 'user_profile_sections.dart';
part 'user_profile_sections_extra.dart';
part 'user_profile_credit_dialog.dart';

/// 用户主页
///
/// 路径: /user/:uid
class UserProfilePage extends StatefulWidget {
  final String uid;
  const UserProfilePage({super.key, required this.uid});

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  ColorScheme get _cs => Theme.of(context).colorScheme;
  Map<String, dynamic>? _profile;
  bool _loading = true;
  String? _error;
  bool _showRawSignature = false;

  /// 当前页面作用域的站点会话（跨站点打开时 = 目标站默认账号/游客，只读）
  SiteSession _session = const GlobalSiteSession();
  Dio get _dio => _session.dio;
  bool _sessionBound = false;

  /// 「生成图片」预览模式：正文区切换为预览（复用本页区块，见 _contentSections）
  bool _sharing = false;

  // ==================== 关注态（他人主页） ====================
  // 数据来自 PC 模板 profile 页（follow/parse.dart 的 parseFollowStatus）。
  bool? _isFollowing; // null = 未登录/未渲染按钮（不显示关注项）
  String _followHash = '';
  String _followFormhash = '';

  /// 关注目标 uid（写接口 fuid 参数；Discuz 缺失即 Access Denied）
  String _followFuid = '';
  bool _followLoading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = SiteScope.of(context);
    // 同一页面上身份可能被换掉（匿名横幅的「用登录身份」是 `replace` 到无 `anon`
    // 的同一路径，GoRoute 的 key 不变 → State 复用）。此时必须重新加载：
    // 否则只读守卫按新会话放开，但关注态等仍停留在匿名时的空值。
    final switched = _sessionBound && !identical(next, _session);
    _session = next;
    if (_sessionBound && !switched) return;
    _sessionBound = true;
    _load();
  }

  /// 只读守卫：跨站点临时会话 / 匿名访问会话命中时提示并返回 true
  ///
  /// 两种只读会话的提示文案不同：跨站点是"换了站点"，匿名是"同一站点的游客"，
  /// 用户需要知道该做什么才能恢复互动。
  bool _guardReadOnly() {
    if (!_session.temporary) return false;
    showToast(
      _session.anonymous
          ? '匿名浏览为只读：需要互动请重新以登录身份打开本页'
          : '跨站点浏览为只读：发帖/留言/私信请先切换到目标站点',
    );
    return true;
  }

  /// 打开 App 内页面；跨站时目标页未迁移 → 提示先切站点
  void _openAppPath(String appPath) {
    if (_guardReadOnly()) return;
    context.push(appPath);
  }

  /// 错误页的「网页验证」入口 —— 带上本页会话，验证结果才会写进本页的罐
  /// （匿名页用匿名罐，跨站点页用该站作用域罐）。
  Future<void> _verifyFromErrorPage() async {
    final ok = await VerificationGate.instance.verifyManually(
      url:
          '${_session.baseUrl}/home.php?mod=space&uid=${widget.uid}&do=profile',
      session: _session,
    );
    if (!mounted) return;
    if (ok) {
      await _load();
    } else {
      showToast('网页验证未通过，请重试');
    }
  }

  /// 供 part 扩展使用（扩展无法直接访问受保护的 setState）
  void _setState(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await space_api.getUserProfile(
        _dio,
        uid: widget.uid == 'self' ? '' : widget.uid,
      );
      final profile = raw['success'] == true && raw['profile'] != null
          ? UserProfile.fromMap(raw['profile'] as Map<String, dynamic>)
          : null;
      if (profile == null) {
        setState(() {
          _error = '加载失败';
          _loading = false;
        });
        return;
      }
      setState(() {
        _profile = profile.toMap();
        _loading = false;
      });
      // 加载成功保存浏览记录（跨站点临时浏览不计入当前站点历史）
      if (context.mounted && !_session.temporary) {
        context.read<HistoryProvider>().addRecord(
          BrowseRecord(
            id: '${_session.host}:user_${widget.uid}',
            host: _session.host,
            type: 'user',
            routePath: '/user/${widget.uid}',
            timestamp: DateTime.now(),
            info: {
              'uid': widget.uid,
              'nickname': profile.nickname,
              'avatar': profile.avatar,
              'url':
                  '${_session.baseUrl}/home.php?mod=space&uid=${widget.uid}&do=profile&from=space',
            },
          ),
        );
      }
      // 加载成功后拉取关注态（他人主页；仅本会话已登录时，取 PC 模板按钮状态与令牌）
      //
      // 判据用**会话身份**而不是 `AuthProvider`：跨站点页 / 匿名页的登录态与全局
      // 账号不同（匿名页恒为游客）。用全局 auth 判断会让匿名页拿着匿名 Dio 去拉
      // "我有没有关注他"，再允许点"收听"（写操作），既无意义也会失败。
      if (_session.isLoggedIn &&
          widget.uid != 'self' &&
          _session.uid != widget.uid) {
        _loadFollowStatus();
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 拉取他人主页关注态与操作令牌（失败静默，仅不显示关注项）
  Future<void> _loadFollowStatus() async {
    try {
      final data = await follow_api.getFollowStatus(_dio, widget.uid);
      if (!mounted) return;
      if (data['success'] == true) {
        final formhash = (data['formhash'] as String?) ?? '';
        final parsedFuid = (data['fuid'] as String?) ?? '';
        setState(() {
          _isFollowing = data['isFollowing'] as bool?;
          _followHash = (data['followHash'] as String?) ?? '';
          _followFormhash = formhash;
          // fuid 优先用页面 href 里解析出的值，解析不到就用本页 uid 兜底
          // （Discuz 写接口要求 fuid 必填，缺失会直接 Access Denied）
          _followFuid = parsedFuid.isNotEmpty ? parsedFuid : widget.uid;
        });
      }
    } catch (e) {
      AppLogger.w('USER', '关注态加载失败: $e');
    }
  }

  /// 关注/取消关注（乐观更新，失败回滚）
  Future<void> _toggleFollow() async {
    if (_followLoading) return;
    final fuid = _followFuid.isNotEmpty ? _followFuid : widget.uid;
    if (fuid.isEmpty || _followFormhash.isEmpty) {
      showToast('关注信息未就绪，请稍候或刷新');
      return;
    }
    final wasFollowing = _isFollowing == true;
    setState(() {
      _followLoading = true;
      _isFollowing = !wasFollowing; // 乐观更新
    });
    try {
      final data = wasFollowing
          ? await follow_api.unfollowUser(
              _dio,
              fuid: fuid,
              formhash: _followFormhash,
            )
          : await follow_api.followUser(
              _dio,
              fuid: fuid,
              formhash: _followFormhash,
            );
      if (!mounted) return;
      if (data['success'] != true) {
        // 服务器拒绝 → 回滚
        setState(() => _isFollowing = wasFollowing);
        showToast('操作失败: ${data['message'] ?? data['error'] ?? '未知错误'}');
      } else {
        showToast(wasFollowing ? '已取消收听' : '已收听');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isFollowing = wasFollowing);
      showToast('网络错误，请重试');
      AppLogger.e('USER', '关注操作失败: $e');
    } finally {
      if (mounted) setState(() => _followLoading = false);
    }
  }

  int? get _uidNum => int.tryParse(widget.uid);

  void _navigateToUid(int uid) =>
      GoRouter.of(context).replace(SiteScope.pathFor(context, '/user/$uid'));

  void _showUidPicker() {
    showDialog(
      context: context,
      builder: (_) => UidPickerDialog(onNavigateToUid: _navigateToUid),
    );
  }

  /// 生成个人主页分享图（见 pages/user/user_share_page.dart）
  ///
  /// 直接复用本页正文区块（`_contentSections`）→ 图片与页面完全一致，无需任何配置。
  void _shareImage() {
    if (_profile == null) return;
    setState(() => _sharing = true);
  }

  /// 正文区块（正文列表与「生成图片」共用，保证图片与页面完全一致）
  List<Widget> _contentSections() => [
    _buildHeader(),
    const SizedBox(height: 8),
    _buildPointsSection(),
    const SizedBox(height: 8),
    if (_profile!['signature'] != null) _buildSignature(),
    if (_profile!['customTitle'] != null) ...[
      const SizedBox(height: 8),
      _buildCustomTitle(),
    ],
    const SizedBox(height: 8),
    _buildActivityInfo(),
    if (_profile!['medals'] != null) ...[
      const SizedBox(height: 8),
      _buildMedals(),
    ],
    const SizedBox(height: 24),
  ];

  /// 数据源菜单行：图标 + 文案 + 勾选
  Widget _sourceMenuRow({
    required IconData icon,
    required String label,
    required bool selected,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Text(label),
        const Spacer(),
        if (selected) const Icon(Icons.check, size: 16),
      ],
    );
  }

  /// 设置本页数据源并重新加载（'' = 跟随浏览模式 / 'mobile' / 'desktop'）
  String get _spaceSource =>
      SettingsRepository.instance.site(_session.host).content.spaceSource;

  Future<void> _setSpaceSource(String value) async {
    await SettingsRepository.instance.updateSite(
      _session.host,
      (s) => s.copyWith(content: s.content.copyWith(spaceSource: value)),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = _cs;
    final uidNum = _uidNum;
    return Scaffold(
      backgroundColor: cs.surfaceContainerLow,
      appBar: AppBar(
        title: GestureDetector(
          onTap: _showUidPicker,
          child: Text(
            _profile != null
                ? '${_profile!['nickname'] ?? '用户'}的主页 (${widget.uid})'
                : '用户主页 (${widget.uid})',
          ),
        ),
        surfaceTintColor: _cs.surface,
        elevation: 0.5,
        actions: [
          PageActions(
            url:
                '${_session.baseUrl}/home.php?mod=space&uid=${widget.uid}&do=profile&from=space',
            onRefresh: _load,
            loading: _loading,
            copyLabel: '复制个人主页链接',
            extraItems: [
              // 生成分享图（与帖子/评论同一套：预览 → 截图保存）
              if (AppCapabilities.isAvailable(AppCapability.saveImage)) ...[
                PopupMenuItem<String>(
                  value: 'save_image',
                  child: Row(
                    children: [
                      const Icon(Icons.save_alt, size: 18),
                      const SizedBox(width: 8),
                      const Text('生成图片'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
              ],
              // 本页数据源（仅个人空间生效）：移动版社交数据全，桌面版资料更全
              PopupMenuItem<String>(
                value: 'src_follow',
                child: _sourceMenuRow(
                  icon: Icons.sync,
                  label: '跟随浏览模式',
                  selected: _spaceSource.isEmpty,
                ),
              ),
              PopupMenuItem<String>(
                value: 'src_mobile',
                child: _sourceMenuRow(
                  icon: Icons.smartphone_outlined,
                  label: '移动版',
                  selected: _spaceSource == 'mobile',
                ),
              ),
              PopupMenuItem<String>(
                value: 'src_desktop',
                child: _sourceMenuRow(
                  icon: Icons.desktop_windows_outlined,
                  label: '桌面版',
                  selected: _spaceSource == 'desktop',
                ),
              ),
              if (uidNum != null) ...[
                const PopupMenuDivider(),
                PopupMenuItem<String>(
                  value: 'prev_user',
                  enabled: uidNum > 1,
                  child: Row(
                    children: [
                      Icon(
                        Icons.chevron_left,
                        size: 18,
                        color: uidNum > 1
                            ? null
                            : Theme.of(context).disabledColor,
                      ),
                      const SizedBox(width: 8),
                      const Text('上一个用户'),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'next_user',
                  child: Row(
                    children: [
                      const Icon(Icons.chevron_right, size: 18),
                      const SizedBox(width: 8),
                      const Text('下一个用户'),
                    ],
                  ),
                ),
              ],
            ],
            onExtraSelected: (action) {
              switch (action) {
                case 'save_image':
                  _shareImage();
                case 'src_follow':
                  _setSpaceSource('');
                case 'src_mobile':
                  _setSpaceSource('mobile');
                case 'src_desktop':
                  _setSpaceSource('desktop');
                case 'prev_user':
                  if (uidNum != null && uidNum > 1) {
                    _navigateToUid(uidNum - 1);
                  }
                case 'next_user':
                  if (uidNum != null) {
                    _navigateToUid(uidNum + 1);
                  }
                case 'credit_analysis':
                  _showCreditDialog();
              }
            },
          ),
        ],
      ),
      body: _sharing ? _buildSharePreview() : _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingView();
    if (_error != null) {
      return PageErrorWidget(
        message: _error!,
        onRetry: _load,
        showBack: false,
        // 匿名 / 跨站点页被拦时也要能过验证：显式带上本页会话，
        // 否则验证结果会写进登录罐（见 VerificationGate.verifyManually）。
        onVerify: _session.temporary ? _verifyFromErrorPage : null,
      );
    }
    if (_profile == null) {
      return const EmptyView(icon: Icons.person_off_outlined, text: '无数据');
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          if (_session.anonymous) _buildAnonymousBanner(),
          ..._contentSections(),
        ],
      ),
    );
  }

  /// 匿名浏览提示条 —— 让用户始终知道"这页不是我登录身份看的"。
  ///
  /// 右侧提供「用登录身份打开」：把 location 上的 `anon=1` 去掉重开一页，
  /// 比"退出再进"直观（且不影响其它已打开的页面）。
  Widget _buildAnonymousBanner() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: cs.surfaceContainerHigh,
      child: Row(
        children: [
          Icon(Icons.visibility_off, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '正在以游客身份匿名浏览（只读，站点不记录你的访问）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          TextButton(
            onPressed: () =>
                GoRouter.of(context).replace('/user/${widget.uid}'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('用登录身份', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// 生成图片预览：复用本页正文区块（与页面完全一致）+ 底部「站点 / 用户 / 二维码」水印
  Widget _buildSharePreview() {
    final p = _profile!;
    final nickname = p['nickname'] as String? ?? '';
    final spaceUrl = p['spaceUrl'] as String? ?? '';
    return UserSharePreview(
      sections: _contentSections(),
      userLabel: nickname.isEmpty
          ? 'uid=${widget.uid}'
          : '$nickname · uid=${widget.uid}',
      qrUrl: spaceUrl.isNotEmpty
          ? spaceUrl
          : '${_session.baseUrl}/home.php?mod=space&uid=${widget.uid}&do=profile&from=space',
      siteHost: _session.host,
      filePrefix: 'MTBBS_user_${widget.uid}',
      onClose: () => setState(() => _sharing = false),
    );
  }

  /// 从嵌套 Map 中安全取值
  dynamic _getNested(Map<String, dynamic> map, List<String> keys) {
    dynamic value = map;
    for (final key in keys) {
      if (value is Map<String, dynamic>) {
        value = value[key];
      } else {
        return null;
      }
    }
    return value;
  }
}
