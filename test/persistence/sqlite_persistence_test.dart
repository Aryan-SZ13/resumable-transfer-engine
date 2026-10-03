import 'package:resumable_transfer_engine/resumable_transfer_engine.dart';
import 'package:test/test.dart';

void main() {
  group('SqlitePersistence', () {
    late SqliteTransferDatabase database;
    late SqliteTransferEngineRepository repository;

    setUp(() {
      database = SqliteTransferDatabase.inMemory();
      repository = SqliteTransferEngineRepository(database);
    });

    tearDown(() {
      database.dispose();
    });

    test('Transfer CRUD and state reloading', () async {
      final now = DateTime.now().toUtc();
      final transfer = Transfer(
        id: 't-persistence-1',
        fileName: 'archive.tar.gz',
        filePath: '/storage/archive.tar.gz',
        fileSize: 10485760,
        direction: TransferDirection.upload,
        state: TransferState.queued,
        chunkSize: 2097152,
        totalChunks: 5,
        fileSha256: 'sha256_mock_hash',
        createdAt: now,
        updatedAt: now,
      );

      // Insert
      await repository.insertTransfer(transfer);

      // Query
      final loaded = await repository.getTransfer('t-persistence-1');
      expect(loaded, isNotNull);
      expect(loaded!.id, 't-persistence-1');
      expect(loaded.fileName, 'archive.tar.gz');
      expect(loaded.fileSize, 10485760);
      expect(loaded.direction, TransferDirection.upload);
      expect(loaded.state, TransferState.queued);
      expect(loaded.totalChunks, 5);
      expect(loaded.completedChunks, 0);
      expect(loaded.bytesTransferred, 0);

      // Update state to TRANSFERRING
      final updated = loaded.copyWith(
        state: TransferState.transferring,
        bytesTransferred: 2097152,
        completedChunks: 1,
      );
      await repository.updateTransfer(updated);

      final reloaded = await repository.getTransfer('t-persistence-1');
      expect(reloaded!.state, TransferState.transferring);
      expect(reloaded.completedChunks, 1);
      expect(reloaded.bytesTransferred, 2097152);
    });

    test('Chunk batch insertion and state tracking', () async {
      const fileSize = 6 * 1024 * 1024; // 6 MB
      const chunkSize = 2 * 1024 * 1024; // 2 MB
      final chunks = ChunkCalculator.generateChunks(
        transferId: 't-chunks-1',
        fileSize: fileSize,
        chunkSize: chunkSize,
      );

      expect(chunks.length, 3);

      // Must insert parent transfer first to satisfy foreign key constraint
      await repository.insertTransfer(
        Transfer(
          id: 't-chunks-1',
          fileName: 'video.mp4',
          filePath: '/data/video.mp4',
          fileSize: fileSize,
          direction: TransferDirection.download,
          state: TransferState.queued,
          chunkSize: chunkSize,
          totalChunks: 3,
          fileSha256: 'video_sha256',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      // Insert chunks
      await repository.insertChunks(chunks);

      final loadedChunks = await repository.getChunksForTransfer('t-chunks-1');
      expect(loadedChunks.length, 3);
      expect(loadedChunks[0].state, ChunkState.pending);
      expect(loadedChunks[1].state, ChunkState.pending);
      expect(loadedChunks[2].state, ChunkState.pending);

      // Update Chunk 0 to COMPLETED
      final chunk0 = loadedChunks[0].copyWith(
        state: ChunkState.completed,
        sha256: 'chunk_0_hash',
      );
      await repository.updateChunk(chunk0);

      final reloadedChunk0 = await repository.getChunk('t-chunks-1', 0);
      expect(reloadedChunk0!.state, ChunkState.completed);
      expect(reloadedChunk0.sha256, 'chunk_0_hash');

      // Query by state
      final completed = await repository.getChunksByState(
        't-chunks-1',
        ChunkState.completed,
      );
      expect(completed.length, 1);

      final pending = await repository.getChunksByState(
        't-chunks-1',
        ChunkState.pending,
      );
      expect(pending.length, 2);
    });

    test('Transfer Event audit trail persistence', () async {
      const tId = 't-event-test';
      await repository.insertTransfer(
        Transfer(
          id: tId,
          fileName: 'data.bin',
          filePath: '/data.bin',
          fileSize: 1000,
          direction: TransferDirection.upload,
          state: TransferState.queued,
          chunkSize: 500,
          totalChunks: 2,
          fileSha256: 'hash',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      final event1 = TransferEvent(
        transferId: tId,
        eventType: TransferEventType.created,
        fromState: TransferState.queued,
        toState: TransferState.queued,
        message: 'Transfer created and initialized',
        timestamp: DateTime.now().toUtc(),
      );

      final event2 = TransferEvent(
        transferId: tId,
        eventType: TransferEventType.started,
        fromState: TransferState.queued,
        toState: TransferState.transferring,
        message: 'Worker assigned',
        timestamp: DateTime.now().toUtc().add(const Duration(seconds: 1)),
      );

      await repository.recordEvent(event1);
      await repository.recordEvent(event2);

      final history = await repository.getEventsForTransfer(tId);
      expect(history.length, 2);
      expect(history[0].eventType, TransferEventType.created);
      expect(history[1].eventType, TransferEventType.started);
    });

    test('Cascade delete removes chunks and events when transfer is deleted',
        () async {
      const tId = 't-cascade';
      await repository.insertTransfer(
        Transfer(
          id: tId,
          fileName: 'to_delete.txt',
          filePath: '/to_delete.txt',
          fileSize: 2048,
          direction: TransferDirection.upload,
          state: TransferState.queued,
          chunkSize: 1024,
          totalChunks: 2,
          fileSha256: 'hash',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      await repository.insertChunks(
        ChunkCalculator.generateChunks(
          transferId: tId,
          fileSize: 2048,
          chunkSize: 1024,
        ),
      );

      await repository.recordEvent(
        TransferEvent(
          transferId: tId,
          eventType: TransferEventType.created,
          fromState: TransferState.queued,
          toState: TransferState.queued,
          timestamp: DateTime.now().toUtc(),
        ),
      );

      expect((await repository.getChunksForTransfer(tId)).length, 2);
      expect((await repository.getEventsForTransfer(tId)).length, 1);

      // Delete transfer
      await repository.deleteTransfer(tId);

      expect(await repository.getTransfer(tId), isNull);
      expect((await repository.getChunksForTransfer(tId)), isEmpty);
      expect((await repository.getEventsForTransfer(tId)), isEmpty);
    });

    test('SQLite PRAGMA configuration (CR-1)', () {
      final db = database.db;
      final busyTimeout = db.select('PRAGMA busy_timeout;').first['timeout'];
      expect(busyTimeout, 5000);

      final foreignKeys =
          db.select('PRAGMA foreign_keys;').first['foreign_keys'];
      expect(foreignKeys, 1);
    });

    test(
        'SQLite CHECK constraints reject invalid transfer numeric values (P-1)',
        () {
      final db = database.db;

      // Negative file_size rejected
      expect(
        () => db.execute('''
          INSERT INTO transfers (
            transfer_id, file_name, file_path, file_size, bytes_transferred,
            direction, state, chunk_size, total_chunks, completed_chunks,
            file_sha256, created_at, updated_at
          ) VALUES (
            'bad-1', 'f', '/p', -1, 0,
            'UPLOAD', 'QUEUED', 100, 1, 0,
            'h', 0, 0
          );
        '''),
        throwsException,
      );

      // bytes_transferred > file_size rejected
      expect(
        () => db.execute('''
          INSERT INTO transfers (
            transfer_id, file_name, file_path, file_size, bytes_transferred,
            direction, state, chunk_size, total_chunks, completed_chunks,
            file_sha256, created_at, updated_at
          ) VALUES (
            'bad-2', 'f', '/p', 100, 101,
            'UPLOAD', 'QUEUED', 100, 1, 0,
            'h', 0, 0
          );
        '''),
        throwsException,
      );

      // completed_chunks > total_chunks rejected
      expect(
        () => db.execute('''
          INSERT INTO transfers (
            transfer_id, file_name, file_path, file_size, bytes_transferred,
            direction, state, chunk_size, total_chunks, completed_chunks,
            file_sha256, created_at, updated_at
          ) VALUES (
            'bad-3', 'f', '/p', 100, 100,
            'UPLOAD', 'QUEUED', 100, 1, 2,
            'h', 0, 0
          );
        '''),
        throwsException,
      );

      // Invalid state enum string rejected
      expect(
        () => db.execute('''
          INSERT INTO transfers (
            transfer_id, file_name, file_path, file_size, bytes_transferred,
            direction, state, chunk_size, total_chunks, completed_chunks,
            file_sha256, created_at, updated_at
          ) VALUES (
            'bad-4', 'f', '/p', 100, 0,
            'UPLOAD', 'INVALID_STATE', 100, 1, 0,
            'h', 0, 0
          );
        '''),
        throwsException,
      );
    });

    test('SQLite CHECK constraints reject invalid chunk values (P-1)', () {
      final db = database.db;
      // Setup valid transfer parent
      db.execute('''
        INSERT INTO transfers (
          transfer_id, file_name, file_path, file_size, bytes_transferred,
          direction, state, chunk_size, total_chunks, completed_chunks,
          file_sha256, created_at, updated_at
        ) VALUES (
          't-parent', 'f', '/p', 1000, 0,
          'UPLOAD', 'QUEUED', 500, 2, 0,
          'h', 0, 0
        );
      ''');

      // Negative retry_count rejected
      expect(
        () => db.execute('''
          INSERT INTO chunks (
            transfer_id, chunk_index, byte_offset, byte_length,
            state, sha256, retry_count, updated_at
          ) VALUES (
            't-parent', 0, 0, 500,
            'PENDING', '', -1, 0
          );
        '''),
        throwsException,
      );

      // Negative byte_length rejected
      expect(
        () => db.execute('''
          INSERT INTO chunks (
            transfer_id, chunk_index, byte_offset, byte_length,
            state, sha256, retry_count, updated_at
          ) VALUES (
            't-parent', 0, 0, -1,
            'PENDING', '', 0, 0
          );
        '''),
        throwsException,
      );
    });

    test('SQLite CHECK constraints reject invalid transfer_events (P-2)', () {
      final db = database.db;
      db.execute('''
        INSERT INTO transfers (
          transfer_id, file_name, file_path, file_size, bytes_transferred,
          direction, state, chunk_size, total_chunks, completed_chunks,
          file_sha256, created_at, updated_at
        ) VALUES (
          't-parent-event', 'f', '/p', 1000, 0,
          'UPLOAD', 'QUEUED', 500, 2, 0,
          'h', 0, 0
        );
      ''');

      // Invalid event_type string rejected
      expect(
        () => db.execute('''
          INSERT INTO transfer_events (
            transfer_id, event_type, from_state, to_state, timestamp
          ) VALUES (
            't-parent-event', 'BOGUS_EVENT', 'QUEUED', 'QUEUED', 0
          );
        '''),
        throwsException,
      );

      // Invalid from_state rejected
      expect(
        () => db.execute('''
          INSERT INTO transfer_events (
            transfer_id, event_type, from_state, to_state, timestamp
          ) VALUES (
            't-parent-event', 'CREATED', 'BOGUS_STATE', 'QUEUED', 0
          );
        '''),
        throwsException,
      );
    });
  });
}
