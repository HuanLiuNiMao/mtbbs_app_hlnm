import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/models/browse_record.dart';

BrowseRecord _user({
  String routePath = '/user/456',
  Map<String, dynamic> info = const {},
}) => BrowseRecord(
  id: 'a.com:user_456',
  host: 'a.com',
  type: 'user',
  routePath: routePath,
  timestamp: DateTime(2026, 1, 1),
  info: info,
);

void main() {
  group('BrowseRecord.userUid 三级兜底', () {
    test('优先用 info.uid', () {
      final r = _user(
        info: {
          'uid': '456',
          'url': 'https://a.com/home.php?mod=space&uid=999',
        },
      );
      expect(r.userUid, '456');
    });

    test('info 没有 uid 时回退到 routePath', () {
      expect(_user(routePath: '/user/789').userUid, '789');
    });

    test('前两级都取不到时从 url 推断（兼容各模板写法）', () {
      expect(
        _user(
          routePath: '',
          info: {'url': 'https://a.com/space-uid-321.html'},
        ).userUid,
        '321',
      );
      expect(
        _user(
          routePath: '',
          info: {'url': 'https://a.com/home.php?mod=space&uid=654'},
        ).userUid,
        '654',
      );
    });

    test('全部缺失时返回空串（UI 据此不渲染复制行）', () {
      expect(_user(routePath: '', info: const {}).userUid, '');
      expect(_user(routePath: '', info: {'url': 'not a url'}).userUid, '');
    });

    test('routePath 只认 /user/<数字>，不误吞其它路由', () {
      expect(_user(routePath: '/thread/456').userUid, '');
      expect(_user(routePath: '/user/abc').userUid, '');
    });

    test('自己的主页（uid=self）不产出可复制的 uid', () {
      // user_profile_page 记录自己的主页时固定写 uid: 'self'
      expect(_user(routePath: '/user/self', info: {'uid': 'self'}).userUid, '');
      expect(
        _user(
          routePath: '',
          info: {'uid': 'self', 'url': 'https://a.com/home.php?mod=space&uid=self'},
        ).userUid,
        '',
      );
    });
  });
}
