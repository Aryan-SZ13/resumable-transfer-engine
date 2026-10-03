# Phase 1 — Domain Core & Persistence

## 1. Overview & Objectives Accomplished

Phase 1 establishes the rock-solid, fully tested domain core and persistence foundation for the **Resumable Transfer Engine** strictly aligned with the Phase 0 architecture.

In accordance with Phase 1 constraints:
- **No networking code, mock servers, HTTP clients, background workers, or UI widgets were implemented.**
- The implementation is centered on strongly typed domain models, deterministic chunk calculations, the authoritative state machines, SQLite database schema with foreign keys and WAL mode, atomic transactional updates, and the cold-start recovery service.
- All code has been formatted (`dart format .`), statically analyzed with zero warnings (`dart analyze`), and verified against a comprehensive 29-test automated test suite (`dart test`).

---

## 2. Domain Models & Value Objects

All domain models are immutable, strongly typed, and encapsulated within `lib/src/domain/models/`:

### 2.1 Enums (`enums.dart`)
- **`TransferDirection`**: `upload`, `download`.
- **`TransferState`**: `queued`, `transferring`, `retrying`, `paused`, `verifying`, `completed`, `failed`, `cancelled`.
  - Properties: `isTerminal`, `isActive`, `canResume`.
- **`PauseReason`**: `userPaused`, `interrupted` (explicitly distinguishing `USER_PAUSED != INTERRUPTED != CANCELLED`).
- **`ChunkState`**: `pending`, `uploading`, `completed`, `failed`.
- **`TransferEventType`**: `created`, `started`, `chunkCompleted`, `chunkFailed`, `retryScheduled`, `paused`, `resumed`, `verifying`, `completed`, `failed`, `cancelled`, `reconciled`.

### 2.2 Models
- **`Transfer`**: Holds holistic transfer identity, file paths, size, progress bytes, chunk configurations, retry information, SHA-256 hash manifest, timestamps, and error details. Progress fraction and percentage are purely derived from `bytesTransferred / fileSize`.
- **`Chunk`**: Represents an isolated segment with `transferId`, `chunkIndex`, `byteOffset`, `byteLength`, `state`, `sha256`, and `retryCount`. Includes `idempotencyKey` derivation (`$transferId:$chunkIndex:$sha256`).
- **`TransferEvent`**: An immutable audit log entry documenting state transitions and reasons.

---

## 3. Deterministic Chunk Arithmetic (`chunk_calculator.dart`)

The `ChunkCalculator` provides pure functional mathematical routines:
- Calculates `totalChunks = (fileSize + chunkSize - 1) ~/ chunkSize` for files $> 0$.
- Safely handles zero-byte files (1 chunk of length 0).
- Truncates remainder bytes for the final chunk:
  $$\text{length}(i) = \min(\text{chunkSize}, \text{fileSize} - \text{offset}(i))$$
- Validates that the sum of all generated chunk lengths equals `fileSize` bit-for-bit.

---

## 4. State Machine Implementation

### 4.1 Transfer State Machine (`transfer_state_machine.dart`)
Provides the single authoritative transition mechanism:
`TransferStateMachine.transition(Transfer current, TransferEventTrigger trigger, ...)`

- **Valid Transitions**:
  - `QUEUED -> TRANSFERRING -> VERIFYING -> COMPLETED`
  - `TRANSFERRING -> PAUSED(reason = USER_PAUSED)`
  - `PAUSED -> QUEUED` (via explicit `userResume`)
  - `TRANSFERRING -> RETRYING -> TRANSFERRING` (bounded by `maxRetries = 5`)
  - `RETRYING -> FAILED` (when retries exhausted)
  - `* -> CANCELLED`
  - Unexpected Interruption: `TRANSFERRING / RETRYING / VERIFYING -> QUEUED`
- **Guarded Constraints**:
  - Terminal states (`COMPLETED`, `CANCELLED`, `FAILED`) throw `TerminalStateViolationException` if any transition is attempted.
  - Jumping directly from `PAUSED` to `TRANSFERRING` is rejected; must route through `QUEUED`.
  - Skipping `VERIFYING` to reach `COMPLETED` is strictly prohibited.

### 4.2 Chunk State Machine (`chunk_state_machine.dart`)
- Governs individual chunk lifecycle:
  - `PENDING -> UPLOADING -> COMPLETED`
  - `UPLOADING -> FAILED -> (retry) -> UPLOADING`
  - `UPLOADING -> PENDING` (graceful abort / cold-start crash recovery)
  - Terminal protection: `COMPLETED -> Any` throws `IllegalStateTransitionException`.

---

## 5. Persistence Schema & SQLite Implementation

Backed by the canonical `sqlite3` Dart FFI package. Operates on file-based databases or isolated in-memory databases (`sqlite3.openInMemory()`) for testing.

### 5.1 Tables & Schema
1. **`transfers`**: Primary key `transfer_id`, strict `CHECK` constraints on `state`, `direction`, and `pause_reason`.
2. **`chunks`**: Composite primary key `(transfer_id, chunk_index)`. Foreign key references `transfers(transfer_id) ON DELETE CASCADE`.
3. **`transfer_events`**: Autoincrement `event_id`, foreign key references `transfers(transfer_id) ON DELETE CASCADE`.
4. **Indexes**: `idx_transfers_state`, `idx_chunks_lookup`, `idx_events_transfer`.
5. **Pragmas**: `PRAGMA foreign_keys = ON;`, `PRAGMA journal_mode = WAL;`.

