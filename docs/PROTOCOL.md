# Transfer Protocol & Idempotency Specification

## 1. Overview & Architectural Scope

This document specifies the wire protocol between the mobile client engine and the transfer server. It establishes:
1. Symmetric chunked transfer protocols for both **Upload** and **Download**.
2. Loss-tolerant idempotency guarantees that prevent duplicate processing or data corruption when responses are lost.
3. Explicit resolution matrix for client/server state drift.
4. Strict recovery semantics distinguishing user pause, unexpected process termination, and cancellation:
   $$\mathbf{USER\_PAUSED} \neq \mathbf{INTERRUPTED} \neq \mathbf{CANCELLED}$$
5. Cryptographic integrity checking (SHA-256) strictly for data corruption detection and idempotency key derivation (not security handshakes or session encryption).
6. Programmable fault injection headers for testing and evaluation.

---

## 2. Integrity vs. Security Clarification

> [!NOTE]
> **No Custom Security Handshakes:** This protocol deliberately avoids custom public-key cryptography, session token negotiations, or custom authentication schemes. Standard transport security (HTTPS / TLS 1.3) handles transport layer encryption.
> 
> **Cryptographic Usage is Strictly Scoped To:**
> 1. **Per-Chunk Integrity**: SHA-256 hashes generated over individual byte segments to detect bit flips and network corruption.
> 2. **Final File Integrity**: SHA-256 hash computed over the reconstructed/downloaded file to verify bit-for-bit authenticity against the manifest.
> 3. **Idempotency Identity**: SHA-256 digest embedded inside the `Idempotency-Key` to detect and reject conflicting payloads submitted under identical chunk indices.

---

## 3. Concurrency Limits on the Wire

To guarantee predictable memory and socket usage on mobile operating systems:
- **`MAX_CONCURRENT_TRANSFERS = 2`**: At most two independent transfer sessions may actively utilize network connections simultaneously.
- **`MAX_IN_FLIGHT_CHUNKS_PER_TRANSFER = 1`**: Chunks are transferred sequentially per transfer. Only one HTTP request carrying chunk payload is active per transfer at any moment.

Both parameters are architectural constants configured in `TransferConfiguration` and can be adjusted without changing protocol contracts.

---

## 4. API Endpoints

### 4.1 Summary Matrix

| Method | Endpoint | Direction | Purpose |
| :--- | :--- | :--- | :--- |
| `POST` | `/api/v1/transfers` | Upload / Download | Initialize transfer session & register manifest |
| `GET` | `/api/v1/transfers/{id}` | Both | Query transfer status, progress & server chunk bitmask |
| `PUT` | `/api/v1/transfers/{id}/chunks/{index}` | Upload | Transmit a single binary chunk |
| `GET` | `/api/v1/transfers/{id}/chunks/{index}` | Download | Retrieve a single binary chunk (supports `Content-Range`) |
| `GET` | `/api/v1/transfers/{id}/chunks` | Both | List statuses of all chunks on server |
| `POST` | `/api/v1/transfers/{id}/finalize` | Upload | Trigger server reassembly & cryptographic SHA-256 audit |
| `GET` | `/api/v1/transfers/{id}/download` | Download | Stream entire file with standard HTTP `Range` support |
| `DELETE` | `/api/v1/transfers/{id}` | Both | Explicit user cancellation; purges partial chunks and temp files |

---

### 4.2 Endpoint Specifications

#### 1. Initialize Transfer Session: `POST /api/v1/transfers`

**Upload Initialization (Client $\to$ Server):**
Client registers file manifest with expected hash and segment parameters.
```json
{
  "transferId": "550e8400-e29b-41d4-a716-446655440000",
  "direction": "UPLOAD",
  "fileName": "dataset_v1.tar.gz",
  "fileSize": 104857600,
  "chunkSize": 2097152,
  "totalChunks": 50,
  "fileSha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
```
**Response (201 Created):**
```json
{
  "transferId": "550e8400-e29b-41d4-a716-446655440000",
  "direction": "UPLOAD",
  "status": "QUEUED",
  "chunkSize": 2097152,
  "totalChunks": 50,
  "completedChunks": [],
  "createdAt": "2026-10-03T10:30:00Z"
}
```

