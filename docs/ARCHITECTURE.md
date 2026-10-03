# Resumable Transfer Engine — Architecture & System Design

**Project:** Resumable Transfer Engine  
**Event:** GDG SRM App Development Submission  
**Document Status:** Approved Architecture Blueprint (Phase 0.6 Hardened)  
**Target Environment:** Flutter / Dart (Mobile Engine) + Python FastAPI / Node.js (Mock Server)

---

## 1. System Overview

The **Resumable Transfer Engine** is an industrial-grade, fault-tolerant file transfer framework engineered to guarantee data delivery across erratic network conditions, unexpected process termination, mobile operating system memory pressure, and server-side transient failures.

Traditional mobile upload/download solutions rely on ephemeral in-memory state or simple boolean flags (`isUploading`, `isPaused`), rendering them fragile against application restarts, network timeouts, and lost server responses. This engine establishes:
- **Persistence as the Source of Truth:** All transfer metadata, chunk statuses, and audit events are durably persisted in SQLite before execution.
- **Upload/Download Symmetry:** Uploads and downloads share identical resilience guarantees, chunk-level persistence, partial progress tracking, and cryptographic integrity validation.
- **Hierarchical Deterministic State Machines:** Explicit state machines for transfers and individual byte chunks with strict invariant enforcement.
- **Deterministic Disruption Semantics:** Strictly distinguishes deliberate user pause from unexpected crash interruptions:
  $$\mathbf{USER\_PAUSED} \neq \mathbf{INTERRUPTED} \neq \mathbf{CANCELLED}$$
  - A transfer paused by the user (`USER_PAUSED`) remains `PAUSED` on restart and requires explicit user Resume.
  - A transfer unexpectedly interrupted by process termination is automatically reconciled on cold start into `QUEUED` and resumes work automatically into `TRANSFERRING`.
  - A `CANCELLED` transfer is permanently terminal and never resurrects.
- **True Chunk-Level Resumability:** Large files are deterministically partitioned into byte segments. If transfer stops at 40%, only the remaining 60% of byte chunks are transmitted upon resumption. **Downloads and uploads never restart from zero.**
- **Loss-Tolerant Idempotent Protocol:** Composite idempotency keys prevent duplicate writes or data corruption when server responses are lost in transit.
- **Streaming Cryptographic Verification:** End-to-end SHA-256 verification of individual chunks and assembled files with zero memory-ballooning.
- **Deterministic Fault Injection:** Built-in network cut, dropped response, and timeout simulation mechanisms for automated verification.

---

## 2. Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────┐
│                        PRESENTATION LAYER                              │
│   ┌───────────────────────────┐      ┌──────────────────────────────┐  │
│   │   Transfer Dashboard UI   │      │  Fault Injection Control UI  │  │
│   └─────────────┬─────────────┘      └──────────────┬───────────────┘  │
└─────────────────┼───────────────────────────────────┼──────────────────┘
                  │ Observes Streams / Dispatches Commands
                  ▼                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│                         APPLICATION LAYER                              │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                     TransferEngine (Facade)                      │  │
│  └─────────────────┬───────────────────────────────┬────────────────┘  │
│                    ▼                               ▼                   │
│  ┌──────────────────────────────────┐ ┌─────────────────────────────┐  │
│  │   TransferQueueManager (FIFO)    │ │   FaultSimulatorRegistry    │  │
│  │  - MAX_CONCURRENT_TRANSFERS = 2  │ └──────────────┬──────────────┘  │
│  └─────────────────┬────────────────┘                │                 │
│                    ▼                                 │                 │
│  ┌──────────────────────────────────┐                │                 │
│  │      TransferCoordinator         │◄───────────────┘                 │
│  │   - Governs Single Transfer      │                                  │
│  │   - MAX_IN_FLIGHT_CHUNKS = 1     │                                  │
│  └─────────────────┬────────────────┘                                  │
└────────────────────┼───────────────────────────────────────────────────┘
                     │ Orchestrates
                     ▼
