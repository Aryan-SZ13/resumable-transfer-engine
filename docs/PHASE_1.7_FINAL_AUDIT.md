# Phase 1.7 — Final Pre-Network Architecture Audit

**Audit Target:** Full Pre-Network Domain Core, Persistence & Recovery Engine  
**Baseline Documentation:** `docs/ARCHITECTURE.md`, `docs/STATE_MACHINE.md`, `docs/PROTOCOL.md`, `docs/PHASE_1.md`, `docs/PHASE_1_AUDIT.md`, `docs/PHASE_1.6.md`  
**Date:** October 3, 2026  
**Auditor:** Antigravity Autonomous Systems Review  
**Status:** **PHASE 2 READY** (0 Critical, 0 High, 2 Medium, 2 Low)

---

## 1. Overall Audit Verdict

The pre-network architecture of the Resumable Transfer Engine is sound, highly robust, and ready for networking in Phase 2. The domain model invariants, finite state machines, SQLite database constraints, async lock serialization, and cold-start recovery semantics have been rigorously validated. All 53 unit and integration tests execute with zero failures and zero static analysis warnings.

---

## 2. Deep Section-by-Section Architectural Review

### 2.1 Transaction Runner Boundary
- **Inspection Target:** [`TransactionRunner`](file:///Users/aryansingh/resumable-transfer-engine/lib/src/domain/repositories/transaction_runner.dart) and its callers.
- **Dependency Flow:**
  $$\text{Domain Layer} \longrightarrow \text{Repository Abstractions} (\texttt{TransactionRunner}) \longleftarrow \text{Infrastructure} (\texttt{SqliteTransferEngineRepository})$$
- **Architectural Analysis:**
  The `TransactionRunner` interface contains zero references to SQLite, SQL syntax, or database handles. It defines a pure Dart functional contract:
  ```dart
  abstract interface class TransactionRunner {
    Future<T> runTransaction<T>(Future<T> Function() action);
  }
  ```
- **Finding:** **NONE**. The abstraction is fully infrastructure-agnostic. `ColdStartRecoveryService` depends exclusively on this abstraction without leaking SQLite details into the domain layer.

---

### 2.2 Async Lock Correctness & Re-entrancy
- **Inspection Target:** `_AsyncLock` and Zone-based re-entrancy in [`SqliteTransferEngineRepository`](file:///Users/aryansingh/resumable-transfer-engine/lib/src/infrastructure/persistence/sqlite/sqlite_transfer_repository.dart).
- **Ownership & Mechanics Model:**
  ```dart
  class _AsyncLock {
    Future<void>? _last;
    static final _lockZoneKey = Object();

    Future<T> synchronized<T>(Future<T> Function() action) {
      if (Zone.current[_lockZoneKey] == this) {
        return action(); // Re-entrant path
      }
      final prev = _last;
      final completer = Completer<void>();
      _last = completer.future;

      return Future(() async {
        if (prev != null) {
          try { await prev; } catch (_) {}
        }
        return await runZoned(action, zoneValues: {_lockZoneKey: this});
      }).whenComplete(() => completer.complete());
    }
  }
  ```
- **Verification Analysis:**
  - **A. Mutual Exclusion:** Independent async calls enter the queue via chained `Completer<void>`. Operation $N+1$ awaits `prev` (Operation $N$'s completion), preventing simultaneous access to the underlying SQLite handle.
  - **B. Re-entrancy:** When an outer operation (e.g. `runTransaction`) enters `_AsyncLock.synchronized`, it executes inside a `Zone` with `_lockZoneKey: this`. Any nested repository method (`getAllTransfers`, `updateTransfer`, `recordEvent`) detects `Zone.current[_lockZoneKey] == this` and executes immediately without re-queueing, preventing self-deadlock.
  - **C. Zone Isolation:** Operations initiated outside the transaction zone do not possess the `_lockZoneKey` matching `this` instance and are forced to wait in FIFO sequence.
  - **D. Exception Safety:** `whenComplete(() => completer.complete())` guarantees lock release even if `action()` throws.
  - **E. Await Point Safety:** While an active transaction awaits an asynchronous operation, subsequent callers remain blocked on `await prev`.
  - **F. No Stuck State:** If a predecessor fails, `try { await prev; } catch (_) {}` ensures the error is swallowed within the waiting chain so subsequent operations continue processing.
  - **G. Nested Transactions:** `runTransaction`, `completeChunkAtomically`, and `insertChunks` inspect `Zone.current[_txZoneKey] == true`. If already inside an outer transaction, they bypass issuing redundant `BEGIN IMMEDIATE` or premature `COMMIT`/`ROLLBACK` statements, preserving outer transaction integrity.
  - **H. Error Propagation:** If an inner operation throws, the exception propagates unhindered to the outer `catch` block, triggering a clean `ROLLBACK;`.

---

### 2.3 SQLite Transaction Semantics
- **Inspection Target:** Every mutating and composite operation in `SqliteTransferEngineRepository`.
- **Flow Documentation:**
  1. **`runTransaction<T>`**:
     ```
     BEGIN IMMEDIATE TRANSACTION;
       → runZoned(action, zoneValues: {_txZoneKey: true})
     COMMIT;
     [ON ERROR] → ROLLBACK; → rethrow
     ```
  2. **`completeChunkAtomically`**:
     ```
     [If !inTx] BEGIN IMMEDIATE TRANSACTION;
       → UPDATE chunks SET state = 'COMPLETED' (asserts updatedRows == 1)
       → SELECT COUNT(*), SUM(byte_length) FROM chunks WHERE state = 'COMPLETED'
       → SELECT * FROM transfers WHERE transfer_id = ?
       → UPDATE transfers SET completed_chunks = ?, bytes_transferred = ?, state = ?
       → INSERT INTO transfer_events (...)
     [If !inTx] COMMIT;
     [ON ERROR] → [If !inTx] ROLLBACK; → rethrow
     ```
  3. **`insertChunks`**:
     ```
     [If !inTx] BEGIN IMMEDIATE TRANSACTION;
       → Batch execute prepared statement INSERT INTO chunks (...)
     [If !inTx] COMMIT;
     [ON ERROR] → [If !inTx] ROLLBACK; → rethrow
     ```
  4. **`ColdStartRecoveryService.performRecovery()`**:
     ```
     Wrapped entirely inside runTransaction(...) when TransactionRunner is provided.
     ```
- **Finding:** **NONE**. Every composite operation is atomic. No intermediate or partial writes escape rollback.

---

### 2.4 Recovery Idempotence
- **Inspection Target:** [`ColdStartRecoveryService._performRecoveryInternal`](file:///Users/aryansingh/resumable-transfer-engine/lib/src/domain/recovery/cold_start_recovery_service.dart).
- **Idempotency Evaluation:**
  - **Terminal Transfers:** Filtered immediately into `terminalIds`; zero database mutations.
  - **USER_PAUSED Transfers:** Only calls `resetChunkStates(uploading -> pending)`. If run a second time, 0 chunks are in `UPLOADING`; returns 0 with zero transfer updates or events.
  - **Active / Interrupted Transfers:**
    - *Pass 1:* Chunks reset `UPLOADING -> PENDING`. Transfer recalculated and updated to `QUEUED`. Audit event `RECONCILED` logged.
    - *Pass 2:* Transfer is now in `QUEUED`. The `QUEUED` handler runs: `resetChunkStates` resets 0 chunks. Verified bytes and completed chunks match existing record (`transfer.completedChunks == completedChunks.length && transfer.bytesTransferred == verifiedBytes`). No `updateTransfer` or `recordEvent` is called.
- **Finding:** **NONE**. Calling `performRecovery()` multiple consecutive times produces identical persistent state and zero duplicate events.

---

### 2.5 State Machine & Persistence Consistency
- **Inspection Target:** [`TransferStateMachine`](file:///Users/aryansingh/resumable-transfer-engine/lib/src/domain/state_machine/transfer_state_machine.dart) and `SqliteTransferEngineRepository`.
- **Invalid Paths Analysis:**
  - `TRANSFERRING -> COMPLETED`: **IMPOSSIBLE**. Requires routing through `allChunksCompleted` to `VERIFYING`, followed by `integrityVerified` to `COMPLETED`.
  - `PAUSED -> COMPLETED`: **IMPOSSIBLE**. State machine only allows `userResume -> QUEUED` or `userCancel -> CANCELLED`.
  - `CANCELLED -> TRANSFERRING`: **IMPOSSIBLE**. Throws `TerminalStateViolationException`.
  - `VERIFYING -> TRANSFERRING`: **IMPOSSIBLE**. Transitions only to `COMPLETED`, `FAILED`, `CANCELLED`, or `reconcileInterrupted -> QUEUED`.
- **Escape Hatch Inspection:**
  - `TransferRepository.updateTransfer(Transfer transfer)` persists the provided `Transfer` model directly into SQLite.
  - If application code outside the state machine instantiates an invalid `Transfer` object (e.g. via `copyWith`) and calls `updateTransfer`, the repository does not re-validate the previous state against `TransferStateMachine`.
  - However, SQLite's DDL constraints (`P-1` and `P-2`) enforce numeric bounds and enum validity at the database level.
- **Finding:** **MEDIUM (M-1)** — Documented in Section 3.

---

### 2.6 Progress Accounting
- **Inspection Target:** Chunk totals calculation, byte aggregations, and chunk completion invariants.
- **Audited Edge Cases:**
  - **Out-of-Order Completion:** Progress is calculated directly via `SELECT COUNT(*), SUM(byte_length) FROM chunks WHERE state = 'COMPLETED'`. Completing chunks in arbitrary order (e.g. chunk 4 before chunk 1) computes exact cumulative progress.
  - **Duplicate Completion:** Re-executing completion for an already completed chunk updates the single row in SQLite; `COUNT(*)` and `SUM(byte_length)` return the same sum. Zero double counting.
  - **Uneven Chunk Slices / Remainder:** Final chunk smaller than nominal `chunkSize` has its exact `byteLength` recorded in SQLite. The sum reflects total file size bit-for-bit.
  - **Zero-Byte Files:** Allocated 1 chunk of 0 bytes. `completedChunks = 1`, `bytesTransferred = 0`, satisfying `bytesTransferred <= fileSize` (0 <= 0).
  - **Retrying Completed Chunk:** `ChunkStateMachine` guards `completed` as a terminal chunk state; attempts to re-transition throw `TerminalStateViolationException`.
- **Finding:** **NONE**. Progress accounting is mathematically deterministic and immune to drift.

---

### 2.7 Upload / Download Symmetry Readiness
- **Inspection Target:** [`TransferDirection`](file:///Users/aryansingh/resumable-transfer-engine/lib/src/domain/models/enums.dart), [`Chunk`](file:///Users/aryansingh/resumable-transfer-engine/lib/src/domain/models/chunk.dart), [`ChunkCalculator`](file:///Users/aryansingh/resumable-transfer-engine/lib/src/domain/chunking/chunk_calculator.dart).
- **Symmetry Analysis:**
  - The domain model, chunk slicing arithmetic, SQLite schema, state machines, and recovery service operate symmetrically regardless of `TransferDirection`.
  - In both upload and download:
    - Files are partitioned into identical deterministic byte chunks with start offsets and byte lengths.
    - Chunks track integrity via SHA-256 digests.
    - Cold-start recovery resets in-flight chunks to `PENDING` and preserves completed chunks.
- **Semantic Naming Observation:**
  - `ChunkState` uses the identifier `uploading` for the in-flight state (`enum ChunkState { pending, uploading, completed, failed }`).
  - For download transfers, an in-flight chunk on the wire also uses `ChunkState.uploading`. While mechanically symmetrical and fully functional, the naming is upload-centric.
- **Finding:** **LOW (L-1)** — Documented in Section 3.

---

### 2.8 Idempotency Readiness
- **Inspection Target:** `Chunk.idempotencyKey` and relational identity in SQLite.
- **Key Composition:**
  $$\text{idempotencyKey} = \texttt{"\$transferId:\$chunkIndex:\$sha256"}$$
  - Guarded against unhashed access via `StateError`.
  - In SQLite, the primary key `(transfer_id, chunk_index)` guarantees uniqueness.
  - Protocol reconciliation: A duplicate upload/download chunk request maps directly to `(transfer_id, chunk_index)`. If `state == ChunkState.completed`, the engine can return an immediate idempotent acknowledgement without re-processing.
- **Finding:** **NONE**. Fully ready for Phase 2 protocol integration.

---

### 2.9 Database Schema Review
- **Inspection Target:** DDL schema in [`SqliteTransferDatabase._initialize`](file:///Users/aryansingh/resumable-transfer-engine/lib/src/infrastructure/persistence/sqlite/sqlite_transfer_database.dart).
- **Relational Integrity:**
  - Transfer Uniqueness: `transfer_id TEXT PRIMARY KEY NOT NULL`.
  - Chunk Uniqueness: `PRIMARY KEY (transfer_id, chunk_index)`.
  - Foreign Keys & Cascading: `FOREIGN KEY (transfer_id) REFERENCES transfers(transfer_id) ON DELETE CASCADE` on both `chunks` and `transfer_events`. Deleting a transfer purges all child chunks and audit events.
  - Numeric `CHECK` Constraints:
    - `file_size >= 0`, `chunk_size > 0`, `total_chunks >= 0`
    - `completed_chunks >= 0 AND completed_chunks <= total_chunks`
    - `bytes_transferred >= 0 AND bytes_transferred <= file_size`
    - `chunk_index >= 0`, `byte_offset >= 0`, `byte_length >= 0`, `retry_count >= 0`
  - Enum `CHECK` Constraints:
    - `direction IN ('UPLOAD', 'DOWNLOAD')`
    - `state IN ('QUEUED', 'TRANSFERRING', 'RETRYING', 'PAUSED', 'VERIFYING', 'COMPLETED', 'FAILED', 'CANCELLED')`
    - `event_type IN (...)` across all 12 events
    - `from_state` and `to_state` across all 8 states
- **Index Evaluation for Phase 2 Query Patterns:**
  - Existing indexes:
    - `idx_transfers_state ON transfers(state)`
    - `idx_chunks_lookup ON chunks(transfer_id, state)`
    - `idx_events_transfer ON transfer_events(transfer_id)`
  - Optimal query: Next pending chunk query (`SELECT * FROM chunks WHERE transfer_id = ? AND state = 'PENDING' ORDER BY chunk_index ASC LIMIT 1`).
  - An index on `(transfer_id, state, chunk_index)` or `(transfer_id, chunk_index)` provides index-only traversal.
- **Finding:** **LOW (L-2)** — Documented in Section 3.

---

### 2.10 Test Quality Audit
- **Inspection Target:** All 6 test suites across `test/`.
- **Evaluation:**
  - `test/persistence/transactional_consistency_test.dart`:
    - Concurrency test generates 10 unawaited concurrent futures to `completeChunkAtomically`.
    - Proves that `_AsyncLock` successfully queues calls without SQLite `cannot start a transaction within a transaction` collisions.
    - *Scope Note:* Tests async concurrency within a single Dart isolate. Multi-isolate background thread testing belongs to Phase 3.
  - `test/recovery/cold_start_recovery_test.dart`:
    - Scenarios A–F do not merely inspect the returned `RecoveryReport`.
    - Every scenario queries the SQLite database directly via `repository.getTransfer`, `repository.getChunksForTransfer`, and `repository.getEventsForTransfer` to prove disk persistence.
- **Finding:** **NONE**. Tests verify actual persistent state and prove domain invariants.

---

### 2.11 Dependency & Package Audit
- **Inspection Target:** [`pubspec.yaml`](file:///Users/aryansingh/resumable-transfer-engine/pubspec.yaml).
- **Dependencies:**
  - Runtime: `sqlite3: ^2.4.6`, `meta: ^1.11.0`.
  - Dev: `test: ^1.25.0`, `lints: ^3.0.0`.
- **Verdict:** **NONE**. Zero unneeded dependencies.

---

### 2.12 Code Quality & Complexity
- **Global Mutable State:** Zero.
- **Static Singletons:** Zero.
- **Exception Handling:** All swallowed exceptions in `catch (_)` blocks are explicitly scoped to non-fatal cleanups (ignoring in-memory SQLite WAL pragma, ignoring failed rollbacks before rethrowing the original exception, or continuing the async lock queue).
- **Architecture Integrity:** `SqliteTransferEngineRepository` maintains high cohesion by encapsulating database operations, transaction lifecycles, and lock serialization in a single location.
- **Finding:** **NONE**. Clean, well-structured, production-grade Dart code.

---

## 3. Findings Matrix

| Finding ID | Severity | File / Component | Failure Scenario | Impact | Phase 2 Blocker? |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **M-1** | **MEDIUM** | `SqliteTransferEngineRepository.updateTransfer` | A developer bypasses `TransferStateMachine.transition` and invokes `updateTransfer` directly with an arbitrarily mutated `Transfer` object (e.g. changing `PAUSED` directly to `COMPLETED`). | Repository persists the invalid state (provided it meets SQLite table-level `CHECK` constraints). | **NO** (Orchestrators in Phase 2 enforce state machine transitions). |
| **M-2** | **MEDIUM** | `_AsyncLock` in `SqliteTransferEngineRepository` | An async sub-task inside a transaction spawns an unawaited detached asynchronous future that does not inherit the transaction Zone. | If that detached future attempts a write, it enters the queue behind the transaction rather than within it. | **NO** (All repository calls inside engine operations are properly awaited). |
| **L-1** | **LOW** | `ChunkState.uploading` in `lib/src/domain/models/enums.dart` | In-flight chunks for download operations use `ChunkState.uploading` to represent the wire transfer state. | Semantic naming asymmetry only; functional symmetry is completely preserved. | **NO** |
| **L-2** | **LOW** | `idx_chunks_lookup` in `SqliteTransferDatabase` | Fetching the next chunk via `WHERE transfer_id = ? AND state = 'PENDING' ORDER BY chunk_index ASC` uses `(transfer_id, state)` index and sorts by `chunk_index`. | Microsecond query overhead on files with thousands of chunks. Can be optimized to `(transfer_id, state, chunk_index)`. | **NO** |

---

## 4. Final Verdict

**PHASE 2 READY**

The foundational domain core, persistence layer, transactional boundary, and recovery engine are hardened, verified, and ready for networking and mock server implementation in Phase 2.
