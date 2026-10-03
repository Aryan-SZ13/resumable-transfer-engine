# Phase 2 — Wire Protocol & Transport Specification

**Version:** 1.0  
**Status:** Approved & Implemented  
**Scope:** HTTP/1.1 REST + Binary Chunk Transport Protocol  

---

## 1. Protocol Overview

The Resumable Transfer Engine protocol provides fault-tolerant, deterministic chunked file upload and download operations over HTTP. 

Key principles:
1. **Transport Decoupling:** The transport layer is an execution medium that translates wire traffic into typed domain results (`TransportResult<T>`). It does **not** own retry policies, backoff timers, or orchestration loops.
2. **Deterministic Idempotency:** Every chunk is uniquely identified by `(transferId, chunkIndex, sha256)`. Duplicates are acknowledged without redundant disk/byte writes.
3. **Chunk & Whole-File Integrity:** Cryptographic SHA-256 validation is enforced on every single byte chunk and across the reassembled whole file upon completion.
4. **Upload/Download Symmetry:** Both upload and download share the same transfer identifiers, chunk indexing, boundary arithmetic, and checksum validation semantics.

---

## 2. Endpoint Definitions

All endpoints are rooted under the path prefix `/api/v1/transfers`.

| Method | Endpoint | Description | Request Body | Response Body |
| :--- | :--- | :--- | :--- | :--- |
| `POST` | `/api/v1/transfers` | Initialize or register a transfer session | JSON manifest | JSON session metadata |
| `PUT` | `/api/v1/transfers/{id}/chunks/{index}` | Upload a specific byte chunk | Binary payload | JSON chunk ack |
| `GET` | `/api/v1/transfers/{id}` | Query server status and completed chunks | None | JSON status manifest |
| `POST` | `/api/v1/transfers/{id}/finalize` | Assemble chunks and verify whole-file SHA-256 | JSON expected hash | JSON verification summary |
| `GET` | `/api/v1/transfers/{id}/chunks/{index}` | Download a specific byte chunk | None | Binary payload + headers |

---

## 3. Schemas & Wire Models

### 3.1 Create Transfer (`POST /api/v1/transfers`)

**Request Headers:**
- `Content-Type: application/json`

**Request Body (JSON):**
```json
{
  "transferId": "transfer-uuid-1234",
  "fileName": "large_archive.tar.gz",
  "fileSize": 104857600,
  "direction": "UPLOAD",
  "chunkSize": 2097152,
  "totalChunks": 50,
  "fileSha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
```

**Response Body (201 Created / 200 OK):**
```json
{
  "transferId": "transfer-uuid-1234",
  "status": "CREATED",
  "chunkSize": 2097152,
  "totalChunks": 50,
  "protocolVersion": "1.0"
}
```

---

### 3.2 Upload Chunk (`PUT /api/v1/transfers/{id}/chunks/{index}`)

**Request Headers:**
- `Content-Type: application/octet-stream`
- `X-Idempotency-Key: {transferId}:{chunkIndex}:{sha256}`
- `X-Chunk-SHA256: {sha256Hex}`
- `X-Byte-Offset: {offsetInt}`
- `X-Byte-Length: {lengthInt}`

**Request Body:**
- Raw binary bytes of the chunk.

**Response Body (201 Created for new chunk, 200 OK for idempotent duplicate):**
```json
{
  "transferId": "transfer-uuid-1234",
  "chunkIndex": 0,
  "status": "ACCEPTED", 
  "sha256": "4b227777d4dd1fc61c6f884f48641d02b4d121d3fd328cb08b5531fcacdabf8a",
  "bytesReceived": 2097152
}
```
*Note: If the chunk was already persisted, `status` returns `"IDEMPOTENT_REPLAY"`.*

---

### 3.3 Transfer Status Query (`GET /api/v1/transfers/{id}`)

**Response Body (200 OK):**
```json
{
  "transferId": "transfer-uuid-1234",
  "serverState": "TRANSFERRING",
  "completedChunkIndexes": [0, 1, 2, 3],
  "completedBytes": 8388608,
  "totalBytes": 104857600,
  "isFinalized": false,
  "serverFileSha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
```

---

### 3.4 Finalize Transfer (`POST /api/v1/transfers/{id}/finalize`)

**Request Body (JSON):**
```json
{
  "expectedFileSha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
```

**Response Body (200 OK):**
```json
{
  "transferId": "transfer-uuid-1234",
  "isVerified": true,
  "verifiedBytes": 104857600,
  "actualFileSha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
```

---

### 3.5 Download Chunk (`GET /api/v1/transfers/{id}/chunks/{index}`)

**Response Headers:**
- `Content-Type: application/octet-stream`
- `X-Chunk-SHA256: {sha256Hex}`
- `X-Byte-Offset: {offsetInt}`
- `X-Byte-Length: {lengthInt}`