┌────────────────────────────────────────────────────────────────────────┐
│                    DOMAIN & STATE MACHINE LAYER                        │
│  ┌─────────────────────────────────┐  ┌─────────────────────────────┐  │
│  │    TransferStateMachine         │  │      ChunkStateMachine      │  │
│  │  (QUEUED -> TRANSFERRING ...)   │  │  (PENDING -> COMPLETED ...) │  │
│  └────────────────┬────────────────┘  └──────────────┬──────────────┘  │
│                   │                                  │                 │
│                   ▼                                  ▼                 │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │              RetryPolicy (Exponential Backoff + Jitter)          │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────┬───────────────────────────────────────────────────┘
                     │ Reads / Persists State
                     ▼
┌────────────────────────────────────────────────────────────────────────┐
│                   INFRASTRUCTURE & PERSISTENCE                         │
│  ┌───────────────────────────────┐   ┌──────────────────────────────┐  │
│  │      TransferRepository       │   │   FileChunker & Assembler    │  │
│  │  - SQLite (WAL Mode, Drift)   │   │  - RandomAccessFile Slicing  │  │
│  │  - Transfers, Chunks, Events  │   │  - Streaming SHA-256 Engine  │  │
│  └───────────────────────────────┘   └──────────────┬───────────────┘  │
│                                                     │                  │
│  ┌──────────────────────────────────────────────────┴───────────────┐  │
│  │         NetworkClient (Dio + Fault Injection Interceptor)        │  │
│  └──────────────────────────────────┬───────────────────────────────┘  │
└─────────────────────────────────────┼──────────────────────────────────┘
                                      │ HTTP / REST Wire Protocol
                                      ▼
┌────────────────────────────────────────────────────────────────────────┐
│                     MOCK TRANSFER SERVER (FastAPI)                     │
│  ┌───────────────────────┐ ┌──────────────────────┐ ┌───────────────┐  │
│  │ Idempotency Evaluator │ │  Chunk Temp Storage  │ │ Fault Engine  │  │
│  └───────────────────────┘ └──────────────────────┘ └───────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Upload & Download Symmetry

Uploads and downloads are treated as first-class, symmetrical operations within a unified architecture. Both directions share identical persistence schemas, state machines, chunk tracking, retry policies, and integrity checks.

### Symmetrical Operations Matrix

| Capability | Upload Lifecycle | Download Lifecycle |
| :--- | :--- | :--- |
| **Manifest Initialization** | Client hashes local file, creates `TransferRecord`, registers manifest via `POST /api/v1/transfers`. | Client receives remote asset metadata via `POST /api/v1/transfers`, persists expected file size, chunk count, and SHA-256 in SQLite. |
| **Chunk-Level Persistence** | Slices file into $N$ chunk records (`PENDING`). | Pre-allocates $N$ chunk records (`PENDING`) in SQLite corresponding to byte ranges. |
| **Network Transfer** | Reads slice from disk via `RandomAccessFile`, streams chunk via `PUT /transfers/{id}/chunks/{index}`. | Downloads chunk byte stream via `GET /transfers/{id}/chunks/{index}` or HTTP `Range` request. |
| **Chunk Verification** | Client calculates chunk SHA-256 before transmission; server verifies before committing. | Client calculates SHA-256 on incoming chunk stream; verifies against server header before committing to disk and SQLite. |
| **Progress Accounting** | On HTTP 200/201, marks chunk `COMPLETED` and increments `bytes_transferred`. | On verified chunk write, marks chunk `COMPLETED` and increments `bytes_transferred`. |
| **Process Interruption** | Process killed at 40%: completed chunks remain `COMPLETED`. On reboot, client skips completed chunks. | Process killed at 40%: completed chunks remain on disk and marked `COMPLETED` in SQLite. **Client resumes from chunk index 20, never restarting from zero.** |
| **Integrity Verification** | All chunks sent $\to$ Client calls `POST /finalize`. Server reassembles file and audits SHA-256 against manifest. | All chunks downloaded $\to$ Client streams local assembled file, computes SHA-256, and validates against manifest. |