**Download Initialization (Client $\to$ Server):**
Client requests transfer session for an existing server asset.
```json
{
  "transferId": "550e8400-e29b-41d4-a716-446655440001",
  "direction": "DOWNLOAD",
  "remoteFileId": "remote-asset-998"
}
```
**Response (200 OK):**
Server returns file manifest. Client persists this manifest in local SQLite before downloading any chunks.
```json
{
  "transferId": "550e8400-e29b-41d4-a716-446655440001",
  "direction": "DOWNLOAD",
  "fileName": "package_release.zip",
  "fileSize": 41943040,
  "chunkSize": 2097152,
  "totalChunks": 20,
  "fileSha256": "8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4",
  "status": "TRANSFERRING"
}
```

---

#### 2. Upload Chunk: `PUT /api/v1/transfers/{id}/chunks/{index}`

Transmits a single byte segment.

**Request Headers:**
- `Content-Type`: `application/octet-stream`
- `Content-Length`: `<chunk_byte_count>`
- `Content-Range`: `bytes <start>-<end>/<total>` (e.g. `bytes 0-2097151/104857600`)
- `X-Chunk-Index`: `0`
- `X-Chunk-SHA256`: `<sha256_of_chunk_payload>`
- `Idempotency-Key`: `${transferId}:${chunkIndex}:${chunkSha256}`
- *(Optional Fault Injection)*: `X-Fault-Inject: <directive>`

**Request Body:** Raw binary chunk bytes.

**Responses:**
- `201 Created`: Chunk successfully received, validated, and stored.
  ```json
  {
    "transferId": "550e8400-e29b-41d4-a716-446655440000",
    "chunkIndex": 0,
    "status": "COMPLETED",
    "receivedSha256": "d28b1390...",
    "isIdempotentReplay": false
  }
  ```
- `200 OK`: Duplicate chunk detected and already validated (Idempotent replay).
  ```json
  {
    "transferId": "550e8400-e29b-41d4-a716-446655440000",
    "chunkIndex": 0,
    "status": "COMPLETED",
    "receivedSha256": "d28b1390...",
    "isIdempotentReplay": true
  }
  ```
- `409 Conflict`: Chunk index exists on server but stored payload has a differing SHA-256 hash.
- `400 Bad Request`: Payload length mismatch or corrupted payload hash in transit.

---

#### 3. Download Chunk: `GET /api/v1/transfers/{id}/chunks/{index}`

Retrieves an isolated byte segment for download.

**Request Headers:**
- `Accept`: `application/octet-stream`
- *(Optional)* `Range`: `bytes=<start>-<end>`

**Response Headers (200 OK or 206 Partial Content):**
- `Content-Type`: `application/octet-stream`
- `Content-Range`: `bytes 0-2097151/41943040`
- `Content-Length`: `2097152`
- `X-Chunk-Index`: `0`
- `X-Chunk-SHA256`: `84d7a...`

**Response Body:** Raw binary chunk bytes.

**Download Resilience Handling:**
1. Client streams response directly into target file at `byte_offset` via `RandomAccessFile`.
2. Client computes SHA-256 during streaming.
3. If calculated SHA-256 matches `X-Chunk-SHA256`: client commits chunk as `COMPLETED` in SQLite.
4. If calculated SHA-256 mismatches: client discards chunk buffer, marks chunk `FAILED`, and retries.
5. If process dies during download of chunk 7: chunks 0..6 remain `COMPLETED` in SQLite and on disk. Upon restart, client reconciles transfer to `QUEUED` and resumes automatically from chunk 7. **Download never restarts from zero.**

---

#### 4. Query Server Status: `GET /api/v1/transfers/{id}`

Used during startup reconciliation, connection recovery, and pre-finalization checks.

**Response (200 OK):**
```json
{
  "transferId": "550e8400-e29b-41d4-a716-446655440000",
  "direction": "UPLOAD",
  "status": "TRANSFERRING",
  "totalChunks": 50,
  "completedChunksCount": 24,
  "completedChunkIndices": [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, ...],
  "bytesTransferred": 50331648,
  "totalBytes": 104857600
}
```

---

