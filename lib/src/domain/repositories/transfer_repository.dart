import '../models/enums.dart';
import '../models/transfer.dart';

/// Repository interface for persisting and querying [Transfer] master records.
abstract interface class TransferRepository {
  /// Inserts a new transfer record. Fails if ID already exists.
  Future<void> insertTransfer(Transfer transfer);

  /// Updates an existing transfer record.
  Future<void> updateTransfer(Transfer transfer);

  /// Fetches a transfer by unique ID. Returns null if not found.
  Future<Transfer?> getTransfer(String id);

  /// Retrieves all recorded transfers, sorted newest to oldest.
  Future<List<Transfer>> getAllTransfers();

  /// Retrieves transfers matching a specific state.
  Future<List<Transfer>> getTransfersByState(TransferState state);

  /// Retrieves transfers that were in active states when an unexpected termination occurred.
  Future<List<Transfer>> getActiveOrInterruptedTransfers();

  /// Permanently deletes a transfer and cascades deletion to child chunks and events.
  Future<void> deleteTransfer(String id);
}
