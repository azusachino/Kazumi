import 'package:hive_ce/hive.dart';

part 'collect_change_module.g.dart';

// The box stores the changes history of collected bangumi
// The changes will be used to sync with webDav
@HiveType(typeId: 5)
class CollectedBangumiChange {
  // timestamp in seconds
  // hivebox has limited the length of key, the max number is 4294967295
  // we have to use timestamp in seconds as key to avoid key conflict and hive key limit
  @HiveField(0)
  int id;

  @HiveField(1)
  int bangumiID;

  // 1. add
  // 2. update
  // 3. delete
  @HiveField(2)
  int action;

  // 1. 在看
  // 2. 想看
  // 3. 搁置
  // 4. 看过
  // 5. 抛弃
  @HiveField(3)
  int type;

  @HiveField(4)
  int timestamp;

  // Who recorded this change: the owner or a tracker status this device read.
  // 0 means user, 1 means tracker. default 0 is mandatory: rows written by a
  // build without this field are already in synced boxes, and the generated
  // adapter reads `(fields[5] as num).toInt()`.
  @HiveField(5, defaultValue: 0)
  int origin;

  CollectedBangumiChange(this.id, this.bangumiID, this.action, this.type,
      this.timestamp, {this.origin = CollectChangeOrigin.user});

  @override
  String toString() {
    return 'id: $id, bangumi: $bangumiID, action: $action, time: $timestamp, origin: $origin';
  }
}

/// The two origins a collect change can have.
abstract final class CollectChangeOrigin {
  /// The owner changed the category in this app.
  static const int user = 0;

  /// This device followed a status the tracker already held.
  static const int tracker = 1;
}
