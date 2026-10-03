import 'package:meta/meta.dart';
import 'enums.dart';

/// Represents an immutable byte segment of a transfer.
@immutable
class Chunk {
  final String transferId;
  final int chunkIndex;
  final int byteOffset;
  final int byteLength;
  final ChunkState state;
  final String sha256;
  final int retryCount;
  final DateTime updatedAt;

  Chunk({
    required this.transferId,
    required this.chunkIndex,
    required this.byteOffset,
    required this.byteLength,
    required this.state,
    this.sha256 = '',
    this.retryCount = 0,
    required this.updatedAt,
  }) {
    if (chunkIndex < 0) {
      throw ArgumentError.value(
          chunkIndex, 'chunkIndex', 'chunkIndex must be non-negative');
    }
    if (byteOffset < 0) {
      throw ArgumentError.value(
          byteOffset, 'byteOffset', 'byteOffset must be non-negative');
    }
    if (byteLength < 0) {
      throw ArgumentError.value(
          byteLength, 'byteLength', 'byteLength must be non-negative');
    }
    if (retryCount < 0) {
      throw ArgumentError.value(
          retryCount, 'retryCount', 'retryCount must be non-negative');
    }
  }

  /// Derives the standard idempotency key for this chunk.
  /// Throws [StateError] if called before the chunk's SHA-256 digest is known.
  String get idempotencyKey {
    if (sha256.isEmpty) {
      throw StateError(
        'Cannot derive idempotencyKey for chunk $chunkIndex before SHA-256 hash is computed.',
      );
    }
    return '$transferId:$chunkIndex:$sha256';
  }

  Chunk copyWith({
    String? transferId,
    int? chunkIndex,
    int? byteOffset,
    int? byteLength,
    ChunkState? state,
    String? sha256,
    int? retryCount,
    DateTime? updatedAt,
  }) {
    return Chunk(
      transferId: transferId ?? this.transferId,
      chunkIndex: chunkIndex ?? this.chunkIndex,
      byteOffset: byteOffset ?? this.byteOffset,
      byteLength: byteLength ?? this.byteLength,
      state: state ?? this.state,
      sha256: sha256 ?? this.sha256,
      retryCount: retryCount ?? this.retryCount,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Chunk &&
          runtimeType == other.runtimeType &&
          transferId == other.transferId &&
          chunkIndex == other.chunkIndex &&
          byteOffset == other.byteOffset &&
          byteLength == other.byteLength &&
          state == other.state &&
          sha256 == other.sha256 &&
          retryCount == other.retryCount &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        transferId,
        chunkIndex,
        byteOffset,
        byteLength,
        state,
        sha256,
        retryCount,
        updatedAt,
      );

  @override
  String toString() =>
      'Chunk(transferId: $transferId, index: $chunkIndex, range: $byteOffset-${byteOffset + byteLength}, state: ${state.name}, retries: $retryCount)';
}
