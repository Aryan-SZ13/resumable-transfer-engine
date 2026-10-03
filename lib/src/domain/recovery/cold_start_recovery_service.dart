import '../models/enums.dart';
import '../models/transfer_event.dart';
import '../repositories/chunk_repository.dart';
import '../repositories/transaction_runner.dart';
import '../repositories/transfer_event_repository.dart';
import '../repositories/transfer_repository.dart';

/// Summary report returned upon completion of cold-start recovery.
class RecoveryReport {
  final int totalTransfersScanned;
  final int inFlightChunksResetCount;
  final List<String> autoResumedTransferIds;
  final List<String> preservedPausedTransferIds;
  final List<String> terminalTransferIds;

  const RecoveryReport({
    required this.totalTransfersScanned,
    required this.inFlightChunksResetCount,
    required this.autoResumedTransferIds,
    required this.preservedPausedTransferIds,
    required this.terminalTransferIds,
  });
}

/// Implements deterministic, atomic application-startup recovery for interrupted transfers.
/// Enforces: USER_PAUSED != INTERRUPTED != CANCELLED across a strict transaction boundary (R-1, R-2).
class ColdStartRecoveryService {
  final TransferRepository transferRepository;
  final ChunkRepository chunkRepository;
  final TransferEventRepository eventRepository;
  final TransactionRunner? transactionRunner;

  const ColdStartRecoveryService({
    required this.transferRepository,
    required this.chunkRepository,
    required this.eventRepository,
    this.transactionRunner,
  });

  /// Executes startup reconciliation across all stored transfers.
  /// Runs inside a database transaction if a [transactionRunner] is provided (R-1).
  Future<RecoveryReport> performRecovery({DateTime? now}) {
    if (transactionRunner != null) {
      return transactionRunner!.runTransaction(
        () => _performRecoveryInternal(now: now),
      );
    }
    return _performRecoveryInternal(now: now);
  }

  Future<RecoveryReport> _performRecoveryInternal({DateTime? now}) async {
    final timestamp = now ?? DateTime.now().toUtc();
    final allTransfers = await transferRepository.getAllTransfers();

    int totalResetChunks = 0;
    final autoResumedIds = <String>[];
    final preservedPausedIds = <String>[];
    final terminalIds = <String>[];

    for (final transfer in allTransfers) {
      // 1. Terminal transfers are immutable forever
      if (transfer.state.isTerminal) {
        terminalIds.add(transfer.id);
        continue;
      }

      // 2. Transfers deliberately paused by the user remain PAUSED
      if (transfer.state == TransferState.paused &&
          transfer.pauseReason == PauseReason.userPaused) {
        // Reset any stale in-flight chunks that were left dirty
        final resetCount = await chunkRepository.resetChunkStates(
          transferId: transfer.id,
          fromState: ChunkState.uploading,
          toState: ChunkState.pending,
        );
        totalResetChunks += resetCount;

        preservedPausedIds.add(transfer.id);
        continue;
      }

      // 3. Stale in-flight chunks in QUEUED transfers (R-2)
      if (transfer.state == TransferState.queued) {
        final resetCount = await chunkRepository.resetChunkStates(
          transferId: transfer.id,
          fromState: ChunkState.uploading,
          toState: ChunkState.pending,
        );
        totalResetChunks += resetCount;

        // Recalculate progress strictly from COMPLETED chunks
        final completedChunks = await chunkRepository.getChunksByState(
          transfer.id,
          ChunkState.completed,
        );
        final verifiedBytes = completedChunks.fold<int>(
          0,
          (sum, c) => sum + c.byteLength,
        );

        if (transfer.completedChunks != completedChunks.length ||
            transfer.bytesTransferred != verifiedBytes) {
          final reconciled = transfer.copyWith(
            completedChunks: completedChunks.length,
            bytesTransferred: verifiedBytes,
            updatedAt: timestamp,
          );
          await transferRepository.updateTransfer(reconciled);
        }
        continue;
      }

      // 4. For transfers active during unexpected process death:
      // (TRANSFERRING, RETRYING, VERIFYING, or PAUSED without userPaused reason)
      if (transfer.state == TransferState.transferring ||
          transfer.state == TransferState.retrying ||
          transfer.state == TransferState.verifying ||
          transfer.state == TransferState.paused) {
        // Step A: Reset any chunks stuck in UPLOADING -> PENDING
        final resetCount = await chunkRepository.resetChunkStates(
          transferId: transfer.id,
          fromState: ChunkState.uploading,
          toState: ChunkState.pending,
        );
        totalResetChunks += resetCount;

        // Step B: Recalculate progress strictly from COMPLETED chunks
        final completedChunks = await chunkRepository.getChunksByState(
          transfer.id,
          ChunkState.completed,
        );
        final verifiedBytes = completedChunks.fold<int>(
          0,
          (sum, c) => sum + c.byteLength,
        );

        // Step C: Unexpected interruption recovers directly into QUEUED
        final reconciledTransfer = transfer.copyWith(
          state: TransferState.queued,
          completedChunks: completedChunks.length,
          bytesTransferred: verifiedBytes,
          clearPauseReason: true,
          clearErrorMessage: true,
          updatedAt: timestamp,
        );

        await transferRepository.updateTransfer(reconciledTransfer);

        // Step D: Log audit event documenting unexpected crash recovery
        await eventRepository.recordEvent(
          TransferEvent(
            transferId: transfer.id,
            eventType: TransferEventType.reconciled,
            fromState: transfer.state,
            toState: TransferState.queued,
            message:
                'Interrupted by process termination. Restored at ${(reconciledTransfer.progressPercentage).toStringAsFixed(1)}% ($verifiedBytes bytes). Enqueued for automatic continuation.',
            timestamp: timestamp,
          ),
        );

        autoResumedIds.add(transfer.id);
      }
    }

    return RecoveryReport(
      totalTransfersScanned: allTransfers.length,
      inFlightChunksResetCount: totalResetChunks,
      autoResumedTransferIds: autoResumedIds,
      preservedPausedTransferIds: preservedPausedIds,
      terminalTransferIds: terminalIds,
    );
  }
}
