import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:mtbbs/auth/providers/auth_provider.dart';
import 'package:mtbbs/config/build_config.dart';
import 'package:mtbbs/mcp/mcp.dart';
import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/widgets/common/toast_utils.dart';
import 'package:mtbbs/widgets/common/user_avatar.dart';
import 'package:mtbbs/pages/settings/user_management_dialog.dart';
import 'package:mtbbs/pages/settings/widgets/dialogs.dart';
import 'package:mtbbs/pages/user/user_uid_picker_dialog.dart';
import 'package:mtbbs/core/app/site_scope.dart';
import 'package:mtbbs/core/app/app_page_gate.dart';

/// 我的页面
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  /// 匿名访问他人主页：输入 UID → 以**游客身份**打开该用户主页。
  ///
  /// 与普通跳转的区别只在 `anon=1` 参数（见 `SiteScope` / `SessionRegistry`）：
  /// 页面用不带登录 cookie 的 Dio 请求，站点侧看不到"谁来看过"，
  /// 也不会因为"自己看自己"而走成本人视角。匿名页是只读的。
  ///
  /// 若用户把「用户主页」关掉（页面接管 → 内置浏览器）或开了站点级降级，
  /// 这条路径会被 `appPageRedirect` 送去浏览器 —— 而浏览器用的是登录态，
  /// 等于"匿名入口"变成了实名访问。所以先探测一次，命中就提示而不是照跳。
  void _openAnonymousUserPage(BuildContext context) {
    void open(int uid) {
      final path = withAnonParam('/user/$uid');
      if (appPageRedirect(path) != null) {
        showToast('当前设置下用户主页由内置浏览器打开，无法匿名访问（可在 设置 → 页面接管 开启用户主页）');
        return;
      }
      context.push(path);
    }

    showDialog(
      context: context,
      builder: (_) => UidPickerDialog(
        title: '匿名访问用户主页',
        hintText: '输入要访问的 UID',
        confirmLabel: '匿名访问',
        onNavigateToUid: open,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();
    final settings = context.watch<SettingsProvider>();
    final mcp = context.watch<McpServerController>();

    final themeIcon = switch (settings.themeMode) {
      ThemeMode.light => Icons.light_mode,
      ThemeMode.dark => Icons.dark_mode,
      ThemeMode.system => Icons.settings_brightness,
    };

    return Material(
      type: MaterialType.transparency,
      child: ListView(
        children: [
          // 用户卡片
          Container(
            padding: const EdgeInsets.all(20),
            color: cs.surface,
            child: Row(
              children: [
                UserAvatar(uid: auth.uid, nickname: auth.username, radius: 30),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        auth.isLoggedIn ? auth.username : '未登录',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        auth.isLoggedIn ? 'UID: ${auth.uid}' : '登录后可浏览论坛',
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // MCP 快捷开关（主题模式左侧）：一键开/关，图标与颜色反映运行状态
                IconButton(
                  icon: Icon(mcp.isRunning ? Icons.hub : Icons.hub_outlined),
                  color: mcp.isRunning ? cs.primary : null,
                  tooltip: mcp.isRunning ? 'MCP 服务已开启，点击关闭' : 'MCP 服务已关闭，点击开启',
                  onPressed: () async {
                    final next = !mcp.enabled;
                    await mcp.setEnabled(next);
                    showToast(
                      next ? '已开启 MCP 服务' : '已关闭 MCP 服务',
                      duration: const Duration(seconds: 1),
                    );
                  },
                ),
                IconButton(
                  icon: Icon(themeIcon),
                  tooltip: '主题模式',
                  onPressed: () => showThemeModeDialog(
                    context,
                    context.read<SettingsProvider>(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.swap_horiz, size: 20),
                  tooltip: '切换账号',
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => const UserManagementDialog(),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // 功能列表
          Material(
            color: cs.surface,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('小黑屋'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/darkroom'),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.people_alt_outlined),
                  title: const Text('在线用户'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/online'),
                ),
                const Divider(height: 1, indent: 56),
                // 匿名访问：以游客身份打开某用户主页（不留下访客足迹，只读）
                ListTile(
                  leading: const Icon(Icons.visibility_off_outlined),
                  title: const Text('匿名访问用户主页'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openAnonymousUserPage(context),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.history_outlined),
                  title: const Text('浏览记录'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/history'),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.forum_outlined),
                  title: const Text('我的帖子'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/my-threads'),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.reply_outlined),
                  title: const Text('最近回复'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/my-threads?type=reply'),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.bookmark_outline),
                  title: const Text('我的收藏'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/favorite'),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.groups_outlined),
                  title: const Text('圈子'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/groups'),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('设置'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/settings'),
                ),
              ],
            ),
          ),

          // 开源信息
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
            child: Text(
              BuildConfig.repoUrl,
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
