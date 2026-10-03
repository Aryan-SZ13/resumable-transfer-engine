import 'package:resumable_transfer_engine/resumable_transfer_engine.dart';
import 'package:test/test.dart';

void main() {
  group('Transactional Consistency', () {
    late SqliteTransferDatabase database;
    late SqliteTransferEngineRepository repository;

    setUp(() {
      database = SqliteTransferDatabase.inMemory();
      repository = SqliteTransferEngineRepository(database);
    });

    tearDown(() {
      database.dispose();
    });

    test(
        'Atomic chunk completion updates chunk, transfer progress, and logs audit event',
        () async {
      const tId = 't-atomic-1';
      const fileSize = 4 * 1024 * 1024; // 4 MB
      const chunkSize = 2 * 1024 * 1024; // 2 MB -> 2 chunks

      await repository.insertTransfer(
        Transfer(
          id: tId,
          fileName: 'data.iso',
          filePath: '/data.iso',
          fileSize: fileSize,
          direction: TransferDirection.upload,
          state: TransferState.transferring,
          chunkSize: chunkSize,
          totalChunks: 2,
          completedChunks: 0,
          bytesTransferred: 0,
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

      // Complete Chunk 0 atomically
      final updatedTransfer1 = await repository.completeChunkAtomically(
        transferId: tId,
        chunkIndex: 0,
        sha256: 'sha256_chunk_0',
      );

      expect(updatedTransfer1.completedChunks, 1);
      expect(updatedTransfer1.bytesTransferred, 2 * 1024 * 1024);
      expect(updatedTransfer1.state,
          TransferState.transferring); // Not all done yet

      // Verify in DB
      final dbTransfer1 = await repository.getTransfer(tId);
      expect(dbTransfer1!.completedChunks, 1);
      expect(dbTransfer1.bytesTransferred, 2097152);

      final dbChunk0 = await repository.getChunk(tId, 0);
      expect(dbChunk0!.state, ChunkState.completed);
      expect(dbChunk0.sha256, 'sha256_chunk_0');

      // Verify event was logged in the same transaction
      final events1 = await repository.getEventsForTransfer(tId);
      expect(events1.length, 1);
      expect(events1.first.eventType, TransferEventType.chunkCompleted);

      // Complete Chunk 1 (final chunk!)
      final updatedTransfer2 = await repository.completeChunkAtomically(
        transferId: tId,
        chunkIndex: 1,
        sha256: 'sha256_chunk_1',
      );

      expect(updatedTransfer2.completedChunks, 2);
      expect(updatedTransfer2.bytesTransferred, fileSize);
      // All chunks completed -> automatically promoted to VERIFYING in transaction!
      expect(updatedTransfer2.state, TransferState.verifying);

      final dbTransfer2 = await repository.getTransfer(tId);
      expect(dbTransfer2!.state, TransferState.verifying);
      expect(dbTransfer2.completedChunks, 2);
      expect(dbTransfer2.bytesTransferred, fileSize);
      expect(dbTransfer2.allChunksCompleted, isTrue);

      final events2 = await repository.getEventsForTransfer(tId);
      expect(events2.length, 2);
      expect(events2.last.toState, TransferState.verifying);
    });

    test(
        'Zero divergent state: chunk state and transfer progress never desynchronize',
        () async {
      const tId = 't-atomic-2';
      const fileSize = 1000;
      const chunkSize = 500;

      await repository.insertTransfer(
        Transfer(
          id: tId,
          fileName: 'doc.pdf',
          filePath: '/doc.pdf',
          fileSize: fileSize,
          direction: TransferDirection.upload,
          state: TransferState.transferring,
          chunkSize: chunkSize,
          totalChunks: 2,
          fileSha256: 'hash',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      await repository.insertChunks(
        ChunkCalculator.generateChunks(
          transferId: tId,
          fileSize: fileSize,
          chunkSize: chunkSize,
        ),
      );

      // Attempting to complete a non-existent transfer throws and leaves DB clean
      expect(
        () => repository.completeChunkAtomically(
          transferId: 'non-existent',
          chunkIndex: 0,
          sha256: 'mock',
        ),
        throwsStateError,
      );

      // Attempting to complete a non-existent chunk on an existing transfer (T-1)
      expect(
        () => repository.completeChunkAtomically(
          transferId: tId,
          chunkIndex: 999, // Chunk 999 does not exist
          sha256: 'mock',
        ),
        throwsStateError,
      );

      // Original transfer remains completely unmutated
      final original = await repository.getTransfer(tId);
      expect(original!.completedChunks, 0);
      expect(original.bytesTransferred, 0);

      final chunks = await repository.getChunksForTransfer(tId);
      for (final chunk in chunks) {
        expect(chunk.state, ChunkState.pending);
      }
    });

    test('Concurrent repository operations are serialized safely (CR-2)',
        () async {
      const tId = 't-concurrency';
      const fileSize = 10000;
      const chunkSize = 1000;

      await repository.insertTransfer(
        Transfer(
          id: tId,
          fileName: 'concurrent.bin',
          filePath: '/concurrent.bin',
          fileSize: fileSize,
          direction: TransferDirection.upload,
          state: TransferState.transferring,
          chunkSize: chunkSize,
          totalChunks: 10,
          fileSha256: 'hash',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      await repository.insertChunks(
        ChunkCalculator.generateChunks(
          transferId: tId,
          fileSize: fileSize,
          chunkSize: chunkSize,
        ),
      );

      // Fire 10 atomic chunk completions concurrently without awaiting each sequentially
      final futures = List.generate(
        10,
        (i) => repository.completeChunkAtomically(
          transferId: tId,
          chunkIndex: i,
          sha256: 'hash-$i',
        ),
      );

      await Future.wait(futures);

      final completedTransfer = await repository.getTransfer(tId);
      expect(completedTransfer!.completedChunks, 10);
      expect(completedTransfer.bytesTransferred, fileSize);
      expect(completedTransfer.state, TransferState.verifying);

      final events = await repository.getEventsForTransfer(tId);
      expect(events.length, 10);
    });
  });
}
