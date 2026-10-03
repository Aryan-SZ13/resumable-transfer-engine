import 'dart:async';
import 'package:sqlite3/sqlite3.dart';

import '../../../domain/models/chunk.dart';
import '../../../domain/models/enums.dart';
import '../../../domain/models/transfer.dart';
import '../../../domain/models/transfer_event.dart';
import '../../../domain/repositories/chunk_repository.dart';
import '../../../domain/repositories/transaction_runner.dart';
import '../../../domain/repositories/transfer_event_repository.dart';
import '../../../domain/repositories/transfer_repository.dart';
import 'sqlite_transfer_database.dart';

/// Lightweight async task serializer to prevent concurrent transaction interleaving on a single SQLite handle (CR-2).
/// Supports re-entrancy within the same async Zone to prevent deadlocks when transactions invoke repository methods.
class _AsyncLock {
  Future<void>? _last;
  static final _lockZoneKey = Object();

  Future<T> synchronized<T>(Future<T> Function() action) {
    if (Zone.current[_lockZoneKey] == this) {
      return action();
    }

    final prev = _last;
    final completer = Completer<void>();
    _last = completer.future;

    return Future(() async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {
          // Swallow previous failure so queue continues processing
        }
      }
      return await runZoned(
        action,
        zoneValues: {_lockZoneKey: this},
      );
    }).whenComplete(() {
      completer.complete();
    });
  }
}