### 5.2 Repositories Decoupling
Domain interfaces are defined without any SQL dependencies:
- `TransferRepository`: CRUD, state filtering, and interrupted transfer lookup.
- `ChunkRepository`: Batch insertion, lookup by state, and chunk state reset.
- `TransferEventRepository`: Audit event appending and query.
- `SqliteTransferEngineRepository`: Implements all three interfaces.

---

## 6. Transaction Boundaries & Crash Consistency

To prevent impossible states where a chunk is `COMPLETED` but transfer progress is 0, the repository exposes:
`completeChunkAtomically(...)`

Within an immediate SQLite transaction (`BEGIN IMMEDIATE TRANSACTION ... COMMIT`):
1. Updates chunk row: `state = 'COMPLETED'`, `sha256 = ?`.
2. Re-queries SQLite for actual completed count and byte sum (`SELECT COUNT(*), SUM(byte_length) FROM chunks WHERE state = 'COMPLETED'`).
3. Updates `transfers` row with exact counts and bytes.
4. If `completed_chunks >= total_chunks`, atomically transitions transfer state to `VERIFYING`.
5. Inserts a `TransferEvent` audit record.
6. If any step fails, the entire transaction is rolled back (`ROLLBACK;`).

---

## 7. Cold-Start Recovery Algorithm

Implemented in `ColdStartRecoveryService`:
1. Scans all persisted transfers on application boot.
2. Identifies transfers left in dirty active states (`TRANSFERRING`, `RETRYING`, `VERIFYING`) due to abrupt process termination.
3. Resets all in-flight chunks in state `UPLOADING -> PENDING`.
4. Preserves all `COMPLETED` chunks intact.
5. Recalculates verified progress strictly from SQLite `COMPLETED` chunks.
6. Reconciles the transfer to **`QUEUED`** (enqueued for automatic continuation without requiring user button press).
7. Transcribing the core demonstration:
   $$\text{40\% complete} \to \text{kill app} \to \text{restart} \to \text{restored at 40\%} \to \text{resumes seamlessly.}$$
8. Transfers marked `PAUSED(reason = USER_PAUSED)` remain `PAUSED`.
9. Transfers marked `CANCELLED` remain permanently `CANCELLED` (never resurrected).
10. Transfers marked `COMPLETED` remain `COMPLETED`.

---

## 8. Test Strategy & Results

Automated test suites were developed across five distinct test files:
- **`test/domain/state_machine_test.dart`**: Legal transitions, terminal state protection, retry exhaustion, USER_PAUSED semantics.
- **`test/domain/chunk_calculator_test.dart`**: Exact chunk divisions, remainder chunks, small files, 0-byte files, invalid argument handling.
- **`test/persistence/sqlite_persistence_test.dart`**: Transfer/chunk/event CRUD, state filtering, foreign-key cascade deletes.
- **`test/persistence/transactional_consistency_test.dart`**: Atomic chunk completion, zero divergent progress states, automatic promotion to `VERIFYING`.
- **`test/recovery/cold_start_recovery_test.dart`**:
  - Scenario A: 40% progress preserved on unexpected termination.
  - Scenario B: Chunk 7 `UPLOADING -> PENDING` on restart.
  - Scenario C: `USER_PAUSED` remains `PAUSED`.
  - Scenario D: `INTERRUPTED` becomes `QUEUED` for automatic resumption.
  - Scenario E: `CANCELLED` remains terminal and never resurrects.
  - Scenario F: `COMPLETED` remains immutable.

### Test Execution Result:
```
00:00 +29: All tests passed!
```
- Total Tests: 29
- Passed: 29
- Failed: 0

---

## 9. Dependency Decisions

| Dependency | Scope | Justification |
| :--- | :--- | :--- |
| `sqlite3` (`^2.4.6`) | Runtime | Canonical Dart FFI bindings for SQLite. Provides native WAL mode, immediate transactions, and in-memory test databases without heavy code generation. |
| `meta` (`^1.11.0`) | Runtime | Standard Dart annotations (`@immutable`). |
| `test` (`^1.25.0`) | Dev | Standard Dart testing framework. |
| `lints` (`^3.0.0`) | Dev | Standard Dart linting rules for static analysis. |

*Note: Heavy code-generators (e.g. `build_runner`) were excluded to maintain minimal dependencies and clean architecture.*

---

## 10. Files Created

```
analysis_options.yaml
pubspec.yaml
lib/
  resumable_transfer_engine.dart
  src/
    domain/
      models/
        enums.dart
        chunk.dart
        transfer.dart
        transfer_event.dart
      chunking/
        chunk_calculator.dart
      state_machine/
        exceptions.dart
        transfer_state_machine.dart
        chunk_state_machine.dart
      repositories/
        transfer_repository.dart
        chunk_repository.dart
        transfer_event_repository.dart
      recovery/
        cold_start_recovery_service.dart
    infrastructure/
      persistence/
        sqlite/
          sqlite_transfer_database.dart
          sqlite_transfer_repository.dart
test/
  domain/
    state_machine_test.dart
    chunk_calculator_test.dart
  persistence/
    sqlite_persistence_test.dart
    transactional_consistency_test.dart
  recovery/
    cold_start_recovery_test.dart
docs/
  PHASE_1.md
```