**Response Body:**
- Raw binary bytes of the chunk.

---

## 4. HTTP Status Code Mapping

The transport layer maps HTTP status codes and response bodies into strongly-typed `TransportException` instances:

| HTTP Status | Error Type / Code | Domain Exception | Description |
| :--- | :--- | :--- | :--- |
| `200` / `201` | Success | `TransportSuccess<T>` | Operation completed or idempotently confirmed. |
| `400` | `CHECKSUM_REJECTION` | `ChecksumRejectionException` | Payload SHA-256 does not match declared header. |
| `400` | `INVALID_CHUNK` | `InvalidChunkException` | Index or bounds out of range. |
| `400` | `MALFORMED_REQUEST` | `MalformedRequestException` | Body/header formatting error or premature finalization. |
| `404` | `TRANSFER_NOT_FOUND` | `TransferNotFoundException` | Session ID does not exist on server. |
| `404` | `CHUNK_NOT_FOUND` | `TransferNotFoundException` | Chunk has not been uploaded to server. |
| `408` | `REQUEST_TIMEOUT` | `TimeoutTransportException` | Request or socket timed out waiting for server. |
| `409` | `IDEMPOTENCY_CONFLICT`| `IdempotencyConflictException`| Chunk index already exists with **different** SHA-256. |
| `429` | `RATE_LIMITED` | `RateLimitedException` | Server rate limits exceeded; client must back off. |
| `5xx` | `SERVER_ERROR` | `TemporaryServerFailureException` | Internal server or storage malfunction. |
| Socket Error | Network drop | `ConnectionFailureException` | Broken pipe, connection refused, or abrupt reset. |

---

## 5. Idempotency Protocol Invariant

The logical chunk identity is defined as:
$$\text{Chunk Identity} = \langle \text{transferId}, \text{chunkIndex}, \text{sha256} \rangle$$

### Behavior Matrix

| Incoming Request | Server State | Server Action | Response Code | Result Status |
| :--- | :--- | :--- | :--- | :--- |
| Chunk $(T, I, S_1)$ | No chunk $I$ exists | Stores chunk $I$ | `201 Created` | `ACCEPTED` |
| Chunk $(T, I, S_1)$ | Chunk $I$ exists with $S_1$ | **No disk write** | `200 OK` | `IDEMPOTENT_REPLAY` |
| Chunk $(T, I, S_2)$ | Chunk $I$ exists with $S_1$ | **Reject & preserve $S_1$** | `409 Conflict` | `IDEMPOTENCY_CONFLICT` |

---

## 6. Critical Failure Sequence: Drop Response After Processing

```
Client                                  Server
  |                                       |
  |--- PUT chunk 0 (SHA=s1) ------------->|
  |                                       | 1. Validate chunk 0 SHA-256
  |                                       | 2. Persist chunk 0 to storage
  |                                       | 3. [FAULT INJECTED]: Drop connection!
  |<- - - Socket Closed Abruptly - - - - -|
  |                                       |
  | [Client observes ConnectionFailure]   |
  |                                       |
  |--- RETRY: PUT chunk 0 (SHA=s1) ------>|
  |                                       | 4. Match (transferId, index 0, s1)
  |                                       | 5. Detect IDEMPOTENT_REPLAY
  |                                       | 6. ZERO duplicate bytes stored!
  |<-- 200 OK (IDEMPOTENT_REPLAY) --------|
  |                                       |
  | [Client marks Chunk 0 COMPLETED]      |
```

---

## 7. Whole-File Assembly & Integrity Invariant

Finalization cannot occur until:
$$\sum_{i=0}^{N-1} \text{chunk}[i] \text{ are verified present}$$
Upon receiving `/finalize`:
1. Server sequentially joins bytes of chunks $0, 1, \dots, N-1$.
2. Server computes $\text{actualSha} = \text{SHA256}(\text{assembledBytes})$.
3. If $\text{actualSha} == \text{expectedFileSha256}$, status transitions to `COMPLETED`.
4. If mismatch occurs, server returns `400 Bad Request (CHECKSUM_REJECTION)`.

---

## 8. Failure Taxonomy & Separation of Concerns

```
Transport Layer (Phase 2A)               Transfer Engine (Phase 2B)
--------------------------               --------------------------
Reports typed conditions:                Decides response policy:
  • ConnectionFailure                      • Retry with exponential backoff
  • Timeout                                • Retry count limit
  • RateLimited (429)                      • Transient vs permanent failure
  • TemporaryServerFailure (5xx)           • Pause / user notification
  • IdempotencyConflict (409)              • Abort transfer / clean state
  • ChecksumRejection (400)
```