/// Concrete SQLite implementation for Transfer, Chunk, Event persistence, and Transaction coordination.
class SqliteTransferEngineRepository
    implements
        TransferRepository,
        ChunkRepository,
        TransferEventRepository,
        TransactionRunner {
  final SqliteTransferDatabase database;
  final _AsyncLock _lock = _AsyncLock();
  static final _txZoneKey = Object();

  Database get _db => database.db;

  SqliteTransferEngineRepository(this.database);

  // ==========================================
  // TRANSACTION RUNNER IMPLEMENTATION (R-1, CR-2)
  // ==========================================

  @override
  Future<T> runTransaction<T>(Future<T> Function() action) {
    return _lock.synchronized(() async {
      final inTx = Zone.current[_txZoneKey] == true;
      if (!inTx) {
        _db.execute('BEGIN IMMEDIATE TRANSACTION;');
      }
      try {
        final result = await runZoned(
          action,
          zoneValues: {_txZoneKey: true},
        );
        if (!inTx) {
          _db.execute('COMMIT;');
        }
        return result;
      } catch (e) {
        if (!inTx) {
          try {
            _db.execute('ROLLBACK;');
          } catch (_) {
            // Rollback failed, rethrow original exception
          }
        }
        rethrow;
      }
    });
  }

  // ==========================================
  // TRANSFER REPOSITORY IMPLEMENTATION
  // ==========================================

  @override
  Future<void> insertTransfer(Transfer transfer) {
    return _lock.synchronized(() async {
      final stmt = _db.prepare('''
        INSERT INTO transfers (
          transfer_id, file_name, file_path, file_size, direction, state,
          pause_reason, chunk_size, total_chunks, completed_chunks, bytes_transferred,
          file_sha256, retry_count, max_retries, error_message, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''');
      try {
        stmt.execute([
          transfer.id,
          transfer.fileName,
          transfer.filePath,
          transfer.fileSize,
          transfer.direction.name.toUpperCase(),
          transfer.state.name.toUpperCase(),
          transfer.pauseReason?.toDbValue(),
          transfer.chunkSize,
          transfer.totalChunks,
          transfer.completedChunks,
          transfer.bytesTransferred,
          transfer.fileSha256,
          transfer.retryCount,
          transfer.maxRetries,
          transfer.errorMessage,
          transfer.createdAt.millisecondsSinceEpoch,
          transfer.updatedAt.millisecondsSinceEpoch,
        ]);
      } finally {
        stmt.dispose();
      }
    });
  }

  @override
  Future<void> updateTransfer(Transfer transfer) {
    return _lock.synchronized(() async {
      final stmt = _db.prepare('''
        UPDATE transfers SET
          file_name = ?,
          file_path = ?,
          file_size = ?,
          direction = ?,
          state = ?,
          pause_reason = ?,
          chunk_size = ?,
          total_chunks = ?,
          completed_chunks = ?,
          bytes_transferred = ?,
          file_sha256 = ?,
          retry_count = ?,
          max_retries = ?,
          error_message = ?,
          updated_at = ?
        WHERE transfer_id = ?;
      ''');
      try {
        stmt.execute([
          transfer.fileName,
          transfer.filePath,
          transfer.fileSize,
          transfer.direction.name.toUpperCase(),
          transfer.state.name.toUpperCase(),
          transfer.pauseReason?.toDbValue(),
          transfer.chunkSize,
          transfer.totalChunks,
          transfer.completedChunks,
          transfer.bytesTransferred,
          transfer.fileSha256,
          transfer.retryCount,
          transfer.maxRetries,
          transfer.errorMessage,
          transfer.updatedAt.millisecondsSinceEpoch,
          transfer.id,
        ]);
      } finally {
        stmt.dispose();
      }
    });
  }

  @override
  Future<Transfer?> getTransfer(String id) {
    return _lock.synchronized(() async {
      final stmt =
          _db.prepare('SELECT * FROM transfers WHERE transfer_id = ?;');
      try {
        final rows = stmt.select([id]);
        if (rows.isEmpty) return null;
        return _mapTransferRow(rows.first);
      } finally {
        stmt.dispose();
      }
    });
  }

  @override
  Future<List<Transfer>> getAllTransfers() {
    return _lock.synchronized(() async {
      final rows =
          _db.select('SELECT * FROM transfers ORDER BY created_at DESC;');
      return rows.map(_mapTransferRow).toList();
    });
  }

  @override
  Future<List<Transfer>> getTransfersByState(TransferState state) {
    return _lock.synchronized(() async {
      final stmt = _db.prepare(
          'SELECT * FROM transfers WHERE state = ? ORDER BY created_at ASC;');
      try {
        final rows = stmt.select([state.name.toUpperCase()]);
        return rows.map(_mapTransferRow).toList();
      } finally {
        stmt.dispose();
      }
    });
  }

  @override
  Future<List<Transfer>> getActiveOrInterruptedTransfers() {
    return _lock.synchronized(() async {
      final rows = _db.select('''
        SELECT * FROM transfers 
        WHERE state IN ('TRANSFERRING', 'RETRYING', 'VERIFYING')
        ORDER BY created_at ASC;
      ''');
      return rows.map(_mapTransferRow).toList();
    });
  }

  @override
  Future<void> deleteTransfer(String id) {
    return _lock.synchronized(() async {
      final stmt = _db.prepare('DELETE FROM transfers WHERE transfer_id = ?;');
      try {
        stmt.execute([id]);
      } finally {
        stmt.dispose();
      }
    });
  }

  // ==========================================
  // CHUNK REPOSITORY IMPLEMENTATION
  // ==========================================

  @override
  Future<void> insertChunks(List<Chunk> chunks) {
    if (chunks.isEmpty) return Future.value();
    return _lock.synchronized(() async {
      final inTx = Zone.current[_txZoneKey] == true;
      if (!inTx) {
        _db.execute('BEGIN IMMEDIATE TRANSACTION;');
      }
      final stmt = _db.prepare('''
        INSERT INTO chunks (
          transfer_id, chunk_index, byte_offset, byte_length, state, sha256, retry_count, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
      ''');
      try {
        for (final c in chunks) {
          stmt.execute([
            c.transferId,
            c.chunkIndex,
            c.byteOffset,
            c.byteLength,
            c.state.name.toUpperCase(),
            c.sha256,
            c.retryCount,
            c.updatedAt.millisecondsSinceEpoch,
          ]);
        }
        if (!inTx) {
          _db.execute('COMMIT;');
        }
      } catch (e) {
        if (!inTx) {
          try {
            _db.execute('ROLLBACK;');
          } catch (_) {}
        }
        rethrow;
      } finally {
        stmt.dispose();
      }
    });
  }

  @override
  Future<List<Chunk>> getChunksForTransfer(String transferId) {
    return _lock.synchronized(() async {
      final stmt = _db.prepare(
        'SELECT * FROM chunks WHERE transfer_id = ? ORDER BY chunk_index ASC;',
      );
      try {
        final rows = stmt.select([transferId]);
        return rows.map(_mapChunkRow).toList();
      } finally {
        stmt.dispose();
      }
    });
  }

  @override
  Future<Chunk?> getChunk(String transferId, int chunkIndex) {
    return _lock.synchronized(() async {
      final stmt = _db.prepare(
        'SELECT * FROM chunks WHERE transfer_id = ? AND chunk_index = ?;',
      );
      try {
        final rows = stmt.select([transferId, chunkIndex]);
        if (rows.isEmpty) return null;
        return _mapChunkRow(rows.first);
      } finally {
        stmt.dispose();
      }
    });
  }

  @override
  Future<List<Chunk>> getChunksByState(String transferId, ChunkState state) {
    return _lock.synchronized(() async {
      final stmt = _db.prepare(
        'SELECT * FROM chunks WHERE transfer_id = ? AND state = ? ORDER BY chunk_index ASC;',
      );
      try {
        final rows = stmt.select([transferId, state.name.toUpperCase()]);
        return rows.map(_mapChunkRow).toList();
      } finally {
        stmt.dispose();
      }
    });
  }

  @override
  Future<void> updateChunk(Chunk chunk) {
    return _lock.synchronized(() async {
      final stmt = _db.prepare('''
        UPDATE chunks SET
          state = ?,
          sha256 = ?,
          retry_count = ?,
          updated_at = ?
        WHERE transfer_id = ? AND chunk_index = ?;
      ''');
      try {
        stmt.execute([
          chunk.state.name.toUpperCase(),
          chunk.sha256,
          chunk.retryCount,
          chunk.updatedAt.millisecondsSinceEpoch,
          chunk.transferId,
          chunk.chunkIndex,
        ]);
      } finally {
        stmt.dispose();
      }
    });
  }

  @override
  Future<int> resetChunkStates({
    required String transferId,
    required ChunkState fromState,
    required ChunkState toState,
  }) {
    return _lock.synchronized(() async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final stmt = _db.prepare('''
        UPDATE chunks SET state = ?, updated_at = ?
        WHERE transfer_id = ? AND state = ?;
      ''');
      try {
        stmt.execute([
          toState.name.toUpperCase(),
          now,
          transferId,
          fromState.name.toUpperCase(),
        ]);
        return _db.updatedRows;
      } finally {
        stmt.dispose();
      }
    });
  }

  // ==========================================
  // TRANSFER EVENT REPOSITORY IMPLEMENTATION
  // ==========================================

  @override
  Future<void> recordEvent(TransferEvent event) {
    return _lock.synchronized(() async {
      final stmt = _db.prepare('''
        INSERT INTO transfer_events (
          transfer_id, event_type, from_state, to_state, message, timestamp
        ) VALUES (?, ?, ?, ?, ?, ?);
      ''');
      try {
        stmt.execute([
          event.transferId,
          event.eventType.toDbString(),
          event.fromState.name.toUpperCase(),
          event.toState.name.toUpperCase(),
          event.message,
          event.timestamp.millisecondsSinceEpoch,
        ]);
      } finally {
        stmt.dispose();
      }
    });
  }

  @override
  Future<List<TransferEvent>> getEventsForTransfer(String transferId) {
    return _lock.synchronized(() async {
      final stmt = _db.prepare(
        'SELECT * FROM transfer_events WHERE transfer_id = ? ORDER BY timestamp ASC, event_id ASC;',
      );
      try {
        final rows = stmt.select([transferId]);
        return rows.map(_mapEventRow).toList();
      } finally {
        stmt.dispose();
      }
    });
  }

  // ==========================================
  // TRANSACTIONAL CONSISTENCY BOUNDARY (T-1)
  // ==========================================

  /// Atomically commits chunk completion, updates aggregated transfer progress,
  /// transitions transfer state to VERIFYING if all chunks completed, and logs an event.
  /// Throws [StateError] and rolls back if target chunk does not exist (T-1).
  Future<Transfer> completeChunkAtomically({
    required String transferId,
    required int chunkIndex,
    required String sha256,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now().toUtc();
    final epochMs = timestamp.millisecondsSinceEpoch;

    return _lock.synchronized(() async {
      final inTx = Zone.current[_txZoneKey] == true;
      if (!inTx) {
        _db.execute('BEGIN IMMEDIATE TRANSACTION;');
      }
      try {
        // 1. Mark chunk as COMPLETED and validate updatedRows == 1 (T-1)
        final updateChunkStmt = _db.prepare('''
          UPDATE chunks SET state = 'COMPLETED', sha256 = ?, updated_at = ?
          WHERE transfer_id = ? AND chunk_index = ?;
        ''');
        try {
          updateChunkStmt.execute([sha256, epochMs, transferId, chunkIndex]);
          if (_db.updatedRows != 1) {
            throw StateError(
              'Cannot complete chunk: chunkIndex $chunkIndex for transfer "$transferId" does not exist.',
            );
          }
        } finally {
          updateChunkStmt.dispose();
        }

        // 2. Query verified totals directly from SQLite
        final tallyStmt = _db.prepare('''
          SELECT COUNT(*) as count, COALESCE(SUM(byte_length), 0) as total_bytes
          FROM chunks
          WHERE transfer_id = ? AND state = 'COMPLETED';
        ''');
        late final int completedCount;
        late final int completedBytes;
        try {
          final tallyRow = tallyStmt.select([transferId]).first;
          completedCount = tallyRow['count'] as int;
          completedBytes = tallyRow['total_bytes'] as int;
        } finally {
          tallyStmt.dispose();
        }

        // 3. Fetch current transfer to inspect totalChunks and current state
        final currentTransferStmt = _db.prepare(
          'SELECT * FROM transfers WHERE transfer_id = ?;',
        );
        late final Transfer current;
        try {
          final rows = currentTransferStmt.select([transferId]);
          if (rows.isEmpty) {
            throw StateError(
                'Transfer "$transferId" not found for chunk completion.');
          }
          current = _mapTransferRow(rows.first);
        } finally {
          currentTransferStmt.dispose();
        }

        // 4. Determine if all chunks are done -> transition to VERIFYING
        final bool isAllCompleted = completedCount >= current.totalChunks;
        final TransferState nextState =
            isAllCompleted ? TransferState.verifying : current.state;

        // 5. Update transfer master record
        final updateTransferStmt = _db.prepare('''
          UPDATE transfers SET
            completed_chunks = ?,
            bytes_transferred = ?,
            state = ?,
            updated_at = ?
          WHERE transfer_id = ?;
        ''');
        try {
          updateTransferStmt.execute([
            completedCount,
            completedBytes,
            nextState.name.toUpperCase(),
            epochMs,
            transferId,
          ]);
        } finally {
          updateTransferStmt.dispose();
        }

        // 6. Record audit event
        final recordEventStmt = _db.prepare('''
          INSERT INTO transfer_events (
            transfer_id, event_type, from_state, to_state, message, timestamp
          ) VALUES (?, ?, ?, ?, ?, ?);
        ''');
        try {
          recordEventStmt.execute([
            transferId,
            TransferEventType.chunkCompleted.toDbString(),
            current.state.name.toUpperCase(),
            nextState.name.toUpperCase(),
            'Chunk $chunkIndex marked COMPLETED ($completedCount/${current.totalChunks})',
            epochMs,
          ]);
        } finally {
          recordEventStmt.dispose();
        }

        if (!inTx) {
          _db.execute('COMMIT;');
        }

        return current.copyWith(
          completedChunks: completedCount,
          bytesTransferred: completedBytes,
          state: nextState,
          updatedAt: timestamp,
        );
      } catch (e) {
        if (!inTx) {
          try {
            _db.execute('ROLLBACK;');
          } catch (_) {}
        }
        rethrow;
      }
    });
  }

  // ==========================================
  // PRIVATE ROW MAPPERS
  // ==========================================

  Transfer _mapTransferRow(Row row) {
    return Transfer(
      id: row['transfer_id'] as String,
      fileName: row['file_name'] as String,
      filePath: row['file_path'] as String,
      fileSize: row['file_size'] as int,
      direction: TransferDirection.fromString(row['direction'] as String),
      state: TransferState.fromString(row['state'] as String),
      pauseReason: PauseReason.fromString(row['pause_reason'] as String?),
      chunkSize: row['chunk_size'] as int,
      totalChunks: row['total_chunks'] as int,
      completedChunks: row['completed_chunks'] as int,
      bytesTransferred: row['bytes_transferred'] as int,
      fileSha256: row['file_sha256'] as String,
      retryCount: row['retry_count'] as int,
      maxRetries: row['max_retries'] as int,
      errorMessage: row['error_message'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int,
          isUtc: true),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int,
          isUtc: true),
    );
  }

  Chunk _mapChunkRow(Row row) {
    return Chunk(
      transferId: row['transfer_id'] as String,
      chunkIndex: row['chunk_index'] as int,
      byteOffset: row['byte_offset'] as int,
      byteLength: row['byte_length'] as int,
      state: ChunkState.fromString(row['state'] as String),
      sha256: (row['sha256'] as String?) ?? '',
      retryCount: row['retry_count'] as int,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int,
          isUtc: true),
    );
  }

  TransferEvent _mapEventRow(Row row) {
    return TransferEvent(
      eventId: row['event_id'] as int,
      transferId: row['transfer_id'] as String,
      eventType: TransferEventType.fromString(row['event_type'] as String),
      fromState: TransferState.fromString(row['from_state'] as String),
      toState: TransferState.fromString(row['to_state'] as String),
      message: row['message'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int,
          isUtc: true),
    );
  }
}
