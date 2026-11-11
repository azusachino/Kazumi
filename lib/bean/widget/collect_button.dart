import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/info/tracking_sheet.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Tracking entry point; a library category is not a remote tracker status.
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
  Future<void> _open() async {
    widget.onOpen?.call();
    try {
      await showTrackingSheet(context, widget.bangumiItem);
    } finally {
      widget.onClose?.call();
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: GStorage.trackingBindings.listenable(),
    builder: (context, bindings, _) {
      final tracked = bindings.values.any(
        (binding) => binding.subjectId == widget.bangumiItem.id,
      );
      final label = tracked ? '已追踪' : '追踪';
      final icon = Icon(
        tracked ? Icons.sync_rounded : Icons.sync_outlined,
        color: widget._isExtended ? null : widget.color,
      );
      return widget._isExtended
          ? OutlinedButton.icon(
              onPressed: _open,
              icon: icon,
              label: Text(label),
            )
          : IconButton(onPressed: _open, tooltip: label, icon: icon);
    },
  );
}
