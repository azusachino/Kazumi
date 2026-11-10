import 'package:flutter/material.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/tracking/tracker.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> showAniListSearchSheet(
  BuildContext context,
  BangumiItem item, {
  bool rebind = false,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => AniListSearchPage(item: item, rebind: rebind),
  ),
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
    text: widget.item.name.isNotEmpty ? widget.item.name : widget.item.nameCn,
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: TextField(
        controller: _query,
        textInputAction: TextInputAction.search,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _search(),
        decoration: const InputDecoration(
          hintText: '搜索 AniList',
          border: InputBorder.none,
        ),
      ),
      actions: [
        if (_query.text.isNotEmpty)
          IconButton(
            tooltip: '清除',
            onPressed: () => setState(() => _query.clear()),
            icon: const Icon(Icons.close),
          ),
        IconButton(
          tooltip: '搜索',
          onPressed: _busy ? null : _search,
          icon: const Icon(Icons.search),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _results.length,
            itemBuilder: (context, index) {
              final result = _results[index];
              final details = [
                if (result.subtitle?.isNotEmpty ?? false) result.subtitle!,
                if (result.format?.isNotEmpty ?? false) result.format!,
                if (result.seasonYear != null) '${result.seasonYear}',
                if (result.episodes != null) '${result.episodes} 话',
              ].join(' · ');
              return Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: _selected == result.id
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() => _selected = result.id),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (result.cover != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.network(
                              result.cover!,
                              width: 64,
                              height: 96,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const SizedBox(
                                width: 64,
                                height: 96,
                                child: Icon(Icons.image_not_supported_outlined),
                              ),
                            ),
                          )
                        else
                          const SizedBox(
                            width: 64,
                            height: 96,
                            child: Icon(Icons.image_outlined),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                result.title,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                details,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: '更多操作',
                          onSelected: (_) => launchUrl(
                            Uri.https('anilist.co', '/anime/${result.id}'),
                            mode: LaunchMode.externalApplication,
                          ),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'open',
                              child: Text('在浏览器中打开'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: FilledButton(
          onPressed: _busy || _selected == null
              ? null
              : () => _bind(_results.firstWhere((row) => row.id == _selected)),
          child: const Text('追踪'),
        ),
      ),
    ),
  );
}
