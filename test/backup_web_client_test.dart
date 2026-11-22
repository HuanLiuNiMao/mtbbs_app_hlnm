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
    test('地址无尾斜杠时自动补，并落到默认目录 环版_MT论坛', () {
      final uri = BackupWebClient.resolveFileUri(
        const WebBackupConfig(uri: 'https://dav.jianguoyun.com/dav'),
      );
      // 用 pathSegments 比较：`path` 返回的是百分号编码后的文本，
      // 直接和中文常量比会失败，而跟编码串比又测不出「中文没被译错」。
      expect(uri.pathSegments, [
        'dav',
        WebBackupConfig.defaultDirectory,
        WebBackupConfig.defaultFileName,
      ]);
    });

    test('地址已带尾斜杠时不会拼出双斜杠', () {
      final uri = BackupWebClient.resolveFileUri(
        const WebBackupConfig(uri: 'https://dav.jianguoyun.com/dav/'),
      );
      expect(uri.path.contains('//'), isFalse);
      expect(uri.pathSegments.first, 'dav');
      expect(uri.pathSegments.length, 3);
    });

    test('默认目录不再叠一层 mtbbs（避免 环版_MT论坛/mtbbs/ 的双层结构）', () {
      final uri = BackupWebClient.resolveFileUri(
        const WebBackupConfig(
          uri: 'https://example.com/dav/',
          directory: WebBackupConfig.defaultDirectory,
        ),
      );
      expect(uri.pathSegments, [
        'dav',
        WebBackupConfig.defaultDirectory,
        WebBackupConfig.defaultFileName,
      ]);
      expect(uri.pathSegments.contains(WebBackupConfig.appFolder), isFalse);
    });

    test('自定义路径插在 mtbbs 之前（和默认目录区分开，互不冲突）', () {
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
      expect(folder.path.endsWith('/'), isTrue);
      // 末尾斜杠会让 pathSegments.last 是空串，目录名在倒数第二段
      expect(
        folder.pathSegments[folder.pathSegments.length - 2],
        WebBackupConfig.defaultDirectory,
      );
    });
  });

  group('远端子目录的默认值与向后兼容', () {
    test('构造时默认目录就是 环版_MT论坛', () {
      expect(
        const WebBackupConfig().directory,
        WebBackupConfig.defaultDirectory,
      );
    });

    test('老文档没有 directory 键 → 迁到新默认目录（而不是根目录）', () {
      final cfg = WebBackupConfig.fromMap({
        'uri': 'https://example.com/dav/',
        'username': 'u',
      });
      expect(cfg.directory, WebBackupConfig.defaultDirectory);
      expect(cfg.effectiveSegments, [WebBackupConfig.defaultDirectory]);
    });

    test('键存在但是空串（旧版默认值）也迁到新默认目录', () {
      // 旧版本的 directory 默认值就是空串，用户从没填过 → 应该跟随新默认
      final cfg = WebBackupConfig.fromMap({
        'uri': 'https://example.com/dav/',
        'directory': '',
      });
      expect(cfg.directory, WebBackupConfig.defaultDirectory);
    });

    test('纯空白的 directory 视为没填', () {
      final cfg = WebBackupConfig.fromMap({
        'uri': 'https://example.com/dav/',
        'directory': '   ',
      });
      expect(cfg.directory, WebBackupConfig.defaultDirectory);
    });

    test('多层自定义目录会保留层级并补 mtbbs 隔开', () {
      const cfg = WebBackupConfig(directory: 'a/b');
      expect(cfg.directorySegments, ['a', 'b']);
      expect(cfg.effectiveSegments, ['a', 'b', 'mtbbs']);
    });

    test('目录里的多余斜杠与空白会被规整掉', () {
      const cfg = WebBackupConfig(directory: ' /phone//backup/ ');
      expect(cfg.directorySegments, ['phone', 'backup']);
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
