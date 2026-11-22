import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:mtbbs/providers/settings_provider.dart';
import 'package:mtbbs/widgets/editor/editor_fab.dart';

/// 内置浏览器路由的路径前缀（见 `config/router.dart` 的 `/browser`）。
///
/// 单列成常量是为了让「仅在内置浏览器中显示」这一判断只有一处依据；
/// 路由里新增子路径（如 `/browser/xxx`）也能被 startsWith 覆盖。
const String kBrowserRoutePrefix = '/browser';

/// 编辑器路由（点悬浮窗要跳到这里）。
const String kEditorRoute = '/editor';

/// 编辑器悬浮窗的宿主：挂在 `MaterialApp.builder` 里，罩住整个 App。
///
/// 三个关键点：
/// 1. **不跨应用**：这是 Flutter 层的 `Stack`，不是 `WindowManager` 系统窗口。
///    MCP 悬浮球用 `TYPE_APPLICATION_OVERLAY` 才能飘到别的应用上；本功能
///    用户明确要求**不要**跨应用，所以直接用应用内组件，天然做到。
/// 2. **路由感知**：需要知道当前是不是内置浏览器、是不是已经在编辑器里。
///    ⚠️ 不能用 `GoRouterState.of(context)`：它沿 `ModalRoute` 往上找，
///    而 `MaterialApp.builder` 的 context 位于 `Router` **之上**（`Router`
///    就是 `child` 本身），往上找不到任何 `ModalRoute`，必然抛
///    `There is no GoRouterState above the current context`。
///    这里改为直接监听 `router.routerDelegate`（`ChangeNotifier`），
///    从 `currentConfiguration.uri` 读当前 location。
/// 3. **不挡输入**：只有子组件那一小块响应手势，其余区域用
///    `IgnorePointer` 放行，否则整个 App 都点不动。
class EditorFabHost extends StatelessWidget {
  const EditorFabHost({super.key, required this.child, required this.router});

  final Widget child;

  /// 用于读当前路由 + 跳转编辑器。由 main 注入，避免依赖全局 key。
  final GoRouter router;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    if (!settings.editorFabEnabled) return child;

    // 监听 routerDelegate：只有路由真的变了才重建这一层
    return ListenableBuilder(
      listenable: router.routerDelegate,
      builder: (context, _) {
        final location = router.routerDelegate.currentConfiguration.uri.path;

        // 「仅在内置浏览器中使用」
        if (settings.editorFabBrowserOnly &&
            !location.startsWith(kBrowserRoutePrefix)) {
          return child;
        }

        // 已经在编辑器里就不用再显示了 —— 点它没意义，还挡正文
        if (location == kEditorRoute) return child;

        return Stack(
          children: [
            child,
            // 悬浮窗本体在 EditorFab 内部用 Positioned 定位。它返回的
            // Stack 只有那一小块参与命中测试，空白处不会吃掉点击，
            // 所以不需要额外的 IgnorePointer。
            Positioned.fill(
              child: EditorFab(
                // key 绑尺寸/秒数：设置一改就换新实例，
                // 省得组件内部还要处理「运行中改尺寸」
                key: ValueKey(
                  'editor_fab_${settings.editorFabSize}_'
                  '${settings.editorFabSnapSeconds}',
                ),
                size: settings.editorFabSize,
                snapSeconds: settings.editorFabSnapSeconds,
                onTap: () => router.push(kEditorRoute),
              ),
            ),
          ],
        );
      },
    );
  }
}
