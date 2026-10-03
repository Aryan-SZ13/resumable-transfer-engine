# Phase 1.6 — Corrective Hardening Report

**Baseline Audit:** `docs/PHASE_1_AUDIT.md`  
**Date:** October 3, 2026  
**Status:** Complete — All Audit Findings Hardened & Verified  
**Test Suite:** 53 Tests Passing (0 Failures, 0 Analyzer Issues)

---

## 1. Executive Summary

Phase 1.6 implemented targeted correctness, invariant enforcement, and persistence hardening based on the Phase 1.5 engineering audit. No networking, mock servers, HTTP clients, UI, or background worker threads were introduced. The domain boundaries, upload/download symmetry, state machine semantics, and data models remain cleanly isolated.

All 12 actionable findings (High, Medium, and Low severity) have been completely resolved and backed by comprehensive regression tests.

---

## 2. Hardening Details

### 2.1 State Machine Invariants (S-1, S-2, S-3)
1. **Completion Invariant (`S-1`)**: In `TransferStateMachine.transition`, transitioning on `TransferEventTrigger.allChunksCompleted` to `TransferState.verifying` now strictly asserts that `current.completedChunks == current.totalChunks`. Any attempt to transition prematurely throws `InvariantViolationException`.
2. **User Resume Guard (`S-2`)**: The `userResume` transition trigger now checks `current.pauseReason == PauseReason.userPaused`. Resuming an unexpectedly interrupted transfer without explicit user pause context is disallowed via `IllegalStateTransitionException`.
3. **Chunk Transition Simplification (`S-3`)**: Removed redundant unreachable `StateError` branch in `ChunkStateMachine.transition`.

### 2.2 Database Constraints & Pragmas (P-1, P-2, CR-1)
1. **Numeric Integrity (`P-1`)**: Added SQLite DDL `CHECK` constraints across all tables:
   - `transfers`: `CHECK(file_size >= 0)`, `CHECK(chunk_size > 0)`, `CHECK(total_chunks >= 0)`, `CHECK(completed_chunks >= 0 AND completed_chunks <= total_chunks)`, `CHECK(bytes_transferred >= 0 AND bytes_transferred <= file_size)`, `CHECK(retry_count >= 0)`, `CHECK(max_retries >= 0)`.
   - `chunks`: `CHECK(chunk_index >= 0)`, `CHECK(byte_offset >= 0)`, `CHECK(byte_length >= 0)`, `CHECK(retry_count >= 0)`.
2. **Event Enum Constraint (`P-2`)**: Added `CHECK(from_state IN (...))` and `CHECK(to_state IN (...))` to the `transfer_events` table. Added `toDbString()` mapping to ensure string serialization consistency with SQLite enums.
3. **Database Pragmas (`CR-1`)**: Initialized SQLite database with:
   - `PRAGMA busy_timeout = 5000;` (prevents instant failure under lock contention)
   - `PRAGMA synchronous = NORMAL;` (optimal WAL-mode durability without excessive fsync overhead)
   - `PRAGMA foreign_keys = ON;` (cascading deletes and relational integrity)
   - `PRAGMA journal_mode = WAL;` (concurrent reader/writer performance)

### 2.3 Transactional Consistency & Concurrency (T-1, R-1, CR-2)
1. **Row Count Verification (`T-1`)**: In `completeChunkAtomically`, the statement `UPDATE chunks SET state = 'COMPLETED'` verifies `_db.updatedRows == 1`. If the target `chunkIndex` does not exist, it throws `StateError` and automatically triggers a transaction rollback, leaving database state unmodified.
2. **Atomic Cold-Start Recovery (`R-1`)**: Introduced `TransactionRunner` interface in `lib/src/domain/repositories/transaction_runner.dart`. `SqliteTransferEngineRepository` implements `TransactionRunner`. `ColdStartRecoveryService` accepts an optional `TransactionRunner` and executes recovery sweeps inside a single atomic transaction.
3. **Re-entrant AsyncLock Serialization (`CR-2`)**: Implemented `_AsyncLock` with Zone-based re-entrancy in `SqliteTransferEngineRepository`. All repository write and transaction operations are serialized FIFO, preventing nested transaction collisions or SQLite connection lock exhaustion during concurrent asynchronous requests.

### 2.4 Cold-Start Edge Cases (R-2)
- In `ColdStartRecoveryService`, transfers in `QUEUED` and `PAUSED` states are now scanned for stale in-flight `UPLOADING` chunks (e.g. left behind by unexpected crashes during queue transitions). Stale chunks are reset to `PENDING` while preserving the transfer's status and progress.

### 2.5 Domain Invariants & Bounds (D-1, D-2, C-1, C-2)
1. **Runtime Constructor Validation (`D-1`)**: Replaced debug-only `assert(...)` statements in `Transfer` and `Chunk` constructors with runtime `ArgumentError` validation that remains active in release builds.
2. **Chunk Idempotency Key Guard (`D-2`)**: `Chunk.idempotencyKey` explicitly checks that `sha256` is non-empty, throwing a `StateError` if accessed before chunk hashing is completed.
3. **EOF Bounds Guard (`C-1`)**: Refactored `ChunkCalculator.getChunkIndexForByte` to accept named parameters (`bytePosition`, `fileSize`, `chunkSize`). It strictly enforces `0 <= bytePosition < fileSize`, throwing `RangeError` at or beyond EOF (`bytePosition >= fileSize`) or on zero-byte files.
4. **Platform Arithmetic (`C-2`)**: Confirmed 64-bit integer safety on native Dart VM (iOS/Android).

---

## 3. Test Suite Verification

- **Total Test Cases:** 53
- **Passing:** 53 (100%)
- **Failing / Flaky:** 0
- **Static Analysis:** 0 issues found (`dart analyze`)
- **Formatting:** 100% compliant (`dart format`)

### Test Coverage Highlights
- `test/domain/state_machine_test.dart`: Invariant checks for `allChunksCompleted`, `userResume`, valid lifecycle paths, terminal state violations.
- `test/domain/chunk_calculator_test.dart`: Exact/uneven slicing, small/zero-byte files, EOF/out-of-bounds `RangeError` validations.
- `test/domain/model_validation_test.dart`: Runtime validation of negative bounds, overflow bounds, and idempotency key access guards.
- `test/persistence/sqlite_persistence_test.dart`: CRUD, cascade deletion, audit trails, PRAGMA configuration, SQLite numeric CHECK constraints, and event enum constraints.
- `test/persistence/transactional_consistency_test.dart`: Atomic chunk completion, non-existent chunk rollback, concurrent operation serialization without database lock errors.
- `test/recovery/cold_start_recovery_test.dart`: Recovery scenarios A–F (40% restoration, in-flight resets, USER_PAUSED preservation, cancellation immutability, transactional execution, and double-recovery idempotency).