---

## 4. In-Flight Chunk Recovery & Lost Response Guarantee

### 4.1 Why In-Flight (`UPLOADING`) Chunks Safely Reset to `PENDING`
When an application process dies unexpectedly while a chunk is marked `UPLOADING`, the client cannot know whether the byte payload reached the server or was lost in transit.

Resetting an in-flight chunk to `PENDING` upon application restart is guaranteed to be safe, lossless, and non-duplicative due to our **Idempotent Protocol**:

```
Step  Actor     Action / State Transition
────────────────────────────────────────────────────────────────────────────────
 1.   Client    Picks Chunk 7 (State: PENDING -> UPLOADING).
 2.   Client    Transmits PUT /chunks/7 with Idempotency-Key: "uuid:7:hashA".
 3.   Server    Receives chunk 7, validates hashA, writes bytes to disk.
 4.   Server    Commits record to chunk ledger: (transferId, 7, COMPLETED, hashA).
 5.   Server    Generates HTTP 201 Created response.
 6.   Network   TCP RST / Drop: HTTP 201 response is LOST on the wire.
 7.   OS        Mobile OS kills client process (crash, OOM, power loss).
                * Client SQLite retains Chunk 7 = 'UPLOADING'.
 8.   Reboot    Application restarts. Cold-Start Recovery runs:
                * Interrupted Chunk 7 is safely reset: UPLOADING -> PENDING.
                * Parent transfer is reconciled: dirty TRANSFERRING -> QUEUED.
 9.   Client    Transfer resumes automatically. Worker picks Chunk 7.
10.   Client    Retries PUT /chunks/7 with identical Idempotency-Key: "uuid:7:hashA".
11.   Server    Inspects chunk ledger: Chunk 7 is ALREADY marked COMPLETED.
12.   Server    Verifies stored hash matches incoming hash: hashA == hashA (MATCH).
13.   Server    NO REDUNDANT DISK WRITE PERFORMED.
14.   Server    Returns HTTP 200 OK (X-Idempotent-Replay: true).
15.   Client    Receives 200 OK. Marks Chunk 7 = COMPLETED in local SQLite.
────────────────────────────────────────────────────────────────────────────────
```

If the server never received chunk 7 before the crash, the retried request is processed normally as a new arrival (`201 Created`). Data corruption and duplicate file writes are mathematically impossible.

---

## 5. Lifecycle Disruption Taxonomy: USER_PAUSED ≠ INTERRUPTED ≠ CANCELLED

To eliminate ambiguity, the engine strictly differentiates three disruption types:

