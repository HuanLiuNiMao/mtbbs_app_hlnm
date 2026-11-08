import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:mtbbs/core/utils/content_filter.dart';
import 'package:mtbbs/pages/settings/content_filter_quick_sheet.dart';
import 'package:mtbbs/providers/settings_provider.dart';

/// 列表页右上角「屏蔽」快捷面板回归。
///
/// 锁两件事：
/// 1. 面板必须同时给出「开关」与「进设置」两条路（用户诉求是「可开关屏蔽和
///    打开设置」，缺一条就等于没满足）；
/// 2. 评论屏蔽只在会展开楼层的页面出现——帖子列表页没有楼层可屏蔽，多摆一个
///    开关只会让人以为它管的是帖子。
///
/// 这里只断言渲染，不点开关：`SettingsProvider` 的 setter 会写 sembast，
/// 单测环境没有数据库。开关的状态联动由 `docs/30` 的「配置必须 watch」约束
/// 与页面侧 `context.watch` 保证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> openSheet(
    WidgetTester tester, {
    bool showCommentFilter = false,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: SettingsProvider(),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showContentFilterQuickSheet(
                    context,
                    scope: kThreadScopeUser,
                    scopeTitle: threadScopeTitle(kThreadScopeUser),
                    showCommentFilter: showCommentFilter,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('帖子列表页：只有帖子列表屏蔽，没有评论屏蔽', (tester) async {
    await openSheet(tester);
    expect(find.text('屏蔽帖子'), findsOneWidget);
    expect(find.text('帖子列表屏蔽设置'), findsOneWidget);
    expect(find.text('个人主页帖子列表'), findsOneWidget);
    // 帖子列表页不展开楼层，评论屏蔽不该出现
    expect(find.text('屏蔽回复楼层'), findsNothing);
    expect(find.text('评论屏蔽设置'), findsNothing);
  });

  testWidgets('回帖列表页：帖子列表屏蔽 + 评论屏蔽都在', (tester) async {
    await openSheet(tester, showCommentFilter: true);
    expect(find.text('屏蔽帖子'), findsOneWidget);
    expect(find.text('帖子列表屏蔽设置'), findsOneWidget);
    expect(find.text('屏蔽回复楼层'), findsOneWidget);
    expect(find.text('评论屏蔽设置'), findsOneWidget);
  });

  test('列表点显示名集中一处，避免设置页与快捷面板叫法漂移', () {
    expect(threadScopeTitle(kThreadScopeCommunity), '社区页（含标签页）');
    expect(threadScopeTitle(kThreadScopeGuide), '导读页');
    expect(threadScopeTitle(kThreadScopeSearch), '搜索结果页');
    expect(threadScopeTitle(kThreadScopeUser), '个人主页帖子列表');
    // 未知 scope 原样返回，不抛异常（新增列表点时不至于崩）
    expect(threadScopeTitle('unknown'), 'unknown');
  });
}
