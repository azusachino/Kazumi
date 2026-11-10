import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/tracking/models.dart';
import 'package:kazumi/services/tracking/tracker.dart';
import 'package:kazumi/pages/info/anilist_search_page.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> showTrackingSheet(BuildContext context, BangumiItem item) =>
    showAdaptiveBottomSheet<void>(
      context: context,
      maxHeightFactor: 0.9,
      builder: (_) => TrackingSheet(item: item),
    );

class TrackingSheet extends StatefulWidget {
  const TrackingSheet({super.key, required this.item});
  final BangumiItem item;

  @override
  State<TrackingSheet> createState() => _TrackingSheetState();
}

class _TrackingSheetState extends State<TrackingSheet> {
  final Map<String, RemoteEntry?> _remote = {};
  final Set<String> _reading = {};
  final Set<String> _loaded = {};
  late final _bindingChanges = GStorage.trackingBindings.listenable();
  late final _outboxChanges = GStorage.trackingOutbox.listenable();

  @override
  void initState() {
    super.initState();
    _bindingChanges.addListener(_refresh);
    _outboxChanges.addListener(_refresh);
  }

  @override
  void dispose() {
    _bindingChanges.removeListener(_refresh);
    _outboxChanges.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    _loaded.clear();
    if (mounted) setState(() {});
  }

  String _status(TrackStatus status) => switch (status) {
    TrackStatus.planning => '想看',
    TrackStatus.current => '在看',
    TrackStatus.completed => '看过',
    TrackStatus.paused => '搁置',
    TrackStatus.dropped => '抛弃',
  };

  Future<void> _read(TrackingBinding binding) async {
    if (_reading.contains(binding.key) || _loaded.contains(binding.key)) return;
    _reading.add(binding.key);
    try {
      final token = binding.trackerId == TrackerId.bangumi
          ? await GStorage.bangumiAccount.validToken()
          : await GStorage.anilistAccount.validToken();
      if (token == null) return;
      final tracker = binding.trackerId == TrackerId.bangumi
          ? GStorage.trackingSync.trackers[TrackerId.bangumi]!
          : GStorage.trackingSync.trackers[TrackerId.anilist]!;
      final entry = await tracker.readEntry(token, binding.remoteId);
      _loaded.add(binding.key);
      if (mounted) setState(() => _remote[binding.key] = entry);
    } catch (_) {
      // The last locally known progress remains useful while offline.
      _loaded.add(binding.key);
    } finally {
      _reading.remove(binding.key);
    }
  }

  Future<void> _editNumber(
    String title,
    int initial,
    ValueChanged<int> save, {
    int? maximum,
  }) async {
    final value = await showDialog<int>(
      context: context,
      builder: (_) => _TrackingNumberDialog(
        title: title,
        initial: initial,
        maximum: maximum,
      ),
    );
    if (value != null) save(value);
  }

