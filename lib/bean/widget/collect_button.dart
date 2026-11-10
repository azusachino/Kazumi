import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/info/tracking_sheet.dart';
import 'package:kazumi/services/storage/storage.dart';

class CollectButton extends StatefulWidget {
  const CollectButton({
    super.key,
    required this.bangumiItem,
    this.color = Colors.white,
    this.onOpen,
    this.onClose,
  }) : _isExtended = false;

  const CollectButton.extend({
    super.key,
    required this.bangumiItem,
    this.color = Colors.white,
    this.onOpen,
    this.onClose,
  }) : _isExtended = true;

  final BangumiItem bangumiItem;
  final Color color;
  final bool _isExtended;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  @override
  State<CollectButton> createState() => _CollectButtonState();
}

class _CollectButtonState extends State<CollectButton> {
  final _collectController = inject<CollectController>();

  String _labelFor(CollectType type) =>
      type == CollectType.none ? '未追' : type.label;

  IconData _iconFor(CollectType type) => switch (type) {
    CollectType.none => Icons.favorite_border,
    CollectType.watching => Icons.favorite,
    CollectType.planToWatch => Icons.star_rounded,
    CollectType.onHold => Icons.pending_actions,
    CollectType.watched => Icons.done,
    CollectType.abandoned => Icons.heart_broken,
  };

  Future<void> _open() async {
    widget.onOpen?.call();
    try {
      await showTrackingSheet(context, widget.bangumiItem);
    } finally {
      widget.onClose?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: GStorage.collectibles.listenable(),
      builder: (context, _, _) => ValueListenableBuilder(
        valueListenable: GStorage.trackingBindings.listenable(),
        builder: (context, bindings, _) {
          final type = CollectType.fromValue(
            _collectController.getCollectType(widget.bangumiItem),
          );
          final count = bindings.values
              .where((binding) => binding.subjectId == widget.bangumiItem.id)
              .length;
          final label = _labelFor(type);
          final icon = Icon(_iconFor(type), color: widget._isExtended ? null : widget.color);
          return widget._isExtended
              ? FilledButton.icon(
                  onPressed: _open,
                  icon: icon,
                  label: Text(count > 0 ? '$label · $count' : label),
                )
              : IconButton(
                  onPressed: _open,
                  tooltip: count > 0 ? '$label · $count' : label,
                  icon: count > 0
                      ? Badge(label: Text('$count'), child: icon)
                      : icon,
                );
        },
      ),
    );
  }
}