$$\mathbf{USER\_PAUSED} \neq \mathbf{INTERRUPTED} \neq \mathbf{CANCELLED}$$

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                  LIFECYCLE DISRUPTION TAXONOMY & RECOVERY MATRIX                       │
├────────────────────────────┬─────────────────────────────┬─────────────────────────────┤
│   USER PAUSE (USER_PAUSED) │ INTERRUPTED (UNEXPECTED)    │    CANCELLED (USER_CANCEL)  │
├────────────────────────────┼─────────────────────────────┼─────────────────────────────┤
│ • Explicit user action     │ • Process killed by OS/OOM/ │ • Explicit user action      │
│   (User taps "Pause")      │   crash/battery/power loss  │   (User taps "Cancel")      │
│ • State: PAUSED            │ • State left dirty in DB    │ • State: CANCELLED          │
│   (reason = USER_PAUSED)   │   (TRANSFERRING/RETRYING)   │   (Terminal state)          │
│ • In-flight chunks cleanly │ • In-flight chunks dirty    │ • In-flight chunks aborted  │
│   reset to PENDING         │   (remain 'UPLOADING')      │ • Chunks & temp files purged│
│ • ON RESTART: REMAINS      │ • ON RESTART: AUTOMATICALLY │ • ON RESTART: REMAINS       │
│   PAUSED. Requires         │   RESUMES! Reconciled into  │   CANCELLED. Never          │
│   explicit user Resume.    │   QUEUED -> TRANSFERRING.   │   resurrects or resumes.    │
│ • Never auto-resumes       │ • Seamless continuation:    │ • Permanent terminal state. │
│                            │   40% -> restart -> 40% ->  │                             │
│                            │   continues to 100%.        │                             │
└────────────────────────────┴─────────────────────────────┴─────────────────────────────┘
```

### Detailed Behavioral Rules:
1. **User Pause (`USER_PAUSE`)**:
   - The user deliberately pauses the transfer.
   - Ongoing HTTP requests are cancelled via `CancellationToken`.
   - In-flight chunks are reverted to `PENDING`.
   - State is committed as `PAUSED` with `pause_reason = 'USER_PAUSED'`.
   - **On application restart**: Remains `PAUSED`. It will **never** automatically resume without explicit user interaction (`USER_RESUME`).
2. **Unexpected Process Termination (`INTERRUPTED`)**:
   - The OS terminates the process while a transfer is `TRANSFERRING`, `RETRYING`, or `VERIFYING`.
   - On application startup, the **Formal Recovery Algorithm** detects dirty state:
     - In-flight `UPLOADING` chunks are reset to `PENDING`.
     - Progress is recalculated strictly from `COMPLETED` chunks (e.g. exactly 40%).
     - Transfer is transitioned directly to **`QUEUED`**.
     - `TransferQueueManager` schedules the transfer and promotes it to **`TRANSFERRING`**.
     - **The transfer resumes automatically without requiring the user to press Resume.**
   - This directly fulfills the evaluator requirement:
     $$\text{40\% transferred} \to \text{app terminated} \to \text{app reopened} \to \text{transfer restored at 40\%} \to \text{remaining work resumes.}$$
3. **Cancellation (`USER_CANCEL`)**:
   - The user cancels the transfer.
   - All active chunk requests are aborted immediately.
   - State transitions to `CANCELLED` (Terminal).
   - Partial files, chunk files, and database chunk records are purged.
   - **On application restart**: The recovery algorithm ignores `CANCELLED` records. **A cancelled transfer must never automatically resurrect.**

---

## 6. Concurrency Strategy

Uncontrolled parallelism exhausts cellular radio bandwidth, overwhelms OS socket pools, and introduces thread thrashing.

### 6.1 Explicit Concurrency Separation
The architecture separates transfer-level concurrency from chunk-level concurrency:
- **`MAX_CONCURRENT_TRANSFERS = 2`**: The maximum number of independent transfers running simultaneously. Any additional transfers remain in the `QUEUED` state in FIFO order.
- **`MAX_IN_FLIGHT_CHUNKS_PER_TRANSFER = 1`**: Sequential chunk transmission per transfer. Each active transfer operates exactly one in-flight chunk request at any moment.

```
TransferQueueManager (MAX_CONCURRENT_TRANSFERS = 2)
  │
  ├── Slot 1: Transfer A (UPLOAD) ─── ChunkWorker (MAX_IN_FLIGHT = 1) ─── Chunk 4 [In-Flight]
  │
  ├── Slot 2: Transfer B (DOWNLOAD) ─ ChunkWorker (MAX_IN_FLIGHT = 1) ─── Chunk 12 [In-Flight]
  │
  └── FIFO Queue: [Transfer C (QUEUED), Transfer D (QUEUED)]