#### 5. Finalize Transfer: `POST /api/v1/transfers/{id}/finalize`

Triggered exclusively when all $N$ chunks are locally marked `COMPLETED`.

**Response (200 OK):**
```json
{
  "transferId": "550e8400-e29b-41d4-a716-446655440000",
  "status": "COMPLETED",
  "fileSha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "verified": true,
  "finalizedAt": "2026-10-03T10:35:12Z"
}
```

**Response (422 Unprocessable Entity - Hash Mismatch):**
```json
{
  "error": "INTEGRITY_VERIFICATION_FAILED",
  "expectedSha256": "e3b0c442...",
  "actualSha256": "9f83c12a...",
  "message": "Reassembled file checksum did not match initial manifest"
}
```

---

#### 6. Cancel Transfer: `DELETE /api/v1/transfers/{id}`

Signals explicit cancellation. The server immediately aborts any background assembly jobs and removes stored partial chunk files.

**Response (200 OK):**
```json
{
  "transferId": "550e8400-e29b-41d4-a716-446655440000",
  "status": "CANCELLED",
  "purged": true
}
```

---

## 5. In-Flight Chunk Recovery & Idempotency Deep Dive

### 5.1 The Critical Lost-Response & Death Sequence

This flow illustrates the exact resilience guarantee required when client process death intersects with a lost server response:

```
Step  Actor     Action / State Transition
────────────────────────────────────────────────────────────────────────────────
 1.   Client    Picks Chunk 7 (State in DB: PENDING -> UPLOADING).
 2.   Client    Transmits PUT /chunks/7 with Idempotency-Key: "uuid:7:hashA".
 3.   Server    Receives chunk 7, validates hashA, writes chunk-7 to storage.
 4.   Server    Inserts record in server chunk ledger: (transferId, 7, COMPLETED, hashA).
 5.   Server    Generates HTTP 201 Created response.
 6.   Network   TCP RST / Drop: HTTP 201 response is LOST on the wire.
 7.   OS        Mobile OS kills client process (battery/memory/crash).
                * Client SQLite remains with Chunk 7 = 'UPLOADING'.
 8.   Reboot    Application restarts. Cold-Start Recovery runs:
                * Interrupted Chunk 7 is safely reset: UPLOADING -> PENDING.
                * Dirty transfer is reconciled: TRANSFERRING -> QUEUED.
 9.   Client    Transfer resumes automatically (QUEUED -> TRANSFERRING).
                Worker selects Chunk 7 (State: PENDING -> UPLOADING).
10.   Client    Retries PUT /chunks/7 with identical Idempotency-Key: "uuid:7:hashA".
11.   Server    Inspects chunk ledger: Chunk 7 is ALREADY marked COMPLETED.
12.   Server    Compares stored hash with incoming hash: hashA == hashA (MATCH).
13.   Server    NO DISK WRITE PERFORMED.
14.   Server    Returns HTTP 200 OK (X-Idempotent-Replay: true).
15.   Client    Receives 200 OK. Marks Chunk 7 = COMPLETED in local SQLite.
────────────────────────────────────────────────────────────────────────────────
```

### 5.2 Server Decision Algorithm (FastAPI / Node.js)

```python
@app.put("/api/v1/transfers/{transfer_id}/chunks/{chunk_index}")
async def upload_chunk(
    transfer_id: str,
    chunk_index: int,
    request: Request,
    idempotency_key: str = Header(..., alias="Idempotency-Key"),
    chunk_sha256: str = Header(..., alias="X-Chunk-SHA256")
):
    payload = await request.body()
    
    with db.begin_immediate_transaction():
        chunk = db.get_chunk(transfer_id, chunk_index)
        
        # 1. Idempotent Replay Check
        if chunk and chunk.status == "COMPLETED":
            if chunk.sha256 == chunk_sha256:
                # Chunk already committed and identical: return success without writing
                return Response(
                    status_code=200,
                    headers={"X-Idempotent-Replay": "true"},
                    content=json.dumps({"status": "COMPLETED", "isIdempotentReplay": True})
                )
            else:
                # Catastrophic collision: Same chunk index, different payload
                return Response(
                    status_code=409,
                    content=json.dumps({"error": "CHUNK_CHECKSUM_CONFLICT"})
                )
        
        # 2. Payload Validation
        calculated_hash = hashlib.sha256(payload).hexdigest()
        if calculated_hash != chunk_sha256:
            return Response(status_code=400, content=json.dumps({"error": "PAYLOAD_HASH_MISMATCH"}))
            
        # 3. Commit Chunk
        write_to_disk(transfer_id, chunk_index, payload)
        db.save_chunk(transfer_id, chunk_index, status="COMPLETED", sha256=calculated_hash)
        
        return Response(
            status_code=201,
            headers={"X-Idempotent-Replay": "false"},
            content=json.dumps({"status": "COMPLETED", "isIdempotentReplay": False})
        )
```

