import 'package:hive_ce/hive.dart';
import 'models.dart';

abstract interface class BindingStore {
  Future<List<TrackingBinding>> all();
  Future<TrackingBinding?> get(String key);
  Future<void> put(TrackingBinding binding);
  Future<void> delete(String key);
}

abstract interface class OutboxStore {
  Future<List<OutboxEntry>> all();
  Future<OutboxEntry?> get(String key);
  Future<void> put(OutboxEntry entry);
  Future<void> delete(String key);
}

class HiveBindingStore implements BindingStore {
  HiveBindingStore(this.box);
  final Box<TrackingBinding> box;
  @override
  Future<List<TrackingBinding>> all() async => box.values.toList();
  @override
  Future<TrackingBinding?> get(String key) async => box.get(key);
  @override
  Future<void> put(TrackingBinding binding) => box.put(binding.key, binding);
  @override
  Future<void> delete(String key) => box.delete(key);
}

class HiveOutboxStore implements OutboxStore {
  HiveOutboxStore(this.box);
  final Box<OutboxEntry> box;
  @override
  Future<List<OutboxEntry>> all() async => box.values.toList();
  @override
  Future<OutboxEntry?> get(String key) async => box.get(key);
  @override
  Future<void> put(OutboxEntry entry) => box.put(entry.key, entry);
  @override
  Future<void> delete(String key) => box.delete(key);
}

/// Call after the application's Hive adapters have been registered.
Future<(HiveBindingStore, HiveOutboxStore)> openTrackingStores() async {
  final bindings = await Hive.openBox<TrackingBinding>('trackingBindings');
  final outbox = await Hive.openBox<OutboxEntry>('trackingOutbox');
  return (HiveBindingStore(bindings), HiveOutboxStore(outbox));
}
