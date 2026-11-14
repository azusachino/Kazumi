import 'package:flutter/material.dart';
import 'package:kazumi/bean/widget/tracking_entry_button.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';

class CollectButton extends StatelessWidget {
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
  Widget build(BuildContext context) => TrackingEntryButton(
    bangumiItem: bangumiItem,
    color: color,
    extended: _isExtended,
    onOpen: onOpen,
    onClose: onClose,
  );
}