  Future<void> _remove(TrackingBinding binding) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除绑定？'),
        content: Text(binding.trackerId == TrackerId.bangumi
            ? '此番剧不会再被自动追踪。只移除此设备上的绑定，远端追番列表不会改变。'
            : '只会移除此设备上的绑定，远端追番列表不会改变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    if (binding.trackerId == TrackerId.bangumi) {
      await GStorage.bangumiBindingManager.stopTracking(binding.subjectId);
    } else {
      await GStorage.anilistBindingManager.unbind(binding.subjectId);
    }
  }

  Future<void> _editOffset(TrackingBinding binding, int value) async {
    await GStorage.bangumiBindingManager.bindings.put(
      TrackingBinding(
        subjectId: binding.subjectId,
        trackerId: binding.trackerId,
        remoteId: binding.remoteId,
        episodeOffset: value,
        statusLocked: binding.statusLocked,
        score: binding.score,
        lastRemoteProgress: binding.lastRemoteProgress,
        lastSyncAt: binding.lastSyncAt,
        title: binding.title,
        cover: binding.cover,
        total: binding.total,
      ),
    );
    await GStorage.trackingSync.drain();
  }

  Future<void> _editStatus(TrackingBinding binding, TrackStatus status) =>
      GStorage.trackingSync.enqueue(
        binding.subjectId,
        status: status,
        trackerId: binding.trackerId,
      );

  Future<void> _editProgress(TrackingBinding binding, int progress) {
    // The sync engine adds the offset, so convert this remote count to local numbering.
    final localProgress = progress > binding.episodeOffset
        ? progress - binding.episodeOffset
        : 0;
    return GStorage.trackingSync.enqueue(
      binding.subjectId,
      progress: localProgress,
      trackerId: binding.trackerId,
    );
  }

  Future<void> _editScore(TrackingBinding binding, int score) =>
      GStorage.trackingSync.enqueue(
        binding.subjectId,
        score: score * 10,
        trackerId: binding.trackerId,
      );

  Future<void> _openRemote(TrackingBinding binding) async {
    final uri = binding.trackerId == TrackerId.bangumi
        ? Uri.https('bgm.tv', '/subject/${binding.remoteId}')
        : Uri.https('anilist.co', '/anime/${binding.remoteId}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
    child: ListView(
      shrinkWrap: true,
      children: [
        Text('追踪', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        for (final id in TrackerId.values) _buildTrackerRow(id),
      ],
    ),
  );

  Widget _buildTrackerRow(TrackerId id) {
    final isBangumi = id == TrackerId.bangumi;
    final signedIn = isBangumi
        ? GStorage.bangumiAccount.isSignedIn
        : GStorage.anilistAccount.isSignedIn;
    final name = isBangumi ? 'Bangumi' : 'AniList';
    final username = isBangumi
        ? GStorage.bangumiAccount.username
        : GStorage.anilistAccount.username;
    final key = '${widget.item.id}:${id.name}';
    final binding = GStorage.trackingBindings.get(key);
    if (!signedIn) {
      return ListTile(
        leading: Icon(
          isBangumi ? Icons.bookmarks_outlined : Icons.movie_outlined,
        ),
        title: Text(name),
        subtitle: const Text('尚未登录'),
        trailing: TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            context.pushNamed('/settings/bangumi/');
          },
          child: const Text('前往设置'),
        ),
      );
    }
    if (binding == null) {
      return ListTile(
        leading: Icon(
          isBangumi ? Icons.bookmarks_outlined : Icons.movie_outlined,
        ),
        title: Text(name),
        subtitle: Text(username),
        trailing: TextButton(
          onPressed: () {
            if (isBangumi) {
              GStorage.bangumiBindingManager.startTracking(widget.item);
            } else {
              showAniListSearchSheet(context, widget.item);
            }
          },
          child: Text(isBangumi ? '开始追踪' : '搜索并绑定'),
        ),
      );
    }
    _read(binding);
    final pending = GStorage.trackingOutbox.get(key);
    final entry = _remote[key];
    final progress = entry?.progress ?? binding.lastRemoteProgress ?? 0;
    final total = entry?.total ?? binding.total;
    final title = binding.title?.isNotEmpty == true ? binding.title! : name;
    final syncLabel = pending == null
        ? (binding.lastSyncAt == null
              ? '等待同步'
              : '已同步 ${_date(binding.lastSyncAt!)}')
        : pending.error != null
        ? '同步失败：${pending.error}'
        : pending.retryAt != null
        ? '将在 ${_date(pending.retryAt!)} 重试'
        : '等待同步';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$name · $title',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  onSelected: (action) {
                    if (action == 'open') {
                      _openRemote(binding);
                    }
                    if (action == 'search') {
                      showAniListSearchSheet(
                        context,
                        widget.item,
                        rebind: true,
                      );
                    }
                    if (action == 'remove') {
                      _remove(binding);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'open', child: Text('在浏览器中打开')),
                    if (!isBangumi)
                      const PopupMenuItem(
                        value: 'search',
                        child: Text('搜索并重新绑定'),
                      ),
                    const PopupMenuItem(value: 'remove', child: Text('移除绑定')),
                  ],
                ),
              ],
            ),
            Text(
              '$progress / ${total ?? '未知'} 话 · ${entry == null ? '状态未知' : _status(entry.status)} · ${entry?.score == null ? '未评分' : '评分 ${entry!.score! / 10}'}',
            ),
            Text(
              syncLabel,
              style: TextStyle(
                color: pending?.error == null
                    ? null
                    : Theme.of(context).colorScheme.error,
              ),
            ),
            Wrap(
              spacing: 4,
              children: [
                DropdownButton<TrackStatus>(
                  value: entry?.status,
                  hint: const Text('状态'),
                  items: TrackStatus.values
                      .map(
                        (status) => DropdownMenuItem(
                          value: status,
                          child: Text(_status(status)),
                        ),
                      )
                      .toList(),
                  onChanged: (status) {
                    if (status != null) _editStatus(binding, status);
                  },
                ),
                TextButton(
                  onPressed: () => _editNumber(
                    '已看集数',
                    progress,
                    (value) => _editProgress(binding, value),
                  ),
                  child: const Text('进度'),
                ),
                TextButton(
                  onPressed: () => _editNumber(
                    '评分（0–10）',
                    (entry?.score ?? binding.score ?? 0) ~/ 10,
                    (value) => _editScore(binding, value),
                    maximum: 10,
                  ),
                  child: Text(
                    '评分 ${(entry?.score ?? binding.score ?? 0) / 10}',
                  ),
                ),
                TextButton(
                  onPressed: () => _editNumber(
                    '集数偏移',
                    binding.episodeOffset,
                    (value) => _editOffset(binding, value),
                  ),
                  child: Text('偏移 ${binding.episodeOffset}'),
                ),
                if (pending?.error != null)
                  TextButton(
                    onPressed: () => GStorage.trackingSync.retryFailed(id),
                    child: const Text('重试'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _date(DateTime date) =>
      '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

class _TrackingNumberDialog extends StatefulWidget {
  const _TrackingNumberDialog({
    required this.title,
    required this.initial,
    this.maximum,
  });

  final String title;
  final int initial;
  final int? maximum;

  @override
  State<_TrackingNumberDialog> createState() => _TrackingNumberDialogState();
}

class _TrackingNumberDialogState extends State<_TrackingNumberDialog> {
  late final _controller = TextEditingController(text: '${widget.initial}');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      keyboardType: TextInputType.number,
      autofocus: true,
      decoration: const InputDecoration(border: OutlineInputBorder()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final parsed = int.tryParse(_controller.text);
          if (parsed != null &&
              parsed >= 0 &&
              (widget.maximum == null || parsed <= widget.maximum!)) {
            Navigator.pop(context, parsed);
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}
