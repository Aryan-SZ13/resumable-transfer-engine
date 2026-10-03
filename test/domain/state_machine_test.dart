import 'package:resumable_transfer_engine/resumable_transfer_engine.dart';
import 'package:test/test.dart';

void main() {
  group('TransferStateMachine', () {
    late Transfer baseTransfer;

    setUp(() {
      baseTransfer = Transfer(
        id: 't-123',
        fileName: 'sample.zip',
        filePath: '/tmp/sample.zip',
        fileSize: 10485760, // 10 MB
        direction: TransferDirection.upload,
        state: TransferState.queued,
        chunkSize: 2097152, // 2 MB
        totalChunks: 5,
        fileSha256: 'dummy_hash',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );
    });

    test('Valid flow: QUEUED -> TRANSFERRING -> VERIFYING -> COMPLETED', () {
      final t1 = TransferStateMachine.transition(
        baseTransfer,
        TransferEventTrigger.queueSchedule,
      );
      expect(t1.state, TransferState.transferring);

      // Simulate chunk workers completing all 5 chunks
      final tAllChunks = t1.copyWith(
        completedChunks: 5,
        bytesTransferred: 10485760,
      );

      final t2 = TransferStateMachine.transition(
        tAllChunks,
        TransferEventTrigger.allChunksCompleted,
      );
      expect(t2.state, TransferState.verifying);

      final t3 = TransferStateMachine.transition(
        t2,
        TransferEventTrigger.integrityVerified,
      );
      expect(t3.state, TransferState.completed);
    });

    test(
        'S-1 Invariant: allChunksCompleted rejected if completedChunks < totalChunks',
        () {
      final transferring = TransferStateMachine.transition(
        baseTransfer,
        TransferEventTrigger.queueSchedule,
      );

      // Only 2 of 5 chunks completed
      final incomplete = transferring.copyWith(
        completedChunks: 2,
        bytesTransferred: 2 * 2097152,
      );

      expect(
        () => TransferStateMachine.transition(
          incomplete,
          TransferEventTrigger.allChunksCompleted,
        ),
        throwsA(isA<InvariantViolationException>()),
      );

      // Zero totalChunks also rejected
      final zeroChunks = transferring.copyWith(totalChunks: 0);
      expect(
        () => TransferStateMachine.transition(
          zeroChunks,
          TransferEventTrigger.allChunksCompleted,
        ),
        throwsA(isA<InvariantViolationException>()),
      );
    });

    test('User Pause and Resume semantics', () {
      final transferring = TransferStateMachine.transition(
        baseTransfer,
        TransferEventTrigger.queueSchedule,
      );
      expect(transferring.state, TransferState.transferring);

      final paused = TransferStateMachine.transition(
        transferring,
        TransferEventTrigger.userPause,
      );
      expect(paused.state, TransferState.paused);
      expect(paused.pauseReason, PauseReason.userPaused);

      // Cannot jump directly from PAUSED to TRANSFERRING without QUEUED
      expect(
        () => TransferStateMachine.transition(
          paused,
          TransferEventTrigger.queueSchedule,
        ),
        throwsA(isA<IllegalStateTransitionException>()),
      );

      final resumed = TransferStateMachine.transition(
        paused,
        TransferEventTrigger.userResume,
      );
      expect(resumed.state, TransferState.queued);
      expect(resumed.pauseReason, isNull);
    });

    test('S-2 Guard: userResume rejected if pauseReason != USER_PAUSED', () {
      // Create a transfer paused without userPaused reason
      final nonUserPaused = baseTransfer.copyWith(
        state: TransferState.paused,
        clearPauseReason: true,
      );

      expect(
        () => TransferStateMachine.transition(
          nonUserPaused,
          TransferEventTrigger.userResume,
        ),
        throwsA(isA<IllegalStateTransitionException>()),
      );

      final interruptedPause = baseTransfer.copyWith(
        state: TransferState.paused,
        pauseReason: PauseReason.interrupted,
      );

      expect(
        () => TransferStateMachine.transition(
          interruptedPause,
          TransferEventTrigger.userResume,
        ),
        throwsA(isA<IllegalStateTransitionException>()),
      );
    });

    test('Retry logic and max retries exhaustion', () {
      final transferring = TransferStateMachine.transition(
        baseTransfer,
        TransferEventTrigger.queueSchedule,
      );

      // Retry 1
      final r1 = TransferStateMachine.transition(
        transferring,
        TransferEventTrigger.retryableError,
        errorMessage: 'Socket timeout',
      );
      expect(r1.state, TransferState.retrying);
      expect(r1.retryCount, 1);

      // Backoff elapsed -> returns to TRANSFERRING
      final tAfterBackoff = TransferStateMachine.transition(
        r1,
        TransferEventTrigger.backoffElapsed,
      );
      expect(tAfterBackoff.state, TransferState.transferring);

      // Simulate reaching max retries (maxRetries = 5)
      var current = tAfterBackoff.copyWith(retryCount: 4);
      final failed = TransferStateMachine.transition(
        current,
        TransferEventTrigger.retryableError,
      );
      expect(failed.state, TransferState.failed);
      expect(failed.retryCount, 5);
      expect(failed.errorMessage, contains('Max retry attempts'));
    });

    test('Cancellation from various states transitions cleanly to CANCELLED',
        () {
      // From QUEUED
      final c1 = TransferStateMachine.transition(
        baseTransfer,
        TransferEventTrigger.userCancel,
      );
      expect(c1.state, TransferState.cancelled);

      // From TRANSFERRING
      final t = TransferStateMachine.transition(
        baseTransfer,
        TransferEventTrigger.queueSchedule,
      );
      final c2 = TransferStateMachine.transition(
        t,
        TransferEventTrigger.userCancel,
      );
      expect(c2.state, TransferState.cancelled);

      // From PAUSED
      final p = TransferStateMachine.transition(
        t,
        TransferEventTrigger.userPause,
      );
      final c3 = TransferStateMachine.transition(
        p,
        TransferEventTrigger.userCancel,
      );
      expect(c3.state, TransferState.cancelled);
    });

    test(
        'Terminal state protection: COMPLETED and CANCELLED reject transitions',
        () {
      final cancelled = TransferStateMachine.transition(
        baseTransfer,
        TransferEventTrigger.userCancel,
      );
      expect(cancelled.isTerminal, isTrue);

      expect(
        () => TransferStateMachine.transition(
          cancelled,
          TransferEventTrigger.userResume,
        ),
        throwsA(isA<TerminalStateViolationException>()),
      );

      final completed = baseTransfer.copyWith(state: TransferState.completed);
      expect(
        () => TransferStateMachine.transition(
          completed,
          TransferEventTrigger.queueSchedule,
        ),
        throwsA(isA<TerminalStateViolationException>()),
      );
    });

    test('Unexpected crash reconciliation: TRANSFERRING -> QUEUED', () {
      final transferring = TransferStateMachine.transition(
        baseTransfer,
        TransferEventTrigger.queueSchedule,
      );

      final recovered = TransferStateMachine.transition(
        transferring,
        TransferEventTrigger.reconcileInterrupted,
      );
      expect(recovered.state, TransferState.queued);
      expect(recovered.pauseReason, isNull);
    });

    test('Reconcile interrupted from RETRYING and VERIFYING -> QUEUED', () {
      final retrying = baseTransfer.copyWith(state: TransferState.retrying);
      final r1 = TransferStateMachine.transition(
        retrying,
        TransferEventTrigger.reconcileInterrupted,
      );
      expect(r1.state, TransferState.queued);

      final verifying = baseTransfer.copyWith(state: TransferState.verifying);
      final r2 = TransferStateMachine.transition(
        verifying,
        TransferEventTrigger.reconcileInterrupted,
      );
      expect(r2.state, TransferState.queued);
    });

    test('Integrity failure moves VERIFYING to FAILED', () {
      final verifying = baseTransfer.copyWith(state: TransferState.verifying);
      final failed = TransferStateMachine.transition(
        verifying,
        TransferEventTrigger.integrityFailed,
        errorMessage: 'SHA-256 hash mismatch',
      );
      expect(failed.state, TransferState.failed);
      expect(failed.errorMessage, contains('SHA-256 hash mismatch'));
    });
  });

  group('ChunkStateMachine', () {
    late Chunk baseChunk;

    setUp(() {
      baseChunk = Chunk(
        transferId: 't-1',
        chunkIndex: 0,
        byteOffset: 0,
        byteLength: 2097152,
        state: ChunkState.pending,
        updatedAt: DateTime.now().toUtc(),
      );
    });

    test('Lifecycle: PENDING -> UPLOADING -> COMPLETED', () {
      final uploading = ChunkStateMachine.transition(
        baseChunk,
        ChunkEventTrigger.dispatchWorker,
      );
      expect(uploading.state, ChunkState.uploading);

      final completed = ChunkStateMachine.transition(
        uploading,
        ChunkEventTrigger.ackReceived,
        sha256: 'valid_sha256',
      );
      expect(completed.state, ChunkState.completed);
      expect(completed.sha256, 'valid_sha256');

      // COMPLETED is immutable
      expect(
        () => ChunkStateMachine.transition(
          completed,
          ChunkEventTrigger.dispatchWorker,
        ),
        throwsA(isA<IllegalStateTransitionException>()),
      );
    });

    test('Error handling: UPLOADING -> FAILED -> retry UPLOADING', () {
      final uploading = ChunkStateMachine.transition(
        baseChunk,
        ChunkEventTrigger.dispatchWorker,
      );

      final failed = ChunkStateMachine.transition(
        uploading,
        ChunkEventTrigger.networkError,
      );
      expect(failed.state, ChunkState.failed);
      expect(failed.retryCount, 1);

      // Retried
      final retryUploading = ChunkStateMachine.transition(
        failed,
        ChunkEventTrigger.dispatchWorker,
      );
      expect(retryUploading.state, ChunkState.uploading);
      expect(retryUploading.retryCount, 1);
    });

    test('Crash / Pause abort: UPLOADING -> PENDING', () {
      final uploading = ChunkStateMachine.transition(
        baseChunk,
        ChunkEventTrigger.dispatchWorker,
      );

      final aborted = ChunkStateMachine.transition(
        uploading,
        ChunkEventTrigger.abortToPending,
      );
      expect(aborted.state, ChunkState.pending);
    });
  });
}
