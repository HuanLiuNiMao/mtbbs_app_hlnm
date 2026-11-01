import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/core/app/app_page_gate.dart';
import 'package:mtbbs/core/app/session_registry.dart';
import 'package:mtbbs/core/app/site_scope.dart';
import 'package:mtbbs/core/app/site_store.dart';
import 'package:mtbbs/core/settings/settings_repository.dart';

/// 「匿名访问」的 URL 约定：`anon=1`。
///
/// 由「我的」页 →「匿名访问用户主页」生成；路由层据此把本页的会话换成
/// 不携带登录 cookie 的匿名会话（见 `SessionRegistry.sessionForLocation`）。
/// 这里测纯函数部分（拼参数 / 去参数 / 判定）与入口的「页面接管」前置检查。
void main() {
  group('withAnonParam', () {
    test('无查询参数时用 ? 追加', () {
      expect(withAnonParam('/user/123'), '/user/123?anon=1');
    });

    test('已有查询参数时用 & 续接，且保留原参数', () {
      expect(
        withAnonParam('/user/123?nickname=a'),
        '/user/123?nickname=a&anon=1',
      );
    });

    test('已带 anon=1 时幂等（不重复追加）', () {
      expect(withAnonParam('/user/123?anon=1'), '/user/123?anon=1');
    });
  });

  group('isAnonLocation', () {
    test('anon=1 命中', () {
      expect(isAnonLocation(Uri.parse('/user/123?anon=1')), isTrue);
    });

    test('缺少 / 其他取值都不命中', () {
      expect(isAnonLocation(Uri.parse('/user/123')), isFalse);
      expect(isAnonLocation(Uri.parse('/user/123?anon=0')), isFalse);
      expect(isAnonLocation(null), isFalse);
    });
  });

  group('withoutSiteParam', () {
    test('去掉 anon 标记（复制站内链接时不能带出去）', () {
      expect(withoutSiteParam('/user/123?anon=1'), '/user/123');
    });

    test('同时去掉 site / as / anon，保留业务参数', () {
      expect(
        withoutSiteParam('/thread/1?site=a.com&as=bob&anon=1&page=2'),
        '/thread/1?page=2',
      );
    });

    test('没有站点类参数时原样返回', () {
      expect(withoutSiteParam('/user/123?page=2'), '/user/123?page=2');
    });
  });

  group('withSiteParam', () {
    test('跨站点参数仍按原格式生成（与 anon 互不干扰）', () {
      expect(withSiteParam('/user/123', 'a.com'), '/user/123?site=a.com');
    });
  });

  group('SessionRegistry.anonymousSessionForHost', () {
    test('未配置的站点返回 null（调用方退回全局会话，不抛异常）', () {
      expect(
        SessionRegistry.instance.anonymousSessionForHost('not-configured.test'),
        isNull,
      );
    });
  });

  group('入口的「页面接管」前置检查', () {
    // 「我的」页入口先跑 appPageRedirect：命中说明这页会被送去内置浏览器，
    // 而浏览器用登录态 —— 匿名入口会变成实名访问，必须拦住。
    SiteStore.instance.init();
    final host = SiteStore.instance.host;
    final repo = SettingsRepository.instance;

    void closeUserPage(bool disabled) {
      final s = repo.site(host);
      repo.debugSetSite(
        s.copyWith(
          pages: s.pages.copyWith(
            disabledPageIds: disabled ? {'user'} : const <String>{},
          ),
        ),
      );
    }

    tearDown(() => closeUserPage(false));

    test('用户主页开启时放行（anon 参数不影响识别）', () {
      closeUserPage(false);
      expect(appPageRedirect(withAnonParam('/user/123')), isNull);
    });

    test('关掉用户主页后会被回退到内置浏览器（此时应提示而非跳转）', () {
      closeUserPage(true);
      final redirect = appPageRedirect(withAnonParam('/user/123'));
      expect(redirect, isNotNull);
      // 回退地址是站内真实地址，不能把 anon 带进浏览器（它只认 URL）
      expect(redirect, isNot(contains('anon=')));
    });
  });
}