---

## 6. Client vs. Server Chunk State Mismatch Resolution

During startup reconciliation or network re-establishment, client and server states might diverge due to lost packets or server-side transient resets. The engine resolves state drift deterministically:

| Client State | Server State | Resolution Action | Rationale |
| :--- | :--- | :--- | :--- |
| `PENDING` | `COMPLETED` | **Advance Client to `COMPLETED`** | Server already has the verified chunk. Upon reconciliation (via `GET /transfers/{id}`) or upon client PUT retry (which receives `200 OK Idempotent Replay`), client immediately updates SQLite to `COMPLETED` and credits byte progress without re-transmitting payload. |
| `COMPLETED` | `MISSING` | **Demote Client to `PENDING`** | The server suffered storage loss or session eviction. If server reports chunk missing during `GET /transfers/{id}` or rejects `POST /finalize`, client sets local chunk state back to `PENDING`, decrements `bytes_transferred`, and re-transmits the chunk. |
| `COMPLETED` | `COMPLETED` | **No Action (In Sync)** | Both parties agree; chunk is complete. |
| `PENDING` | `MISSING` | **Normal Dispatch** | Chunk is pending transfer; will be scheduled normally. |
| `COMPLETED` | `HASH_MISMATCH` | **Demote to `PENDING` & Re-send** | Server stored a corrupted payload. Client re-sends valid local byte slice. |

---

## 7. Protocol Disruption Semantics: USER_PAUSED ≠ INTERRUPTED ≠ CANCELLED

1. **User Pause (`USER_PAUSED`)**:
   - Client aborts ongoing chunk socket connections.
   - Client persists transfer state as `PAUSED` with reason `USER_PAUSED`.
   - **No destructive call** (`DELETE`) is sent to the server.
   - **On Application Restart**: Client leaves transfer in `PAUSED`. It will **NOT** resume until user explicitly calls Resume.
2. **Unexpected Interruption (`INTERRUPTED`)**:
   - Client process terminates abruptly without warning.
   - Socket connection drops on the wire; server times out the chunk connection or stores chunk if already committed.
   - **On Application Restart**: Client runs startup recovery, sets transfer state to `QUEUED`, and **automatically resumes transfer** into `TRANSFERRING` without user prompt.
3. **Cancellation (`CANCELLED`)**:
   - Client fires `DELETE /api/v1/transfers/{id}` to server.
   - Server purges all stored partial chunks.
   - Client marks local record `CANCELLED` and purges partial disk files.
   - **On Application Restart**: Record remains permanently `CANCELLED`. Never automatically resumes or resurrects.

---

## 8. Fault Injection Directives (HTTP Headers)

The test mock server and client Dio interceptor interpret the `X-Fault-Inject` header to simulate deterministic edge cases:

```http
X-Fault-Inject: type=drop-response;targetChunk=7
```

### Supported Directives:

1. `type=network-cut;targetChunk=N`: Server forcefully closes TCP socket before replying.
2. `type=timeout;targetChunk=N;delayMs=15000`: Server holds request until client timeout trips.
3. `type=status-500;targetChunk=N;attempts=2`: Server returns HTTP 500 for first 2 attempts on chunk $N$, then succeeds on attempt 3.
4. `type=drop-response;targetChunk=N`: Server commits chunk $N$ to disk/DB, then immediately severs connection without sending HTTP response (tests idempotency).
5. `type=corrupt-data;targetChunk=N`: Inverts bytes in chunk payload to trigger SHA-256 rejection.
