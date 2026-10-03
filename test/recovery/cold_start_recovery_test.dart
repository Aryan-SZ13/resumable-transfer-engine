import 'package:resumable_transfer_engine/resumable_transfer_engine.dart';
import 'package:test/test.dart';

void main() {
  group('ColdStartRecoveryService', () {
    late SqliteTransferDatabase database;
    late SqliteTransferEngineRepository repository;
    late ColdStartRecoveryService recoveryService;

    setUp(() {
      database = SqliteTransferDatabase.inMemory();
      repository = SqliteTransferEngineRepository(database);
      recoveryService = ColdStartRecoveryService(
        transferRepository: repository,
        chunkRepository: repository,
        eventRepository: repository,
      );
    });

    tearDown(() {
      database.dispose();
    });

    test(
        'Scenario A: 40% completed -> process dies -> recovery preserves exact 40% progress',
        () async {
      const tId = 't-recovery-a';
      const fileSize = 10 * 1024 * 1024; // 10 MB
      const chunkSize = 2 * 1024 * 1024; // 2 MB (5 chunks total, each 20%)

      // 1. Setup transfer and chunks
      await repository.insertTransfer(
        Transfer(
          id: tId,
          fileName: 'dataset.bin',
          filePath: '/data/dataset.bin',
          fileSize: fileSize,
          direction: TransferDirection.upload,
          state: TransferState.transferring,
          chunkSize: chunkSize,
          totalChunks: 5,
          completedChunks: 2, // 2 chunks completed = 40%
          bytesTransferred: 4 * 1024 * 1024,
          fileSha256: 'dataset_hash',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      final chunks = ChunkCalculator.generateChunks(
        transferId: tId,
        fileSize: fileSize,
        chunkSize: chunkSize,
      );
      await repository.insertChunks(chunks);

      // Chunks 0 and 1 are COMPLETED
      await repository.updateChunk(
        chunks[0].copyWith(state: ChunkState.completed, sha256: 'h0'),
      );
      await repository.updateChunk(
        chunks[1].copyWith(state: ChunkState.completed, sha256: 'h1'),
      );

      // Chunk 2 was in-flight (UPLOADING) when process abruptly died
      await repository.updateChunk(
        chunks[2].copyWith(state: ChunkState.uploading),
      );

      // 2. Perform Cold-Start Recovery
      final report = await recoveryService.performRecovery();

      expect(report.inFlightChunksResetCount, 1);
      expect(report.autoResumedTransferIds, contains(tId));

      // 3. Inspect reconciled transfer
      final recoveredTransfer = await repository.getTransfer(tId);
      expect(recoveredTransfer, isNotNull);
      expect(recoveredTransfer!.state, TransferState.queued);
      expect(recoveredTransfer.completedChunks, 2);
      expect(recoveredTransfer.bytesTransferred, 4 * 1024 * 1024);
      expect(recoveredTransfer.progressPercentage, 40.0);

      // 4. Inspect chunks
      final recoveredChunks = await repository.getChunksForTransfer(tId);
      expect(recoveredChunks[0].state, ChunkState.completed);
      expect(recoveredChunks[1].state, ChunkState.completed);
      expect(recoveredChunks[2].state, ChunkState.pending); // Reset to PENDING!
      expect(recoveredChunks[3].state, ChunkState.pending);
      expect(recoveredChunks[4].state, ChunkState.pending);
    });

    test(
        'Scenario B: Chunk 7 = UPLOADING -> process dies -> recovery resets Chunk 7 to PENDING',
        () async {
      const tId = 't-recovery-b';
      const fileSize = 20 * 1024 * 1024; // 20 MB
      const chunkSize = 2 * 1024 * 1024; // 2 MB -> 10 chunks

      await repository.insertTransfer(
        Transfer(
          id: tId,
          fileName: 'large.iso',
          filePath: '/large.iso',
          fileSize: fileSize,
          direction: TransferDirection.upload,
          state: TransferState.transferring,
          chunkSize: chunkSize,
          totalChunks: 10,
          fileSha256: 'iso_hash',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      final chunks = ChunkCalculator.generateChunks(
        transferId: tId,
        fileSize: fileSize,
        chunkSize: chunkSize,
      );
      await repository.insertChunks(chunks);

      // Set chunks 0..6 as COMPLETED
      for (var i = 0; i < 7; i++) {
        await repository.updateChunk(
          chunks[i].copyWith(state: ChunkState.completed, sha256: 'hash_$i'),
        );
      }

      // Chunk 7 was in-flight (UPLOADING)
      await repository.updateChunk(
        chunks[7].copyWith(state: ChunkState.uploading),
      );

      // Execute recovery
      final report = await recoveryService.performRecovery();
      expect(report.inFlightChunksResetCount, 1);

      // Chunk 7 is now safely PENDING
      final chunk7 = await repository.getChunk(tId, 7);
      expect(chunk7!.state, ChunkState.pending);

      // Progress is preserved from chunks 0..6 (14 MB)
      final transfer = await repository.getTransfer(tId);
      expect(transfer!.completedChunks, 7);
      expect(transfer.bytesTransferred, 7 * chunkSize);
      expect(transfer.state, TransferState.queued);
    });

    test(
        'Scenario C: USER_PAUSED transfer remains PAUSED on restart and requires explicit user action',
        () async {
      const tId = 't-recovery-c';

      await repository.insertTransfer(
        Transfer(
          id: tId,
          fileName: 'manual_pause.zip',
          filePath: '/manual_pause.zip',
          fileSize: 5000,
          direction: TransferDirection.upload,
          state: TransferState.paused,
          pauseReason: PauseReason.userPaused,
          chunkSize: 1000,
          totalChunks: 5,
          completedChunks: 2,
          bytesTransferred: 2000,
          fileSha256: 'h',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      final report = await recoveryService.performRecovery();

      expect(report.preservedPausedTransferIds, contains(tId));
      expect(report.autoResumedTransferIds, isNot(contains(tId)));

      final transfer = await repository.getTransfer(tId);
      expect(transfer!.state, TransferState.paused);
      expect(transfer.pauseReason, PauseReason.userPaused);
    });

    test(
        'Scenario D: Unexpectedly INTERRUPTED transfer becomes QUEUED and eligible for automatic execution',
        () async {
      const tId = 't-recovery-d';

      await repository.insertTransfer(
        Transfer(
          id: tId,
          fileName: 'interrupted.bin',
          filePath: '/interrupted.bin',
          fileSize: 4000,
          direction: TransferDirection.upload,
          state: TransferState.transferring, // Left dirty at crash
          chunkSize: 1000,
          totalChunks: 4,
          completedChunks: 1,
          bytesTransferred: 1000,
          fileSha256: 'h',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      final report = await recoveryService.performRecovery();

      expect(report.autoResumedTransferIds, contains(tId));

      final transfer = await repository.getTransfer(tId);
      expect(transfer!.state, TransferState.queued);
      expect(transfer.pauseReason, isNull);

      // Verify audit event was recorded
      final events = await repository.getEventsForTransfer(tId);
      expect(events.any((e) => e.eventType == TransferEventType.reconciled),
          isTrue);
    });

    test(
        'Scenario E: CANCELLED transfer remains permanently CANCELLED and never resurrects',
        () async {
      const tId = 't-recovery-e';

      await repository.insertTransfer(
        Transfer(
          id: tId,
          fileName: 'cancelled.tar',
          filePath: '/cancelled.tar',
          fileSize: 4000,
          direction: TransferDirection.upload,
          state: TransferState.cancelled,
          chunkSize: 1000,
          totalChunks: 4,
          fileSha256: 'h',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      final report = await recoveryService.performRecovery();

      expect(report.terminalTransferIds, contains(tId));
      expect(report.autoResumedTransferIds, isNot(contains(tId)));

      final transfer = await repository.getTransfer(tId);
      expect(transfer!.state, TransferState.cancelled);
    });

    test('Scenario F: COMPLETED transfer is immutable and remains COMPLETED',
        () async {
      const tId = 't-recovery-f';

      await repository.insertTransfer(
        Transfer(
          id: tId,
          fileName: 'completed.zip',
          filePath: '/completed.zip',
          fileSize: 4000,
          direction: TransferDirection.upload,
          state: TransferState.completed,
          chunkSize: 1000,
          totalChunks: 4,
          completedChunks: 4,
          bytesTransferred: 4000,
          fileSha256: 'h',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      final report = await recoveryService.performRecovery();

      expect(report.terminalTransferIds, contains(tId));
      expect(report.autoResumedTransferIds, isNot(contains(tId)));

      final transfer = await repository.getTransfer(tId);
      expect(transfer!.state, TransferState.completed);
    });

    test(
        'R-1 & R-2: Recovery runs inside TransactionRunner and reconciles QUEUED/PAUSED transfers with stale chunks',
        () async {
      final transactionalRecoveryService = ColdStartRecoveryService(
        transferRepository: repository,
        chunkRepository: repository,
        eventRepository: repository,
        transactionRunner: repository, // R-1 TransactionRunner injected
      );

      // Transfer 1: QUEUED but has an UPLOADING chunk (e.g. abnormal shutdown during queueing)
      const t1Id = 't-queued-stale';
      await repository.insertTransfer(
        Transfer(
          id: t1Id,
          fileName: 'queued_stale.bin',
          filePath: '/queued_stale.bin',
          fileSize: 2000,
          direction: TransferDirection.upload,
          state: TransferState.queued,
          chunkSize: 1000,
          totalChunks: 2,
          completedChunks: 0,
          bytesTransferred: 0,
          fileSha256: 'h',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      final now = DateTime.now().toUtc();
      await repository.insertChunks([
        Chunk(
          transferId: t1Id,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: 1000,
          state: ChunkState.uploading, // STALE!
          retryCount: 0,
          updatedAt: now,
        ),
        Chunk(
          transferId: t1Id,
          chunkIndex: 1,
          byteOffset: 1000,
          byteLength: 1000,
          state: ChunkState.pending,
          retryCount: 0,
          updatedAt: now,
        ),
      ]);

      // Transfer 2: USER_PAUSED but has an UPLOADING chunk
      const t2Id = 't-paused-stale';
      await repository.insertTransfer(
        Transfer(
          id: t2Id,
          fileName: 'paused_stale.bin',
          filePath: '/paused_stale.bin',
          fileSize: 2000,
          direction: TransferDirection.upload,
          state: TransferState.paused,
          pauseReason: PauseReason.userPaused,
          chunkSize: 1000,
          totalChunks: 2,
          completedChunks: 0,
          bytesTransferred: 0,
          fileSha256: 'h',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      await repository.insertChunks([
        Chunk(
          transferId: t2Id,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: 1000,
          state: ChunkState.uploading, // STALE!
          retryCount: 0,
          updatedAt: now,
        ),
        Chunk(
          transferId: t2Id,
          chunkIndex: 1,
          byteOffset: 1000,
          byteLength: 1000,
          state: ChunkState.pending,
          retryCount: 0,
          updatedAt: now,
        ),
      ]);

      final report = await transactionalRecoveryService.performRecovery();

      // Stale chunk in t1 reset, stale chunk in t2 reset
      expect(report.inFlightChunksResetCount, 2);
      expect(report.preservedPausedTransferIds, contains(t2Id));

      // Chunks in both transfers are now PENDING
      final t1Chunk0 = await repository.getChunk(t1Id, 0);
      expect(t1Chunk0!.state, ChunkState.pending);

      final t2Chunk0 = await repository.getChunk(t2Id, 0);
      expect(t2Chunk0!.state, ChunkState.pending);

      // t2 remains PAUSED
      final t2 = await repository.getTransfer(t2Id);
      expect(t2!.state, TransferState.paused);
      expect(t2.pauseReason, PauseReason.userPaused);
    });

    test(
        'Double recovery idempotency: running recovery twice yields stable state',
        () async {
      const tId = 't-idempotent';
      final now = DateTime.now().toUtc();
      await repository.insertTransfer(
        Transfer(
          id: tId,
          fileName: 'idem.bin',
          filePath: '/idem.bin',
          fileSize: 2000,
          direction: TransferDirection.upload,
          state: TransferState.transferring,
          chunkSize: 1000,
          totalChunks: 2,
          completedChunks: 1,
          bytesTransferred: 1000,
          fileSha256: 'h',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.insertChunks([
        Chunk(
          transferId: tId,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: 1000,
          state: ChunkState.completed,
          retryCount: 0,
          sha256: 'h0',
          updatedAt: now,
        ),
        Chunk(
          transferId: tId,
          chunkIndex: 1,
          byteOffset: 1000,
          byteLength: 1000,
          state: ChunkState.uploading,
          retryCount: 0,
          updatedAt: now,
        ),
      ]);

      // Pass 1
      final report1 = await recoveryService.performRecovery();
      expect(report1.inFlightChunksResetCount, 1);
      expect(report1.autoResumedTransferIds, contains(tId));

      final transfer1 = await repository.getTransfer(tId);
      expect(transfer1!.state, TransferState.queued);
      expect(transfer1.completedChunks, 1);

      // Pass 2 immediately after
      final report2 = await recoveryService.performRecovery();
      expect(report2.inFlightChunksResetCount, 0);
      expect(report2.autoResumedTransferIds, isEmpty);

      final transfer2 = await repository.getTransfer(tId);
      expect(transfer2!.state, TransferState.queued);
      expect(transfer2.completedChunks, 1);
    });
  });
}
