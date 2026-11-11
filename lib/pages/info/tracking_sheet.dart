import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/widget/tracker_logo.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_title.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/pages/info/anilist_search_page.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/tracking/models.dart';
import 'package:kazumi/services/tracking/tracker.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> showTrackingSheet(BuildContext context, BangumiItem item) =>
    showAdaptiveBottomSheet<void>(
      context: context,
      maxHeightFactor: 0.9,
      builder: (_) => TrackingSheet(item: item),
    );

class TrackingSheet extends StatefulWidget {
  const TrackingSheet({
    super.key,
    required this.item,
    this.onRemoveBinding,
    this.onMirrorStatus,
  });
  final BangumiItem item;
  final Future<void> Function(TrackingBinding binding)? onRemoveBinding;

  /// Test seam: the real mirror is a local Hive write, which cannot run inside
  /// a widget-test zone. Production leaves this null.
  final Future<void> Function(BangumiItem item, CollectType type)? onMirrorStatus;

  @override
  State<TrackingSheet> createState() => _TrackingSheetState();
}

class _TrackingSheetState extends State<TrackingSheet> {
  final _collectController = inject<CollectController>();
  int _revision = 0;
  final Set<String> _reading = {};
  final Set<String> _loaded = {};
  final Set<String> _readErrors = {};
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
    _revision++;
    _loaded.clear();
    _readErrors.clear();
    if (mounted) setState(() {});
  }

  CollectType _collectTypeFor(TrackStatus status) => switch (status) {
    TrackStatus.planning => CollectType.planToWatch,
    TrackStatus.current => CollectType.watching,
    TrackStatus.completed => CollectType.watched,
    TrackStatus.paused => CollectType.onHold,
    TrackStatus.dropped => CollectType.abandoned,
  };

  String _status(TrackStatus status) => switch (status) {
    TrackStatus.planning => '想看',
    TrackStatus.current => '在看',
    TrackStatus.completed => '看过',
    TrackStatus.paused => '搁置',
    TrackStatus.dropped => '抛弃',
  };

  Future<void> _read(TrackingBinding binding, {bool force = false}) async {
    if (_reading.contains(binding.key)) return;
    final cache = GStorage.trackingEntryCache;
    final snapshot = cache.get(binding);
    if (!force) {
      // A fresh snapshot renders immediately and needs no network read.
      if (snapshot != null && snapshot.isFresh(DateTime.now())) {
        _loaded.add(binding.key);
        _readErrors.remove(binding.key);
        return;
      }
      if (_loaded.contains(binding.key)) return;
    }
    _reading.add(binding.key);
    final revision = _revision;
    final scope = cache.scopeFor(binding.trackerId);
    try {
      final token = binding.trackerId == TrackerId.bangumi
          ? await GStorage.bangumiAccount.validToken()
          : await GStorage.anilistAccount.validToken();
      if (token == null) throw const TrackerAuthException();
      final entry = await GStorage.trackingSync.trackers[binding.trackerId]!
          .readEntry(token, binding.remoteId);
      if (revision == _revision &&
          mounted &&
          GStorage.trackingBindings.get(binding.key)?.generation ==
              binding.generation) {
        // Always keyed to the account captured before the read, so a response
        // that crosses a sign-in cannot populate the new account.
        await cache.put(binding, entry, DateTime.now(), scope: scope);
        // Persisting the row can outlive this sheet or its binding.
        if (!mounted ||
            revision != _revision ||
            scope != cache.scopeFor(binding.trackerId) ||
            GStorage.trackingBindings.get(binding.key)?.generation !=
                binding.generation) {
          return;
        }
        _loaded.add(binding.key);
        _readErrors.remove(binding.key);
        setState(() {});
      }
    } catch (_) {
      if (revision == _revision && mounted) {
        setState(() {
          _loaded.add(binding.key);
          _readErrors.add(binding.key);
        });
      }
    } finally {
      _reading.remove(binding.key);
      if (mounted && revision != _revision) setState(() {});
    }
  }

  Future<void> _remove(TrackingBinding binding) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除绑定？'),
        content: Text(
          binding.trackerId == TrackerId.bangumi
              ? '此番剧不会再被自动追踪。只移除此设备上的绑定，远端追番列表不会改变。'
              : '只会移除此设备上的绑定，远端追番列表不会改变。',
        ),
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
    final onRemoveBinding = widget.onRemoveBinding;
    if (onRemoveBinding != null) {
      await onRemoveBinding(binding);
    } else if (binding.trackerId == TrackerId.bangumi) {
      await GStorage.bangumiBindingManager.stopTracking(binding.subjectId);
    } else {
      await GStorage.anilistBindingManager.unbind(binding.subjectId);
    }
  }

  Future<void> _editOffset(TrackingBinding binding) async {
    final value = await showDialog<int>(
      context: context,
      builder: (_) =>
          _NumberDialog(title: '集数偏移', initial: binding.episodeOffset),
    );
    if (value == null) return;
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
        updatedAt: DateTime.now(),
        // New generation: writes queued under the old offset are dropped,
        // since progress sent with a wrong offset could never be lowered.
      ),
    );
    await GStorage.trackingSync.drain();
  }

  Future<void> _selectStatus(
    TrackingBinding binding,
    TrackStatus? initial,
  ) async {
    var selected = initial ?? TrackStatus.planning;
    final result = await showDialog<TrackStatus>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('状态'),
          content: SingleChildScrollView(
            child: RadioGroup<TrackStatus>(
              groupValue: selected,
              onChanged: (value) {
                if (value != null) setDialogState(() => selected = value);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final status in TrackStatus.values)
                    RadioListTile<TrackStatus>(
                      value: status,
                      title: Text(_status(status)),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, selected),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    await GStorage.trackingSync.enqueue(
      binding.subjectId,
      status: result,
      trackerId: binding.trackerId,
    );
    // The drawer writes one tracker; the local library (what 追番 lists) has to
    // follow, or a show set to 在看 here never appears under 追番 > 在看.
    final localType = _collectTypeFor(result);
    if (_collectController.getCollectType(widget.item) == localType.value) {
      return;
    }
    final seam = widget.onMirrorStatus;
    final mirror = seam != null
        ? seam(widget.item, localType)
        : _collectController.addCollectFromTracker(
            widget.item,
            localType.value,
          );
    unawaited(
      mirror.catchError((Object e) {
        KazumiLogger().e(
          'Tracking: failed to mirror status into the library',
          error: e,
        );
      }),
    );
  }

  Future<void> _selectNumber(
    TrackingBinding binding,
    String title,
    int initial, {
    int? maximum,
    bool score = false,
  }) async {
    final result = await showDialog<int>(
      context: context,
      builder: (_) => _NumberDialog(
        title: title,
        initial: initial,
        maximum: maximum,
        score: score,
      ),
    );
    if (result == null || (score && result == 0)) return;
    if (score) {
      await GStorage.trackingSync.enqueue(
        binding.subjectId,
        score: result * 10,
        trackerId: binding.trackerId,
      );
    } else {
      final localProgress = result > binding.episodeOffset
          ? result - binding.episodeOffset
          : 0;
      await GStorage.trackingSync.enqueue(
        binding.subjectId,
        progress: localProgress,
        trackerId: binding.trackerId,
      );
    }
  }

  Uri _uri(TrackingBinding binding) => binding.trackerId == TrackerId.bangumi
      ? Uri.https('bgm.tv', '/subject/${binding.remoteId}')
      : Uri.https('anilist.co', '/anime/${binding.remoteId}');

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已复制')));
    }
  }

  void _open(TrackingBinding binding) =>
      launchUrl(_uri(binding), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final ids = [
      if (GStorage.bangumiAccount.isSignedIn) TrackerId.bangumi,
      if (GStorage.anilistAccount.isSignedIn) TrackerId.anilist,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: ListView(
        shrinkWrap: true,
        children: [
          Text('追踪', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          if (ids.isEmpty) ...[
            const Text('尚未登录追踪账号'),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                context.pushNamed('/settings/bangumi/');
              },
              child: const Text('追踪账号'),
            ),
          ],
          for (final id in ids)
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: _buildTracker(id),
            ),
        ],
      ),
    );
  }

  Widget _logo(TrackerId id) => TrackerLogo(trackerId: id);

  Widget _buildTracker(TrackerId id) {
    final key = '${widget.item.id}:${id.name}';
    final binding = GStorage.trackingBindings.get(key);
    if (binding == null) {
      return Row(
        children: [
          _logo(id),
          const SizedBox(width: 16),
          Expanded(
            child: TextButton(
              onPressed: () {
                if (id == TrackerId.bangumi) {
                  GStorage.bangumiBindingManager.startTracking(widget.item);
                } else {
                  showAniListSearchSheet(context, widget.item);
                }
              },
              child: const Text('添加追踪'),
            ),
          ),
        ],
      );
    }
    _read(binding);
    final snapshot = GStorage.trackingEntryCache.get(binding);
    // A remembered null entry means the tracker has nothing for this subject;
    // a missing snapshot means this device has not read it yet.
    final known = snapshot != null || _loaded.contains(key);
    final stale =
        snapshot != null && !snapshot.isFresh(DateTime.now());
    final entry = snapshot?.entry;
    final queued = GStorage.trackingOutbox.get(key);
    final pending = queued?.bindingGeneration == binding.generation &&
            queued?.remoteId == binding.remoteId
        ? queued
        : null;
    final status = pending?.status ?? entry?.status;
    final progress = pending?.progress ??
        entry?.progress ??
        (snapshot != null ? 0 : binding.lastRemoteProgress ?? 0);
    final total = entry?.total ?? binding.total;
    final score = pending?.score ??
        entry?.score ??
        (snapshot != null ? null : binding.score);
    final title = id == TrackerId.bangumi
        ? widget.item.displayTitle
        : (binding.title?.isNotEmpty == true ? binding.title! : 'AniList');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            GestureDetector(
              onTap: () => _open(binding),
              onLongPress: () => _copy(_uri(binding).toString()),
              child: _logo(id),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: InkWell(
                onTap: id == TrackerId.anilist
                    ? () => showAniListSearchSheet(
                        context,
                        widget.item,
                        rebind: true,
                      )
                    : null,
                onLongPress: () => _copy(title),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32, child: VerticalDivider()),
            PopupMenuButton<String>(
              tooltip: '更多操作',
              onSelected: (action) async {
                switch (action) {
                  case 'open':
                    _open(binding);
                  case 'copy':
                    _copy(_uri(binding).toString());
                  case 'offset':
                    _editOffset(binding);
                  case 'refresh':
                    await GStorage.trackingEntryCache.remove(binding);
                    setState(() {
                      _loaded.remove(binding.key);
                      _readErrors.remove(binding.key);
                    });
                    await _read(binding, force: true);
                  case 'remove':
                    await _remove(binding);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'open', child: Text('在浏览器中打开')),
                PopupMenuItem(value: 'copy', child: Text('复制链接')),
                PopupMenuItem(value: 'offset', child: Text('集数偏移')),
                PopupMenuItem(value: 'refresh', child: Text('刷新状态')),
                PopupMenuItem(value: 'remove', child: Text('移除')),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: IntrinsicHeight(
            child: Row(
              children: [
                _cell(
                  status != null ? _status(status) :
                      _readErrors.contains(key) ? '读取失败' :
                      known ? '状态' : '读取中…',
                  () => _selectStatus(binding, status),
                ),
                const VerticalDivider(width: 1),
                _cell(
                  total != null && total > 0
                      ? '$progress / $total'
                      : '$progress',
                  () => _selectNumber(
                    binding,
                    '已看集数',
                    progress,
                    maximum: total != null && total > 0 ? total : null,
                  ),
                ),
                const VerticalDivider(width: 1),
                _cell(
                  score == null || score == 0 ? '评分' : '${score / 10}',
                  () => _selectNumber(
                    binding,
                    '评分',
                    (score ?? 0) ~/ 10,
                    maximum: 10,
                    score: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (stale && !_readErrors.contains(key) && _reading.contains(key))
          Text(
            '正在刷新追踪状态…',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        if (_readErrors.contains(key))
          Row(
            children: [
              const Expanded(child: Text('无法读取追踪状态')),
              TextButton(
                onPressed: () {
                  setState(() {
                    _loaded.remove(key);
                    _readErrors.remove(key);
                  });
                  _read(binding, force: true);
                },
                child: const Text('重新读取'),
              ),
            ],
          ),
        if (pending != null)
          Row(
            children: [
              Expanded(
                child: Text(
                  pending.error == null ? '等待同步' : '同步失败：${pending.error}',
                  style: TextStyle(
                    color: pending.error == null
                        ? null
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
              if (pending.error != null)
                TextButton(
                  onPressed: () => GStorage.trackingSync.retryFailed(id),
                  child: const Text('重试'),
                ),
            ],
          ),
      ],
    );
  }

  Widget _cell(String text, VoidCallback onTap) => Expanded(
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
        child: Text(
          text,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
  );
}

class _NumberDialog extends StatefulWidget {
  const _NumberDialog({
    required this.title,
    required this.initial,
    this.maximum,
    this.score = false,
  });
  final String title;
  final int initial;
  final int? maximum;
  final bool score;

  @override
  State<_NumberDialog> createState() => _NumberDialogState();
}

class _NumberDialogState extends State<_NumberDialog> {
  late int selected = widget.maximum == null
      ? widget.initial
      : widget.initial.clamp(0, widget.maximum!);
  late final _controller = TextEditingController(text: '$selected');
  late final _wheel = FixedExtentScrollController(initialItem: selected);

  @override
  void dispose() {
    _controller.dispose();
    _wheel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: widget.maximum == null
        ? TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          )
        : SizedBox(
            // Material dialog width, not the whole tablet: a full-width
            // number wheel reads as a page, not a selector.
            width: math.min(
              320,
              MediaQuery.sizeOf(context).width - 120,
            ),
            height: 200,
            child: Stack(
              alignment: Alignment.center,
              children: [
                IgnorePointer(
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                ListWheelScrollView.useDelegate(
                  controller: _wheel,
                  itemExtent: 40,
                  physics: const FixedExtentScrollPhysics(),
                  onSelectedItemChanged: (value) => setState(() => selected = value),
                  childDelegate: ListWheelChildBuilderDelegate(
                    childCount: widget.maximum! + 1,
                    builder: (context, index) => Semantics(
                      selected: index == selected,
                      label: '${widget.title}：$index',
                      child: Center(
                        child: Text(
                          widget.score && index == 0 ? '不评分' : '$index',
                          style: TextStyle(
                            fontSize: index == selected ? 24 : 18,
                            fontWeight: index == selected ? FontWeight.bold : FontWeight.normal,
                            color: index == selected
                                ? Theme.of(context).colorScheme.onSecondaryContainer
                                : Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () {
          final value = widget.maximum == null
              ? int.tryParse(_controller.text)
              : selected;
          if (value != null && value >= 0) Navigator.pop(context, value);
        },
        child: const Text('确定'),
      ),
    ],
  );
}
