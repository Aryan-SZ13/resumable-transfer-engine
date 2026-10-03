import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import '../domain/models/enums.dart';
import '../domain/transport/transport_exceptions.dart';
import '../domain/transport/transport_models.dart';

/// Server-side representation of a stored chunk.
class ServerChunkRecord {
  final int chunkIndex;
  final int byteOffset;
  final int byteLength;
  final String sha256;
  final String idempotencyKey;
  final Uint8List bytes;

  ServerChunkRecord({
    required this.chunkIndex,
    required this.byteOffset,
    required this.byteLength,
    required this.sha256,
    required this.idempotencyKey,
    required List<int> rawBytes,
  }) : bytes = Uint8List.fromList(rawBytes);
}

/// Server-side representation of an active transfer session.
class ServerTransferRecord {
  final String transferId;
  final String fileName;
  final int fileSize;
  final TransferDirection direction;
  final int chunkSize;
  final int totalChunks;
  final String expectedFileSha256;
  final DateTime createdAt;
  bool isFinalized;

  final Map<int, ServerChunkRecord> _chunks = {};

  ServerTransferRecord({
    required this.transferId,
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.chunkSize,
    required this.totalChunks,
    required this.expectedFileSha256,
    required this.createdAt,
    this.isFinalized = false,
  });

  Map<int, ServerChunkRecord> get chunks => Map.unmodifiable(_chunks);

  int get completedChunksCount => _chunks.length;

  int get completedBytes =>
      _chunks.values.fold<int>(0, (acc, c) => acc + c.byteLength);

  /// Registers or validates an uploaded chunk according to strict idempotency rules.
  ///
  /// - If chunk does not exist: Validates checksum & bounds, persists chunk, returns [UploadChunkStatus.accepted].
  /// - If chunk exists with identical checksum: Returns [UploadChunkStatus.idempotentReplay] WITHOUT writing duplicate bytes.
  /// - If chunk exists with different checksum: Throws [IdempotencyConflictException] (never overwrites).
  UploadChunkStatus addOrValidateChunk({
    required int chunkIndex,
    required int byteOffset,
    required int byteLength,
    required String declaredSha256,
    required String idempotencyKey,
    required List<int> payload,
  }) {
    if (chunkIndex < 0 || chunkIndex >= totalChunks) {
      throw InvalidChunkException(
        message:
            'Chunk index $chunkIndex out of bounds for total chunks $totalChunks.',
        chunkIndex: chunkIndex,
      );
    }

    if (byteLength != payload.length) {
      throw MalformedRequestException(
        message:
            'Declared byteLength ($byteLength) does not match payload size (${payload.length}).',
      );
    }

    // 1. Calculate and verify actual payload checksum
    final calculatedSha256 = sha256.convert(payload).toString();
    if (calculatedSha256 != declaredSha256) {
      throw ChecksumRejectionException(
        message:
            'Chunk $chunkIndex payload checksum mismatch: declared=$declaredSha256, actual=$calculatedSha256.',
        expectedSha256: declaredSha256,
        actualSha256: calculatedSha256,
      );
    }

    // 2. Check for existing chunk (Idempotency Invariant)
    final existing = _chunks[chunkIndex];
    if (existing != null) {
      if (existing.sha256 == declaredSha256) {
        // Idempotent duplicate: exact match, no duplicate storage
        return UploadChunkStatus.idempotentReplay;
      } else {
        // Idempotency conflict: same index, different checksum
        throw IdempotencyConflictException(
          message:
              'Chunk $chunkIndex already exists with conflicting SHA-256 (existing=${existing.sha256}, attempted=$declaredSha256).',
          transferId: transferId,
          chunkIndex: chunkIndex,
          existingSha256: existing.sha256,
          attemptedSha256: declaredSha256,
        );
      }
    }

    // 3. Persist new chunk
    _chunks[chunkIndex] = ServerChunkRecord(
      chunkIndex: chunkIndex,
      byteOffset: byteOffset,
      byteLength: byteLength,
      sha256: declaredSha256,
      idempotencyKey: idempotencyKey,
      rawBytes: payload,
    );

    return UploadChunkStatus.accepted;
  }

  /// Finalizes the transfer by assembling chunks and verifying whole-file SHA-256.
  FinalizeTransferResponse finalizeTransfer(String declaredFinalSha256) {
    if (_chunks.length < totalChunks) {
      throw MalformedRequestException(
        message:
            'Cannot finalize transfer: only ${_chunks.length}/$totalChunks chunks uploaded.',
      );
    }

    // Reassemble full file in strict chunk index order
    final assembled = BytesBuilder(copy: false);
    for (int i = 0; i < totalChunks; i++) {
      final chunk = _chunks[i];
      if (chunk == null) {
        throw MalformedRequestException(
          message: 'Missing chunk $i during file reassembly.',
        );
      }
      assembled.add(chunk.bytes);
    }

    final fullBytes = assembled.takeBytes();
    final actualFinalSha256 = sha256.convert(fullBytes).toString();

    if (actualFinalSha256 != declaredFinalSha256) {
      throw ChecksumRejectionException(
        message:
            'Final reassembled file SHA-256 mismatch: expected=$declaredFinalSha256, actual=$actualFinalSha256.',
        expectedSha256: declaredFinalSha256,
        actualSha256: actualFinalSha256,
      );
    }

    isFinalized = true;

    return FinalizeTransferResponse(
      transferId: transferId,
      isVerified: true,
      verifiedBytes: fullBytes.length,
      actualFileSha256: actualFinalSha256,
    );
  }
}
