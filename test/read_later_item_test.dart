import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/models/read_later_item.dart';

void main() {
  group('ReadLaterItem', () {
    test('id 含站点与类型，跨站同号互不覆盖', () {
      expect(
        ReadLaterItem.buildId('a.com', 'thread', '123'),
        'a.com:thread:123',
      );
      expect(
        ReadLaterItem.buildId('a.com', 'thread', '123'),
        isNot(ReadLaterItem.buildId('b.com', 'thread', '123')),
      );
      expect(
        ReadLaterItem.buildId('a.com', 'thread', '123'),
        isNot(ReadLaterItem.buildId('a.com', 'user', '123')),
      );
    });

    test('JSON 往返保留全部字段', () {
      final item = ReadLaterItem(
        id: 'a.com:thread:123',
        host: 'a.com',
        type: 'thread',
        targetId: '123',
        routePath: '/thread/123',
        title: '标题',
        subtitle: '作者',
        authorUid: '456',
        url: 'https://a.com/forum.php?mod=viewthread&tid=123',
        page: 3,
        read: true,
        addedAt: DateTime(2026, 1, 2, 3, 4, 5),
        updatedAt: DateTime(2026, 1, 3, 3, 4, 5),
      );

      final restored = ReadLaterItem.fromJson(item.toJson());
      expect(restored.id, item.id);
      expect(restored.host, item.host);
      expect(restored.type, item.type);
      expect(restored.targetId, item.targetId);
      expect(restored.routePath, item.routePath);
      expect(restored.title, item.title);
      expect(restored.subtitle, item.subtitle);
      expect(restored.authorUid, item.authorUid);
      expect(restored.url, item.url);
      expect(restored.page, item.page);
      expect(restored.read, item.read);
      expect(restored.addedAt, item.addedAt);
      expect(restored.updatedAt, item.updatedAt);
    });

    test('缺字段的旧数据按默认值恢复', () {
      final restored = ReadLaterItem.fromJson(const {'id': 'x:thread:1'});
      expect(restored.page, 1);
      expect(restored.read, false);
      expect(restored.title, '');
      expect(restored.host, '');
    });

    test('copyWith 保留不可变字段', () {
      final item = ReadLaterItem(
        id: 'a.com:user:1',
        host: 'a.com',
        type: 'user',
        targetId: '1',
        routePath: '/user/1',
        title: '旧昵称',
        addedAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      final next = item.copyWith(title: '新昵称', read: true, page: 2);
      expect(next.id, item.id);
      expect(next.type, 'user');
      expect(next.title, '新昵称');
      expect(next.read, true);
      expect(next.page, 2);
      expect(next.addedAt, item.addedAt);
    });
  });
}