```

### 6.2 Configuration & Extensibility
Both values are defined in `TransferConfiguration` and injected into the engine:
```dart
class TransferConfiguration {
  final int maxConcurrentTransfers;       // Default: 2
  final int maxInFlightChunksPerTransfer; // Default: 1
  final int chunkSize;                    // Default: 2 * 1024 * 1024 (2 MB)
  final int maxRetries;                   // Default: 5
  
  const TransferConfiguration({
    this.maxConcurrentTransfers = 2,
    this.maxInFlightChunksPerTransfer = 1,
    this.chunkSize = 2097152,
    this.maxRetries = 5,
  });
}
```

Sequential chunking per transfer guarantees deterministic byte progress, minimal memory overhead, and avoids out-of-order write contention on storage.

---

## 7. Integrity vs. Security Clarification

> [!IMPORTANT]
> **Zero Unnecessary Cryptographic Complexity**: This architecture deliberately rejects custom authentication handshakes, public-key exchanges, asymmetric encryption schemes, or custom session negotiations. Standard transport security (TLS 1.3 / HTTPS) provides transport encryption.

### Scope of Cryptography:
1. **Per-Chunk SHA-256**: Calculated over the raw byte slice to guarantee that cellular or Wi-Fi packet corruption is detected and rejected before chunk commitment.
2. **End-to-End File SHA-256**: Calculated over the complete reconstructed file to guarantee bit-for-bit authenticity against the manifest before marking the transfer `COMPLETED`.
3. **Idempotency Composite Key**: Incorporates chunk SHA-256 (`{transferId}:{chunkIndex}:{chunkSha256}`) to uniquely identify payload content and detect payload collisions.

---

## 8. Formal Application-Start Recovery Algorithm

When `TransferEngine.initialize()` is executed on application boot, the following deterministic algorithm executes before any new transfer requests are accepted:

```
                          [Application Launch]
                                   │
                                   ▼
             [Step 1: Open SQLite DB with PRAGMA journal_mode=WAL]
                                   │
                                   ▼
[Step 2: Query Non-Terminal Transfers]
SELECT * FROM transfers WHERE state IN ('TRANSFERRING', 'RETRYING', 'VERIFYING', 'QUEUED')
                                   │
                 ┌─────────────────┴─────────────────┐
                 │ (No dirty transfers found)        │ (Found dirty transfers)
                 ▼                                   ▼
        [Step 6: Boot Complete]           [BEGIN IMMEDIATE TRANSACTION]
                                                     │
                                                     ▼
                                 [Step 3: Reconcile In-Flight Chunks]
                                 UPDATE chunks SET state = 'PENDING'
                                 WHERE state = 'UPLOADING'
                                                     │
                                                     ▼
                                 [Step 4: Recalculate Verified Progress]
                                 For each transfer:
                                   count = SELECT COUNT(*) FROM chunks 
                                           WHERE transfer_id = ? AND state = 'COMPLETED'
                                   bytes = SELECT SUM(byte_length) FROM chunks 
                                           WHERE transfer_id = ? AND state = 'COMPLETED'
                                   UPDATE transfers SET completed_chunks = count, 
                                                        bytes_transferred = bytes
                                                     │
                                                     ▼
                                 [Step 5: Reconcile Transfer States]
                                 • If state IN ('TRANSFERRING', 'RETRYING', 'VERIFYING'):
                                     UPDATE transfers SET state = 'QUEUED'
                                     (Transfer becomes immediately eligible for
                                      automatic scheduling and resumes into TRANSFERRING)
                                 • If state == 'PAUSED' (USER_PAUSED):
                                     Keep 'PAUSED' (Requires explicit user Resume)
                                 • NEVER touch 'CANCELLED' or 'COMPLETED' transfers
                                                     │
                                                     ▼
                                          [COMMIT TRANSACTION]
                                                     │
                                                     ▼
                                 [Step 6: Enqueue Reconciled Transfers]
                                 QueueManager picks up QUEUED transfers -> TRANSFERRING
                                 (Work automatically continues from exact restored byte %)
