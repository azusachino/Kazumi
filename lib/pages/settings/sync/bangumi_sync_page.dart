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
  final _token = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _failed = false;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

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

  @override
  Widget build(BuildContext context) {
    final account = GStorage.bangumiAccount;
    return ValueListenableBuilder(
      valueListenable: account.settings.listenable(),
      builder: (context, _, _) => SettingsDetailScaffold(
      title: const Text('追番同步'),
      body: SyncPageBody(maxWidth: 720, children: [
        const SyncPageIntro(icon: Icons.bookmarks_rounded, title: 'Bangumi',
            description: '同步想看、在看、看过等追番状态。'),
        TonalCard(child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(account.isSignedIn ? '已登录 · ${account.username}' : '尚未登录'),
            const SizedBox(height: 16),
            TextField(controller: _token, enabled: !_busy, obscureText: true,
                autocorrect: false, enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Access Token', border: OutlineInputBorder())),
            Wrap(spacing: 12, children: [
              TextButton(onPressed: _busy ? null : () => _run(() async {
                await account.signInWithToken(_token.text);
                _token.clear();
                return '已登录 ${account.username}';
              }), child: const Text('验证并登录')),
              if (account.isOAuthAvailable)
                TextButton(onPressed: _busy ? null : () => _run(() async {
                  if (!await launchUrl(account.buildAuthorizeUrl(), mode: LaunchMode.externalApplication)) {
                    throw StateError('Cannot open browser');
                  }
                  return '请在浏览器中完成授权';
                }), child: const Text('使用 Bangumi 登录')),
              if (account.isSignedIn)
                TextButton(onPressed: _busy ? null : () => _run(() async {
                  await account.signOut();
                  return '已退出登录';
                }), child: const Text('退出登录')),
            ]),
          ]),
        )),
        FilledButton.icon(
          onPressed: _busy || !account.isSignedIn ? null : () => _run(() async {
            final count = await BangumiImport(account, account.tracker as BangumiTracker,
                CollectCrudRepository()).run();
            return '已导入 $count 部番剧';
          }),
          icon: const Icon(Icons.download_rounded), label: const Text('从 Bangumi 导入'),
        ),
        if (_message != null) SyncFeedback(message: _message!, error: _failed),
      ]),
      ),
    );
  }
}
