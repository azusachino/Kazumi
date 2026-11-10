import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/widget/tonal_card.dart';
import 'package:kazumi/pages/settings/sync/sync_settings_widgets.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/tracking/bangumi_import.dart';
import 'package:kazumi/services/tracking/bangumi_tracker.dart';

class BangumiSyncPage extends StatefulWidget {
  const BangumiSyncPage({super.key});

  @override
  State<BangumiSyncPage> createState() => _BangumiSyncPageState();
}

class _BangumiSyncPageState extends State<BangumiSyncPage> {
  bool _busy = false;
  String? _message;
  bool _failed = false;

  Future<void> _run(Future<String> Function() action) async {
    if (_busy) return;
    setState(() { _busy = true; _message = null; _failed = false; });
    try {
      final message = await action();
      if (mounted) setState(() => _message = message);
    } catch (_) {
      if (mounted) setState(() { _failed = true; _message = '操作失败，请检查账号或网络'; });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _account({
    required String title,
    required String username,
    required bool signedIn,
    required bool oauthAvailable,
    required Future<void> Function() signOut,
    required Uri Function() authorizeUrl,
    Widget? extraAction,
  }) => TonalCard(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(signedIn
                ? '已登录 · $username'
                : oauthAvailable
                    ? '尚未登录'
                    : '此版本未配置 $title 应用，无法登录'),
            const SizedBox(height: 16),
            Wrap(spacing: 8, children: [
              if (oauthAvailable && !signedIn)
                TextButton(
                  onPressed: _busy ? null : () => _run(() async {
                    if (!await launchUrl(authorizeUrl(), mode: LaunchMode.externalApplication)) {
                      throw StateError('Cannot open browser');
                    }
                    return '请在浏览器中完成授权';
                  }),
                  child: const Text('浏览器授权登录'),
                ),
              if (signedIn)
                TextButton(
                  onPressed: _busy ? null : () => _run(() async {
                    await signOut();
                    return '已退出登录';
                  }),
                  child: const Text('退出登录'),
                ),
              ?extraAction,
            ]),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final bangumi = GStorage.bangumiAccount;
    final anilist = GStorage.anilistAccount;
    return AnimatedBuilder(
      animation: Listenable.merge([
        bangumi.settings.listenable(),
        anilist.settings.listenable(),
      ]),
      builder: (context, _) => SettingsDetailScaffold(
        title: const Text('追踪账号'),
        body: SyncPageBody(maxWidth: 720, children: [
          const SyncPageIntro(
            icon: Icons.sync_alt_rounded,
            title: '追踪账号',
            description: '管理 Bangumi 和 AniList 账号，追踪进度与收藏状态。',
          ),
          _account(
            title: 'Bangumi',
            username: bangumi.username,
            signedIn: bangumi.isSignedIn,
            oauthAvailable: bangumi.isOAuthAvailable,
            signOut: bangumi.signOut,
            authorizeUrl: bangumi.buildAuthorizeUrl,
            extraAction: FilledButton.tonalIcon(
              onPressed: _busy || !bangumi.isSignedIn ? null : () => _run(() async {
                final count = await BangumiImport(
                  bangumi,
                  bangumi.tracker as BangumiTracker,
                  CollectCrudRepository(),
                ).run();
                return '已从 Bangumi 导入 $count 部番剧';
              }),
              icon: const Icon(Icons.download_rounded),
              label: const Text('从 Bangumi 导入'),
            ),
          ),
          _account(
            title: 'AniList',
            username: anilist.username,
            signedIn: anilist.isSignedIn,
            oauthAvailable: anilist.isOAuthAvailable,
            signOut: anilist.signOut,
            authorizeUrl: anilist.buildAuthorizeUrl,
          ),
          if (_message != null) SyncFeedback(message: _message!, error: _failed),
        ]),
      ),
    );
  }
}