```

### 8.1 Detailed Step Walkthrough
1. **Load Persisted State**: Connect to SQLite; retrieve all records from `transfers` and `chunks`.
2. **Reconcile In-Flight Chunks**: Any chunk record marked `UPLOADING` represents a request that was killed by process death. These are atomically updated to `PENDING`.
3. **Preserve Completed Chunks**: All chunks marked `COMPLETED` are preserved without modification. Verified byte counts are recalculated from SQLite:
   $$\text{bytes\_transferred} = \sum_{c \in \text{chunks}, c.\text{state}=\texttt{COMPLETED}} c.\text{byte\_length}$$
4. **Determine Remaining Chunks**: Remaining work is strictly identified by querying:
   `SELECT * FROM chunks WHERE transfer_id = ? AND state = 'PENDING' ORDER BY chunk_index ASC;`
5. **Reconcile Interrupted vs Paused Transfers**:
   - Transfers that were dirty (`TRANSFERRING`, `RETRYING`, `VERIFYING`) were interrupted by process termination. They are set to **`QUEUED`**. The `TransferQueueManager` immediately schedules them, moving them to **`TRANSFERRING`** so they continue execution automatically without user intervention.
   - Transfers marked `PAUSED(reason = USER_PAUSED)` stay in **`PAUSED`**. They require explicit user Resume.
6. **Cancelled Transfers**: Any transfer marked `CANCELLED` remains permanently `CANCELLED`. It is never resurrected.
7. **Completed Transfers**: Any transfer marked `COMPLETED` is immutable.

---

## 9. Client vs. Server Chunk State Drift Matrix

During startup or network reconnection, client and server states are reconciled:

| Client State | Server State | Resolution Action | Rationale |
| :--- | :--- | :--- | :--- |
| **`PENDING`** | **`COMPLETED`** | **Advance Client to `COMPLETED`** | Server already holds the verified chunk (due to a previous dropped response). Upon reconciliation query (`GET /transfers/{id}`) or retry `PUT` (which returns `200 OK Idempotent Replay`), client immediately marks chunk `COMPLETED` and credits byte progress without resending data. |
| **`COMPLETED`** | **`MISSING`** | **Demote Client to `PENDING`** | Server suffered storage loss or session eviction. If server reports chunk missing on `GET /transfers/{id}` or rejects `POST /finalize`, client sets local chunk back to `PENDING`, decrements progress, and retransmits the chunk. |
| **`COMPLETED`** | **`COMPLETED`** | **No-op (Synchronized)** | Both sides agree; chunk is satisfied. |
| **`PENDING`** | **`MISSING`** | **Normal Transfer** | Chunk has not been transferred yet; will be scheduled normally. |

---

## 10. Database Schema (SQLite / Drift)

Persistence is the single source of truth. The database uses Write-Ahead Logging (`PRAGMA journal_mode=WAL;`) and foreign keys (`PRAGMA foreign_keys=ON;`).

```sql
-- Transfers Table: Master record for every upload/download task
CREATE TABLE transfers (
    transfer_id TEXT PRIMARY KEY NOT NULL,
    file_name TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    direction TEXT NOT NULL CHECK(direction IN ('UPLOAD', 'DOWNLOAD')),
    state TEXT NOT NULL CHECK(state IN (
        'QUEUED', 'TRANSFERRING', 'RETRYING', 'PAUSED',
        'VERIFYING', 'COMPLETED', 'FAILED', 'CANCELLED'
    )),
    pause_reason TEXT CHECK(pause_reason IN ('USER_PAUSED', NULL)),
    chunk_size INTEGER NOT NULL,
    total_chunks INTEGER NOT NULL,
    completed_chunks INTEGER NOT NULL DEFAULT 0,
    bytes_transferred INTEGER NOT NULL DEFAULT 0,
    file_sha256 TEXT NOT NULL,
    retry_count INTEGER NOT NULL DEFAULT 0,
    max_retries INTEGER NOT NULL DEFAULT 5,
    error_message TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

-- Chunks Table: Segment-level tracking for partial resumability
CREATE TABLE chunks (
    transfer_id TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,
    byte_offset INTEGER NOT NULL,
    byte_length INTEGER NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('PENDING', 'UPLOADING', 'COMPLETED', 'FAILED')),
    sha256 TEXT NOT NULL,
    retry_count INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (transfer_id, chunk_index),
    FOREIGN KEY (transfer_id) REFERENCES transfers(transfer_id) ON DELETE CASCADE
);

