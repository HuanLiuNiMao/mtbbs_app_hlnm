import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/config/update_config.dart';
import 'package:mtbbs/services/update_service.dart';

void main() {
  group('选包规则', () {
    const assets = [
      ReleaseAsset(
        name: 'MTBBS_android_1.2.0_arm64-v8a.apk',
        downloadUrl: 'apk-arm64',
      ),
      ReleaseAsset(
        name: 'MTBBS_android_1.2.0_armeabi-v7a.apk',
        downloadUrl: 'apk-arm',
      ),
      ReleaseAsset(
        name: 'MTBBS_android_1.2.0_x86_64.apk',
        downloadUrl: 'apk-x64',
      ),
      ReleaseAsset(
        name: 'MTBBS_windows_1.2.0_x64_setup.exe',
        downloadUrl: 'win-exe',
      ),
      ReleaseAsset(
        name: 'MTBBS_ohos_1.2.0_arm64-v8a.hap',
        downloadUrl: 'ohos-hap',
      ),
    ];

    List<AssetRule> rules(UpdatePlatform platform) =>
        UpdateConfig.defaultAssetRules[platform] ?? const [];

    test('Android 按设备 ABI 精确匹配', () {
      expect(
        UpdateService.selectAsset(
          assets,
          rules(UpdatePlatform.android),
          'armeabi-v7a',
        ),
        'apk-arm',
      );
      expect(
        UpdateService.selectAsset(
          assets,
          rules(UpdatePlatform.android),
          'x86_64',
        ),
        'apk-x64',
      );
    });

    test('Android ABI 无精确项时回退 arm64-v8a', () {
      expect(
        UpdateService.selectAsset(
          assets,
          rules(UpdatePlatform.android),
          'unknown-abi',
        ),
        'apk-arm64',
      );
    });

    test('鸿蒙选 .hap', () {
      expect(
        UpdateService.selectAsset(
          assets,
          rules(UpdatePlatform.ohos),
          'arm64-v8a',
        ),
        'ohos-hap',
      );
    });

    test('Windows 选 setup.exe', () {
      expect(
        UpdateService.selectAsset(
          assets,
          rules(UpdatePlatform.windows),
          'arm64-v8a',
        ),
        'win-exe',
      );
    });

    test('无匹配产物返回 null（由 UI 回退发布页）', () {
      expect(
        UpdateService.selectAsset(
          assets,
          rules(UpdatePlatform.other),
          'arm64-v8a',
        ),
        isNull,
      );
      expect(
        UpdateService.selectAsset(
          const [],
          rules(UpdatePlatform.android),
          'arm64-v8a',
        ),
        isNull,
      );
    });

    test('支持无前缀的 fork 产物命名', () {
      const forkAssets = [
        ReleaseAsset(name: 'app-release.apk', downloadUrl: 'fork-apk'),
      ];
      expect(
        UpdateService.selectAsset(
          forkAssets,
          rules(UpdatePlatform.android),
          'arm64-v8a',
        ),
        'fork-apk',
      );
    });

    test('同时发布签名/未签名时优先选已签名产物', () {
      const mixed = [
        ReleaseAsset(
          name: 'MTBBS_android_1.2.0_arm64-v8a_unsigned.apk',
          downloadUrl: 'apk-unsigned',
        ),
        ReleaseAsset(
          name: 'MTBBS_android_1.2.0_arm64-v8a.apk',
          downloadUrl: 'apk-signed',
        ),
      ];
      expect(
        UpdateService.selectAsset(
          mixed,
          rules(UpdatePlatform.android),
          'arm64-v8a',
        ),
        'apk-signed',
      );
    });

    test('只发布未签名产物时回退到 unsigned（不返回 null）', () {
      const onlyUnsigned = [
        ReleaseAsset(
          name: 'MTBBS_android_1.2.0_arm64-v8a_unsigned.apk',
          downloadUrl: 'apk-unsigned',
        ),
      ];
      expect(
        UpdateService.selectAsset(
          onlyUnsigned,
          rules(UpdatePlatform.android),
          'arm64-v8a',
        ),
        'apk-unsigned',
      );
      expect(
        UpdateService.isUnsignedAsset(
          'MTBBS_android_1.2.0_x86_64_unsigned.apk',
        ),
        isTrue,
      );
      expect(
        UpdateService.isUnsignedAsset('MTBBS_android_1.2.0_x86_64.apk'),
        isFalse,
      );
    });
  });

  group('自动检查限流', () {
    final now = DateTime(2026, 1, 1, 12);
    int secondsAt(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

    test('从未检查过 → 立即可检查', () {
      expect(UpdateService.autoCheckDue(0, now: now), isTrue);
    });

    test('1 小时内不重复检查', () {
      expect(
        UpdateService.autoCheckDue(
          secondsAt(now.subtract(const Duration(minutes: 59))),
          now: now,
        ),
        isFalse,
      );
    });

    test('超过 1 小时允许再次检查', () {
      expect(
        UpdateService.autoCheckDue(
          secondsAt(now.subtract(const Duration(hours: 1))),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('渠道策略', () {
    test('release 自动检查、可下载、拒绝 prerelease', () {
      final policy = UpdateConfig.defaultPolicies[UpdateChannel.release]!;
      expect(policy.autoCheck, isTrue);
      expect(policy.manualCheck, isTrue);
      expect(policy.canDownload, isTrue);
      expect(policy.includePrerelease, isFalse);
    });
    test('beta 同样自动检查、可下载（同源同签名，能覆盖安装）', () {
      final policy = UpdateConfig.defaultPolicies[UpdateChannel.beta]!;
      expect(policy.autoCheck, isTrue);
      expect(policy.manualCheck, isTrue);
      expect(policy.canDownload, isTrue);
      expect(policy.includePrerelease, isTrue);
    });
    test('恰好两个渠道，且各有策略', () {
      expect(UpdateChannel.values.length, 2);
      for (final channel in UpdateChannel.values) {
        expect(UpdateConfig.defaultPolicies.containsKey(channel), isTrue);
      }
    });
  });

  group('构建注入', () {
    test('未注入 mtbbs.repo → 不启用更新检查', () {
      expect(UpdateConfig.fromBuildConfig(), isNull);
    });

    test('渠道解析接受 GitHub 标记名与历史值', () {
      // 构建注入用的是 App 内部名 release / beta
      expect(UpdateConfig.parseChannel('release'), UpdateChannel.release);
      expect(UpdateConfig.parseChannel('BETA'), UpdateChannel.beta);
      // GitHub 的 Latest / Pre-release 标记名也能直接喂进来（命令行触发时省一次转换）
      expect(UpdateConfig.parseChannel('latest'), UpdateChannel.release);
      expect(UpdateConfig.parseChannel('Pre-Release'), UpdateChannel.beta);
      // 历史遗留的 debug 并入 beta，不能让老用户的渠道选择被静默清空
      expect(UpdateConfig.parseChannel(' debug '), UpdateChannel.beta);
      expect(UpdateConfig.parseChannel('nightly'), isNull);
      expect(UpdateConfig.parseChannel(''), isNull);
    });
  });
  group('更新渠道', () {
    const source = UpdateSource(owner: 'owner', name: 'repo');

    UpdateConfig cfg({UpdateChannel build = UpdateChannel.release}) =>
        UpdateConfig(source: source, buildChannel: build);

    test('展示名与说明齐全', () {
      expect(UpdateChannel.release.label, '稳定版');
      expect(UpdateChannel.beta.label, '测试版');
      for (final c in UpdateChannel.values) {
        expect(c.description, isNotEmpty);
      }
    });

    test('只有稳定版拒绝 prerelease', () {
      expect(UpdateChannel.release.includePrerelease, isFalse);
      expect(UpdateChannel.beta.includePrerelease, isTrue);
    });

    test('默认跟随构建渠道', () {
      final c = cfg(build: UpdateChannel.beta);
      expect(c.channel, UpdateChannel.beta);
      expect(c.buildChannel, UpdateChannel.beta);
      expect(c.isChannelOverridden, isFalse);
    });

    test('用户覆盖优先于构建渠道', () {
      final c = cfg(build: UpdateChannel.release).withChannel(
        UpdateChannel.beta,
      );
      expect(c.channel, UpdateChannel.beta);
      // 构建渠道是「本包是什么」，不能被覆盖改掉
      expect(c.buildChannel, UpdateChannel.release);
      expect(c.isChannelOverridden, isTrue);
    });

    test('withChannel(null) 恢复跟随构建', () {
      final overridden = cfg().withChannel(UpdateChannel.beta);
      expect(overridden.channel, UpdateChannel.beta);
      final restored = overridden.withChannel(null);
      expect(restored.channel, UpdateChannel.release);
      expect(restored.isChannelOverridden, isFalse);
    });

    test('策略随生效渠道变化', () {
      final release = cfg(build: UpdateChannel.release);
      expect(release.policy.autoCheck, isTrue);
      expect(release.policy.canDownload, isTrue);
      expect(release.policy.includePrerelease, isFalse);

      // 切到测试版：仍然自动检查、仍可下载，只是多了 prerelease
      final asBeta = release.withChannel(UpdateChannel.beta);
      expect(asBeta.policy.autoCheck, isTrue);
      expect(asBeta.policy.canDownload, isTrue);
      expect(asBeta.policy.includePrerelease, isTrue);
    });

    test('withChannel 保留更新源', () {
      final c = cfg().withChannel(UpdateChannel.beta);
      expect(c.source.owner, 'owner');
      expect(c.source.name, 'repo');
      expect(c.source.releasesApiUrl, contains('owner/repo'));
    });

    test('parseChannel 对未知值返回 null', () {
      expect(UpdateConfig.parseChannel('release'), UpdateChannel.release);
      expect(UpdateConfig.parseChannel('  BETA '), UpdateChannel.beta);
      expect(UpdateConfig.parseChannel('debug'), UpdateChannel.beta);
      expect(UpdateConfig.parseChannel(''), isNull);
      expect(UpdateConfig.parseChannel('nightly'), isNull);
    });
  });
}
