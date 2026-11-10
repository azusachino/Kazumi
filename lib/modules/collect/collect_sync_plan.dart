class CollectSyncPlan {
  const CollectSyncPlan({
    required this.webDavEnabled,
    required this.webDavCollectiblesEnabled,
  });

  final bool webDavEnabled;
  final bool webDavCollectiblesEnabled;

  bool get shouldSyncWebDavCollectibles =>
      webDavEnabled && webDavCollectiblesEnabled;

  bool get canSync => shouldSyncWebDavCollectibles;
}