-- Transfer Events Table: Immutable audit log of all state transitions
CREATE TABLE transfer_events (
    event_id INTEGER PRIMARY KEY AUTOINCREMENT,
    transfer_id TEXT NOT NULL,
    from_state TEXT NOT NULL,
    to_state TEXT NOT NULL,
    reason TEXT,
    timestamp INTEGER NOT NULL,
    FOREIGN KEY (transfer_id) REFERENCES transfers(transfer_id) ON DELETE CASCADE
);

-- Indexes for high-throughput lookup
CREATE INDEX idx_transfers_state ON transfers(state);
CREATE INDEX idx_chunks_lookup ON chunks(transfer_id, state);
CREATE INDEX idx_events_transfer ON transfer_events(transfer_id);
```

---

## 11. Retry Strategy (Exponential Backoff with Full Jitter)

### Error Classification

| Error Category | Specific Failures | Retryable? | Behavior |
| :--- | :--- | :--- | :--- |
| **Transient Network** | `SocketException`, Connection timeout, Handshake timeout | **YES** | Increment retry counter, enter `RETRYING`, schedule backoff. |
| **Transient Server** | HTTP 500, 502, 503, 504, 429 Too Many Requests | **YES** | Respect `Retry-After` header if present; else exponential backoff. |
| **Non-Retryable Client** | HTTP 400 Bad Request, 401 Unauthorized, 403 Forbidden, 404 Not Found | **NO** | Transition directly to `FAILED`. Never retry. |
| **Integrity Conflict** | HTTP 409 Conflict, 422 Checksum Mismatch | **NO** | Transition to `FAILED`. Corrupt session requires new transfer. |
| **Explicit Cancellation**| User pressed Cancel | **NO** | Transition to `CANCELLED`. Purge temporary artifacts. |

### Backoff Formula:
$$t_{\text{wait}} = \min\left(t_{\text{max}}, t_{\text{base}} \times 2^{\text{attempt}}\right) \times \text{Uniform}(0.8, 1.2)$$
- $t_{\text{base}} = 1.0\text{s}$, $t_{\text{max}} = 30.0\text{s}$, $\text{max\_retries} = 5$.

---

## 12. Lifecycle Strategy & Mobile OS Realities

### 12.1 UI vs Engine Lifecycle
The `TransferEngine` runs as a headless singleton service. UI components observe reactive streams. When UI screens are unmounted, transfers continue uninterrupted.

### 12.2 Platform Execution Realities
- **Android**: To protect transfers when backgrounded, run an Android **Foreground Service** with a non-dismissible notification (`FOREGROUND_SERVICE_DATA_SYNC`). If the OS kills the process under extreme memory pressure, the **Formal Recovery Algorithm** seamlessly restores state at startup and resumes without user intervention.
- **iOS**: Background tasks have a ~30-second execution window. The engine uses `beginBackgroundTask` to complete in-flight chunks before suspension. On resume, transfer continues from the exact last chunk.

---

## 13. Fault Injection Strategy

The engine and mock server include deterministic fault injection to verify resilience during development and evaluation:

```
[UI / Test Trigger] ──► Sets X-Fault-Inject Header ──► Interceptor / Server simulates fault
```

### Supported Directives:
1. `type=network-cut;targetChunk=N`: Abruptly terminates TCP socket before responding.
2. `type=timeout;targetChunk=N;delayMs=15000`: Holds response past client timeout limit.
3. `type=status-500;targetChunk=N;attempts=2`: Fails with HTTP 500 twice, then succeeds.
4. `type=drop-response;targetChunk=N`: Commits chunk to server storage, then terminates connection with 0 bytes sent (Idempotency litmus test).
5. `type=corrupt-data;targetChunk=N`: Inverts payload byte to test SHA-256 rejection.

---

## 14. Testing Strategy Matrix

| Scope | Scenario | Verification Criteria |
| :--- | :--- | :--- |
| **Unit** | State Machine Transitions | Legal transitions succeed; illegal transitions throw `IllegalStateTransitionException`. |
| **Unit** | Slicing & Offset Math | Segment offsets and byte counts are exact, including the final uneven chunk. |
| **Unit** | Exponential Backoff | Delays adhere strictly to exponential bounds and jitter ranges; caps at 30s. |
| **Integration**| Process Crash & Restart | Transfer killed at 40% $\to$ app rebooted $\to$ restored at 40% $\to$ automatically resumes into `TRANSFERRING` and transmits remaining 60%. |
| **Integration**| Lost Response Recovery | Chunk 7 committed by server $\to$ response dropped $\to$ retry yields `200 OK` without duplicate disk write. |
| **Integration**| Concurrency Throttle | 4 transfers enqueued $\to$ exactly 2 run concurrently; remaining 2 wait in `QUEUED`. |
| **Integration**| Integrity Mismatch | Injected corrupt byte triggers rejection $\to$ chunk retried $\to$ final SHA-256 matches. |
| **Integration**| Cancellation Permanence| Cancelled transfer is never resumed by startup reconciliation or user resume calls. |

---

## 15. Dependency Decisions

| Dependency | Purpose | Evaluation & Decision |
| :--- | :--- | :--- |
| `sqlite3` / `drift` | Persistence | ACID transactions, WAL mode, relational integrity for chunk tracking. **Adopted**. |
| `dio` | Networking | Native chunk streaming, cancellation tokens, clean interceptor pipeline. **Adopted**. |
| `flutter_riverpod` | State Management | Decoupled dependency injection, reactive streams, testable without UI widgets. **Adopted**. |
| `crypto` | Integrity | Standard Dart SHA-256 streaming hashing. Zero native overhead. **Adopted**. |
| `path_provider` | Storage | Platform-independent app document directory resolution. **Adopted**. |
| `flutter_foreground_task` | Android Background | Manages Foreground Service lifecycle with persistent progress notification. **Adopted**. |
| *Workmanager* | Background | Unsuitable: 15-minute periodicity and OS throttling prevent active streaming. **Rejected**. |
| *BloC / GetX* | State Management | Heavyweight boilerplate and context dependency. **Rejected**. |

---

## 16. Development Phases

```
Phase 0.6: Final Recovery Semantics Hardened (CURRENT)
   │  - USER_PAUSED ≠ INTERRUPTED ≠ CANCELLED formalized.
   │
Phase 1: Persistence Layer & State Machine
   │  - SQLite / Drift schema, TransferStateMachine, ChunkStateMachine, unit tests.
   │
Phase 2: Local Mock Server & Wire Protocol
   │  - FastAPI / Node.js mock server with idempotent chunk ledger & fault injection.
   │
Phase 3: Core Transfer Engine & Network Client
   │  - Chunked upload/download with Dio, RandomAccessFile streaming, crash recovery.
   │
Phase 4: Fault Injection & Resilience Testing
   │  - Automated tests for network drop, dropped response, process restart at 40%.
   │
Phase 5: Mobile UI & Demonstration Harness
      - Flutter transfer dashboard, live progress telemetry, fault injection controls.
```
