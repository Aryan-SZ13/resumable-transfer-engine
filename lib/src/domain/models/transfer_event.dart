import 'package:meta/meta.dart';
import 'enums.dart';

/// Represents an immutable audit log entry documenting a state change or lifecycle milestone.
@immutable
class TransferEvent {
  final int? eventId;
  final String transferId;
  final TransferEventType eventType;
  final TransferState fromState;
  final TransferState toState;
  final String? message;
  final DateTime timestamp;

  const TransferEvent({
    this.eventId,
    required this.transferId,
    required this.eventType,
    required this.fromState,
    required this.toState,
    this.message,
    required this.timestamp,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransferEvent &&
          runtimeType == other.runtimeType &&
          eventId == other.eventId &&
          transferId == other.transferId &&
          eventType == other.eventType &&
          fromState == other.fromState &&
          toState == other.toState &&
          message == other.message &&
          timestamp == other.timestamp;

  @override
  int get hashCode => Object.hash(
        eventId,
        transferId,
        eventType,
        fromState,
        toState,
        message,
        timestamp,
      );

  @override
  String toString() =>
      'TransferEvent(id: $eventId, transferId: $transferId, ${fromState.name} -> ${toState.name}, type: ${eventType.name}, at: $timestamp)';
}
