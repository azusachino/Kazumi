import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/info/tracking_sheet.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Fork only: the tracking entry point on a subject's card and info page.
///
/// A library category is not a remote tracker status, so the button reports
/// whether a tracker is bound, not what the local collection says.
class TrackingEntryButton extends StatefulWidget {
  const TrackingEntryButton({
    super.key,
    required this.bangumiItem,
    this.color = Colors.white,
    this.extended = true,
    this.onOpen,
    this.onClose,
  });

  final BangumiItem bangumiItem;
  final Color color;
  final bool extended;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  @override
  State<TrackingEntryButton> createState() => _TrackingEntryButtonState();
}

class _TrackingEntryButtonState extends State<TrackingEntryButton> {
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
        color: widget.extended ? null : widget.color,
      );
      return widget.extended
          ? OutlinedButton.icon(
              onPressed: _open,
              icon: icon,
              label: Text(label),
            )
          : IconButton(onPressed: _open, tooltip: label, icon: icon);
    },
  );
}
