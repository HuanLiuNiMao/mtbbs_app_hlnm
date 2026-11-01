import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/services/backup/backup_web_client.dart';

/// Web 备份客户端里可纯逻辑验证的部分（不发网络请求）。
void main() {
  group('BackupWebClient.redactUrl', () {
    test('丢掉 query 与 fragment（避免 token 进日志）', () {
      expect(
        BackupWebClient.redactUrl('https://nas.local/backup.php?token=abc'),
        'https://nas.local/backup.php',
      );
      expect(
        BackupWebClient.redactUrl('https://nas.local/x#frag'),
        'https://nas.local/x',
      );
    });

    test('无 path 时补 /', () {
      expect(
        BackupWebClient.redactUrl('https://nas.local'),
        'https://nas.local/',
      );
    });

    test('无效地址回固定文案（不带异常原文）', () {
      expect(BackupWebClient.redactUrl(''), '（无效地址）');
      expect(BackupWebClient.redactUrl('not a url'), '（无效地址）');
    });
  });

  group('BackupUploadResult.shortResult', () {
    test('成功 / 失败文案', () {
      const ok = BackupUploadResult(ok: true, message: '已上传（HTTP 200）');
      expect(ok.shortResult, 'ok');
      const bad = BackupUploadResult(ok: false, message: '服务器返回 HTTP 500');
      expect(bad.shortResult, 'failed: 服务器返回 HTTP 500');
    });
  });
}
