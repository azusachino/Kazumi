import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/tracking/tracker.dart';

Future<void> showAniListSearchSheet(
  BuildContext context,
  BangumiItem item, {
  bool rebind = false,
}) => showAdaptiveBottomSheet<void>(
  context: context,
  maxHeightFactor: 0.9,
  builder: (_) => AniListSearchPage(item: item, rebind: rebind),
);

class AniListSearchPage extends StatefulWidget {
  const AniListSearchPage({super.key, required this.item, this.rebind = false});
  final BangumiItem item;
  final bool rebind;

  @override
  State<AniListSearchPage> createState() => _AniListSearchPageState();
}

class _AniListSearchPageState extends State<AniListSearchPage> {
  late final _query = TextEditingController(
    text: widget.item.nameCn.isNotEmpty ? widget.item.nameCn : widget.item.name,
  );
  List<TrackerSearchResult> _results = const [];
  String? _error;
  bool _busy = false;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_busy || _query.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _selected = null;
    });
    try {
      final results = await GStorage.anilistAccount.tracker.search(
        _query.text.trim(),
        token: await GStorage.anilistAccount.validToken(),
      );
      if (mounted) setState(() => _results = results);
    } catch (_) {
      if (mounted) setState(() => _error = '搜索失败，请检查账号或网络');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bind(TrackerSearchResult result) async {
    setState(() => _busy = true);
    try {
      if (widget.rebind) {
        await GStorage.anilistBindingManager.rebind(widget.item, result);
      } else {
        await GStorage.anilistBindingManager.bind(widget.item, result);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '绑定失败，请稍后重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _query,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: const InputDecoration(labelText: '搜索 AniList'),
              ),
            ),
            IconButton(
              tooltip: '搜索',
              onPressed: _busy ? null : _search,
              icon: const Icon(Icons.search),
            ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Flexible(
          child: RadioGroup<String>(
            groupValue: _selected,
            onChanged: (value) => setState(() => _selected = value),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _results.length,
              itemBuilder: (context, index) {
                final result = _results[index];
                final subtitle = [
                  if (result.subtitle?.isNotEmpty ?? false) result.subtitle!,
                  if (result.format?.isNotEmpty ?? false) result.format!,
                  if (result.seasonYear != null) '${result.seasonYear}',
                  if (result.episodes != null) '${result.episodes} 话',
                ].join(' · ');
                return RadioListTile<String>(
                  value: result.id,
                  title: Text(result.title),
                  subtitle: Text(subtitle),
                  secondary: result.cover == null
                      ? null
                      : Image.network(
                          result.cover!,
                          width: 48,
                          height: 64,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.image_not_supported_outlined),
                        ),
                );
              },
            ),
          ),
        ),
        if (_selected != null)
          FilledButton(
            onPressed: _busy
                ? null
                : () {
                    final result = _results.firstWhere(
                      (row) => row.id == _selected,
                    );
                    showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('确认绑定'),
                        content: Text('将「${result.title}」绑定到此番剧？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () {
                              Navigator.pop(dialogContext);
                              _bind(result);
                            },
                            child: const Text('确认绑定'),
                          ),
                        ],
                      ),
                    );
                  },
            child: const Text('绑定所选条目'),
          ),
      ],
    ),
  );
}
