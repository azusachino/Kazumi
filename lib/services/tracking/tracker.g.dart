// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tracker.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class TrackerIdAdapter extends TypeAdapter<TrackerId> {
  @override
  final typeId = 11;

  @override
  TrackerId read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return TrackerId.bangumi;
      case 1:
        return TrackerId.anilist;
      default:
        return TrackerId.bangumi;
    }
  }

  @override
  void write(BinaryWriter writer, TrackerId obj) {
    switch (obj) {
      case TrackerId.bangumi:
        writer.writeByte(0);
      case TrackerId.anilist:
        writer.writeByte(1);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrackerIdAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class TrackStatusAdapter extends TypeAdapter<TrackStatus> {
  @override
  final typeId = 12;

  @override
  TrackStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return TrackStatus.planning;
      case 1:
        return TrackStatus.current;
      case 2:
        return TrackStatus.completed;
      case 3:
        return TrackStatus.paused;
      case 4:
        return TrackStatus.dropped;
      default:
        return TrackStatus.planning;
    }
  }

  @override
  void write(BinaryWriter writer, TrackStatus obj) {
    switch (obj) {
      case TrackStatus.planning:
        writer.writeByte(0);
      case TrackStatus.current:
        writer.writeByte(1);
      case TrackStatus.completed:
        writer.writeByte(2);
      case TrackStatus.paused:
        writer.writeByte(3);
      case TrackStatus.dropped:
        writer.writeByte(4);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrackStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
