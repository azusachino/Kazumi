// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class TrackingBindingAdapter extends TypeAdapter<TrackingBinding> {
  @override
  final typeId = 9;

  @override
  TrackingBinding read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return TrackingBinding(
      subjectId: (fields[0] as num).toInt(),
      trackerId: fields[1] as TrackerId,
      remoteId: fields[2] as String,
      episodeOffset: fields[3] == null ? 0 : (fields[3] as num).toInt(),
      statusLocked: fields[4] == null ? false : fields[4] as bool,
      score: (fields[5] as num?)?.toInt(),
      lastRemoteProgress: (fields[6] as num?)?.toInt(),
      lastSyncAt: fields[7] as DateTime?,
      title: fields[8] as String?,
      cover: fields[9] as String?,
      total: (fields[10] as num?)?.toInt(),
      updatedAt: fields[12] as DateTime?,
      generation: fields[11] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, TrackingBinding obj) {
    writer
      ..writeByte(13)
      ..writeByte(0)
      ..write(obj.subjectId)
      ..writeByte(1)
      ..write(obj.trackerId)
      ..writeByte(2)
      ..write(obj.remoteId)
      ..writeByte(3)
      ..write(obj.episodeOffset)
      ..writeByte(4)
      ..write(obj.statusLocked)
      ..writeByte(5)
      ..write(obj.score)
      ..writeByte(6)
      ..write(obj.lastRemoteProgress)
      ..writeByte(7)
      ..write(obj.lastSyncAt)
      ..writeByte(8)
      ..write(obj.title)
      ..writeByte(9)
      ..write(obj.cover)
      ..writeByte(10)
      ..write(obj.total)
      ..writeByte(11)
      ..write(obj.generation)
      ..writeByte(12)
      ..write(obj.updatedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrackingBindingAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class OutboxEntryAdapter extends TypeAdapter<OutboxEntry> {
  @override
  final typeId = 10;

  @override
  OutboxEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return OutboxEntry(
      subjectId: (fields[0] as num).toInt(),
      trackerId: fields[1] as TrackerId,
      remoteId: fields[2] as String,
      bindingGeneration: fields[10] as String,
      progress: (fields[3] as num?)?.toInt(),
      status: fields[4] as TrackStatus?,
      score: (fields[5] as num?)?.toInt(),
      attempts: fields[6] == null ? 0 : (fields[6] as num).toInt(),
      retryAt: fields[7] as DateTime?,
      error: fields[8] as String?,
      revision: fields[9] == null ? 0 : (fields[9] as num).toInt(),
    );
  }

  @override
  void write(BinaryWriter writer, OutboxEntry obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.subjectId)
      ..writeByte(1)
      ..write(obj.trackerId)
      ..writeByte(2)
      ..write(obj.remoteId)
      ..writeByte(3)
      ..write(obj.progress)
      ..writeByte(4)
      ..write(obj.status)
      ..writeByte(5)
      ..write(obj.score)
      ..writeByte(6)
      ..write(obj.attempts)
      ..writeByte(7)
      ..write(obj.retryAt)
      ..writeByte(8)
      ..write(obj.error)
      ..writeByte(9)
      ..write(obj.revision)
      ..writeByte(10)
      ..write(obj.bindingGeneration);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OutboxEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
