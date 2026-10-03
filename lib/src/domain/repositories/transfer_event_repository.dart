import '../models/transfer_event.dart';

/// Repository interface for persisting and reading immutable [TransferEvent] audit entries.
abstract interface class TransferEventRepository {
  /// Appends an event to the audit trail.
  Future<void> recordEvent(TransferEvent event);

  /// Retrieves chronological audit history for a transfer.
  Future<List<TransferEvent>> getEventsForTransfer(String transferId);
}
