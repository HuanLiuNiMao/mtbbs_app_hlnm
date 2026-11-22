import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/models/settings/backup_settings.dart';
import 'package:mtbbs/services/backup/backup_web_client.dart';

/// WebDAV 客户端的纯逻辑部分（路径拼装 / 脱敏）。
///
/// 网络层不在这里测：它需要真实 WebDAV 服务端，且失败分支已被
/// `BackupUploadResult` 收敛成「ok + 一句话」，用假服务器测反而是
/// 在测 dio 而不是测本项目的逻辑。
void main() {
  group('WebDAV 路径拼装', () {
    test('地址无尾斜杠时自动补，并追加 mtbbs/文件名', () {
      final uri = BackupWebClient.resolveFileUri(
        const WebBackupConfig(uri: 'https://dav.jianguoyun.com/dav'),
      );
      expect(
        uri.toString(),
        'https://dav.jianguoyun.com/dav/mtbbs/mtbbs_backup.json',
      );
    });

    test('地址已带尾斜杠时不会拼出双斜杠', () {
      final uri = BackupWebClient.resolveFileUri(
        const WebBackupConfig(uri: 'https://dav.jianguoyun.com/dav/'),
      );
      expect(uri.path, '/dav/mtbbs/mtbbs_backup.json');
    });

    test('自定义路径插在 mtbbs 之前', () {
      final uri = BackupWebClient.resolveFileUri(
        const WebBackupConfig(
          uri: 'https://example.com/dav/',
          directory: 'phone/backup',
        ),
      );
      expect(uri.path, '/dav/phone/backup/mtbbs/mtbbs_backup.json');
    });

    test('目录名里的中文与空格会被转义，不产生非法 URI', () {
      final uri = BackupWebClient.resolveFileUri(
        const WebBackupConfig(
          uri: 'https://example.com/dav/',
          directory: '我的 备份',
        ),
      );
      // 原始文本里是百分号编码，解析回来应还原成原文
      expect(uri.pathSegments, ['dav', '我的 备份', 'mtbbs', 'mtbbs_backup.json']);
    });

    test('路径里的 query / fragment 不会带进备份文件地址', () {
      final uri = BackupWebClient.resolveFileUri(
        const WebBackupConfig(uri: 'https://example.com/dav/?token=x#frag'),
      );
      expect(uri.query, isEmpty);
      expect(uri.hasFragment, isFalse);
    });

    test('目录地址结尾一定带斜杠（MKCOL 需要）', () {
      final folder = BackupWebClient.resolveFolderUri(
        const WebBackupConfig(uri: 'https://example.com/dav/'),
      );
      expect(folder.path, '/dav/mtbbs/');
    });
  });

  group('日志脱敏', () {
    test('保留 scheme/host/port/path', () {
      expect(
        BackupWebClient.redactUrl('https://dav.jianguoyun.com:8443/dav/x'),
        'https://dav.jianguoyun.com:8443/dav/x',
      );
    });

    test('丢掉 query 与 fragment（令牌常被塞在这里）', () {
      expect(
        BackupWebClient.redactUrl(
          'https://dav.example.com/dav/?token=SECRET#a',
        ),
        'https://dav.example.com/dav/',
      );
    });

    test('丢掉 userinfo（用户可能写成 user:pass@host）', () {
      final redacted = BackupWebClient.redactUrl(
        'https://me:app-token@dav.example.com/dav/',
      );
      expect(redacted, 'https://dav.example.com/dav/');
      expect(redacted.contains('app-token'), isFalse);
    });

    test('空地址/非法地址回固定文案，不回显输入', () {
      expect(BackupWebClient.redactUrl(''), '（无效地址）');
      expect(BackupWebClient.redactUrl('not a url'), '（无效地址）');
    });
  });

  group('配置可用性', () {
    test('缺用户名时上传前置校验就拦下（不发请求）', () async {
      final result = await BackupWebClient.instance.upload(
        '{}',
        const WebBackupConfig(uri: 'https://example.com/dav/'),
      );
      expect(result.ok, isFalse);
      expect(result.message, '未填写用户名');
    });

    test('地址非法时上传前置校验就拦下', () async {
      final result = await BackupWebClient.instance.upload(
        '{}',
        const WebBackupConfig(uri: 'ftp://example.com/dav/', username: 'u'),
      );
      expect(result.ok, isFalse);
      expect(result.message, '未填写有效的 WebDAV 地址');
    });
  });
}
