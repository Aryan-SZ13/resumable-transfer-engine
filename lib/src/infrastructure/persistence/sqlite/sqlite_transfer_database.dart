import 'package:sqlite3/sqlite3.dart';

/// Manages the low-level SQLite database lifecycle, migrations, pragmas, and DDL schema.
class SqliteTransferDatabase {
  final Database db;

  SqliteTransferDatabase(this.db) {
    _initialize();
  }

  /// Factory for creating an in-memory database instance (ideal for isolated unit/integration tests).
  factory SqliteTransferDatabase.inMemory() {
    final db = sqlite3.openInMemory();
    return SqliteTransferDatabase(db);
  }

  /// Factory for opening or creating a persistent file-backed database.
  factory SqliteTransferDatabase.openFile(String path) {
    final db = sqlite3.open(path);
    return SqliteTransferDatabase(db);
  }

  void _initialize() {
    // 1. Enforce strict relational integrity and concurrency pragmas (CR-1)
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA busy_timeout = 5000;');

    try {
      db.execute('PRAGMA journal_mode = WAL;');
      db.execute('PRAGMA synchronous = NORMAL;');
    } catch (_) {
      // In-memory databases do not support WAL mode; ignore safely.
    }

    // 2. Create Schema with Numeric Integrity Constraints (P-1 & P-2)
    db.execute('''
      CREATE TABLE IF NOT EXISTS transfers (
        transfer_id TEXT PRIMARY KEY NOT NULL,
        file_name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_size INTEGER NOT NULL CHECK(file_size >= 0),
        direction TEXT NOT NULL CHECK(direction IN ('UPLOAD', 'DOWNLOAD')),
        state TEXT NOT NULL CHECK(state IN (
          'QUEUED', 'TRANSFERRING', 'RETRYING', 'PAUSED',
          'VERIFYING', 'COMPLETED', 'FAILED', 'CANCELLED'
        )),
        pause_reason TEXT CHECK(pause_reason IN ('USER_PAUSED', 'INTERRUPTED', NULL)),
        chunk_size INTEGER NOT NULL CHECK(chunk_size > 0),
        total_chunks INTEGER NOT NULL CHECK(total_chunks >= 0),
        completed_chunks INTEGER NOT NULL DEFAULT 0 CHECK(completed_chunks >= 0 AND completed_chunks <= total_chunks),
        bytes_transferred INTEGER NOT NULL DEFAULT 0 CHECK(bytes_transferred >= 0 AND bytes_transferred <= file_size),
        file_sha256 TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0 CHECK(retry_count >= 0),
        max_retries INTEGER NOT NULL DEFAULT 5 CHECK(max_retries >= 0),
        error_message TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS chunks (
        transfer_id TEXT NOT NULL,
        chunk_index INTEGER NOT NULL CHECK(chunk_index >= 0),
        byte_offset INTEGER NOT NULL CHECK(byte_offset >= 0),
        byte_length INTEGER NOT NULL CHECK(byte_length >= 0),
        state TEXT NOT NULL CHECK(state IN ('PENDING', 'UPLOADING', 'COMPLETED', 'FAILED')),
        sha256 TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0 CHECK(retry_count >= 0),
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (transfer_id, chunk_index),
        FOREIGN KEY (transfer_id) REFERENCES transfers(transfer_id) ON DELETE CASCADE
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS transfer_events (
        event_id INTEGER PRIMARY KEY AUTOINCREMENT,
        transfer_id TEXT NOT NULL,
        event_type TEXT NOT NULL CHECK(event_type IN (
          'CREATED', 'STARTED', 'CHUNK_COMPLETED', 'CHUNK_FAILED',
          'RETRY_SCHEDULED', 'PAUSED', 'RESUMED', 'VERIFYING',
          'COMPLETED', 'FAILED', 'CANCELLED', 'RECONCILED'
        )),
        from_state TEXT NOT NULL CHECK(from_state IN (
          'QUEUED', 'TRANSFERRING', 'RETRYING', 'PAUSED',
          'VERIFYING', 'COMPLETED', 'FAILED', 'CANCELLED'
        )),
        to_state TEXT NOT NULL CHECK(to_state IN (
          'QUEUED', 'TRANSFERRING', 'RETRYING', 'PAUSED',
          'VERIFYING', 'COMPLETED', 'FAILED', 'CANCELLED'
        )),
        message TEXT,
        timestamp INTEGER NOT NULL,
        FOREIGN KEY (transfer_id) REFERENCES transfers(transfer_id) ON DELETE CASCADE
      );
    ''');

    // 3. Create Performance Indexes
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_transfers_state ON transfers(state);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_chunks_lookup ON chunks(transfer_id, state);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_events_transfer ON transfer_events(transfer_id);');
  }

  /// Closes the underlying SQLite database connection.
  void dispose() {
    db.dispose();
  }
}
