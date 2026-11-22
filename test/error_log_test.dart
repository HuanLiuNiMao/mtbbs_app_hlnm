import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/services/error_log/error_log_entry.dart';

/// 错误日志的**纯逻辑**部分：序列化往返与容错解析。
///
/// 文件读写依赖 path_provider，widget 测试跑不了（没有插件实现），
/// 所以落盘那一层由手测覆盖；这里只守住「格式演进不会让旧日志读不出来」
/// 这条最容易在改动中被破坏的契约。
void main() {
  group('ErrorLogEntry 序列化', () {
    test('往返一致：时间 / 错误 / 堆栈 / 来源 / 上下文', () {
      final at = DateTime(2026, 11, 22, 21, 30, 5);
      final entry = ErrorLogEntry(
        at: at,
        error: 'Bad state: boom',
        stackTrace: '#0      main (package:mtbbs/main.dart:1:1)',
        source: 'Flutter 框架',
        context: const {'库': 'widgets library'},
      );

      // 必须能过一遍真正的 JSON 编解码（落盘用的就是 jsonEncode）
      final decoded = jsonDecode(jsonEncode(entry.toMap())) as Map<String, dynamic>;
      final back = ErrorLogEntry.fromMap(decoded);

      expect(back.at, at);
      expect(back.error, entry.error);
      expect(back.stackTrace, entry.stackTrace);
      expect(back.source, entry.source);
      expect(back.context, entry.context);
    });

    test('空堆栈不写进 JSON（省体积），读回来是 null', () {
      final map = ErrorLogEntry(
        at: DateTime(2026, 1, 1),
        error: 'x',
        stackTrace: '',
      ).toMap();
      expect(map.containsKey('stack'), isFalse);
      expect(ErrorLogEntry.fromMap(map).stackTrace, isNull);
    });

    test('缺字段 / 类型不对时取默认值，不抛异常', () {
      // 这是长期累积文件的真实风险：手改过、旧版本写的、被截断的半行
      final back = ErrorLogEntry.fromMap(const {'error': 42, 'context': 'oops'});
      expect(back.error, '42');
      expect(back.stackTrace, isNull);
      expect(back.context, isEmpty);
      expect(back.source, '');
    });

    test('时间串非法时退回当前时间而不是 1970', () {
      final back = ErrorLogEntry.fromMap(const {
        'at': 'not-a-date',
        'error': 'x',
      });
      expect(
        back.at.difference(DateTime.now()).abs().inMinutes,
        lessThan(2),
      );
    });

    test('context 的 value 统一转成字符串', () {
      final back = ErrorLogEntry.fromMap(const {
        'error': 'x',
        'context': {'数量': 3, 'flag': true, 'nil': null},
      });
      expect(back.context, {'数量': '3', 'flag': 'true', 'nil': ''});
    });
  });

  group('title / format', () {
    test('title 取首个非空行', () {
      expect(
        ErrorLogEntry(
          at: DateTime(2026, 1, 1),
          error: '\n\n  Bad state: boom\n第二行',
        ).title,
        'Bad state: boom',
      );
    });

    test('全空错误也有可展示的标题', () {
      expect(ErrorLogEntry(at: DateTime(2026, 1, 1), error: '  \n ').title, '空错误');
    });

    test('format 含时间/来源/上下文/堆栈，且不带 markdown 围栏', () {
      final text = ErrorLogEntry(
        at: DateTime(2026, 11, 22, 21, 30, 5),
        error: 'Bad state: boom',
        stackTrace: '#0 main',
        source: '异步未捕获',
        context: const {'触发入口': '测试'},
      ).format();

      expect(text, contains('2026-11-22 21:30:05'));
      expect(text, contains('来源: 异步未捕获'));
      expect(text, contains('触发入口: 测试'));
      expect(text, contains('错误: Bad state: boom'));
      expect(text, contains('堆栈:'));
      expect(text, contains('#0 main'));
      // 围栏由调用方按需加，不然嵌套时会出现两层
      expect(text, isNot(contains('```')));
    });

    test('format 无堆栈时不留空尾巴', () {
      final text = ErrorLogEntry(
        at: DateTime(2026, 1, 1),
        error: 'x',
      ).format();
      expect(text.trimRight(), text);
      expect(text, isNot(contains('堆栈')));
    });

    test('formatDateTime 补零', () {
      expect(
        ErrorLogEntry.formatDateTime(DateTime(2026, 1, 2, 3, 4, 5)),
        '2026-01-02 03:04:05',
      );
    });
  });
}
