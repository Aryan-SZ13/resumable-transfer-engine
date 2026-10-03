import '../models/chunk.dart';
import '../models/enums.dart';

/// Pure functional calculator for deterministic chunk partitioning and boundary arithmetic.
class ChunkCalculator {
  const ChunkCalculator();

  /// Calculates the total number of chunks required for a given file size and chunk size.
  /// A zero-byte file produces 1 chunk of length 0 to allow registration and manifest tracking.
  static int calculateTotalChunks(int fileSize, int chunkSize) {
    if (fileSize < 0) {
      throw ArgumentError.value(fileSize, 'fileSize', 'Must be non-negative');
    }
    if (chunkSize <= 0) {
      throw ArgumentError.value(
          chunkSize, 'chunkSize', 'Must be strictly positive');
    }
    if (fileSize == 0) return 1;
    return (fileSize + chunkSize - 1) ~/ chunkSize;
  }

  /// Calculates the byte offset for a 0-indexed chunk.
  static int calculateOffset(int chunkIndex, int chunkSize) {
    if (chunkIndex < 0) {
      throw ArgumentError.value(
          chunkIndex, 'chunkIndex', 'Must be non-negative');
    }
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'Must be positive');
    }
    return chunkIndex * chunkSize;
  }

  /// Calculates the byte length for a chunk, correctly truncating the final remainder chunk.
  static int calculateLength(int chunkIndex, int fileSize, int chunkSize) {
    if (fileSize == 0) return 0;
    final offset = calculateOffset(chunkIndex, chunkSize);
    if (offset >= fileSize) {
      throw RangeError('Chunk offset $offset is beyond file size $fileSize');
    }
    final remaining = fileSize - offset;
    return remaining < chunkSize ? remaining : chunkSize;
  }

  /// Generates the complete list of initial [Chunk] records in [ChunkState.pending] for a transfer.
  static List<Chunk> generateChunks({
    required String transferId,
    required int fileSize,
    required int chunkSize,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now().toUtc();
    final total = calculateTotalChunks(fileSize, chunkSize);

    return List.generate(total, (index) {
      final offset = calculateOffset(index, chunkSize);
      final length = calculateLength(index, fileSize, chunkSize);

      return Chunk(
        transferId: transferId,
        chunkIndex: index,
        byteOffset: offset,
        byteLength: length,
        state: ChunkState.pending,
        retryCount: 0,
        updatedAt: timestamp,
      );
    });
  }

  /// Resolves the 0-indexed chunk containing a specific 0-indexed byte position within a file.
  ///
  /// Bound semantics:
  /// - `bytePosition == 0`: Returns 0 (if `fileSize > 0`).
  /// - `0 <= bytePosition < fileSize`: Returns `bytePosition ~/ chunkSize`.
  /// - `bytePosition == fileSize - 1` (final byte): Returns the final chunk index.
  /// - `fileSize == 0`: Throws [RangeError] (empty file has no addressable bytes).
  /// - `bytePosition < 0`: Throws [ArgumentError].
  /// - `bytePosition >= fileSize`: Throws [RangeError] (cannot index at or beyond EOF).
  static int getChunkIndexForByte({
    required int bytePosition,
    required int fileSize,
    required int chunkSize,
  }) {
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'Must be positive');
    }
    if (fileSize < 0) {
      throw ArgumentError.value(fileSize, 'fileSize', 'Must be non-negative');
    }
    if (bytePosition < 0) {
      throw ArgumentError.value(
          bytePosition, 'bytePosition', 'Must be non-negative');
    }
    if (fileSize == 0) {
      throw RangeError(
          'Zero-byte file contains no addressable byte positions.');
    }
    if (bytePosition >= fileSize) {
      throw RangeError.range(
        bytePosition,
        0,
        fileSize - 1,
        'bytePosition',
        'Byte position $bytePosition is at or beyond file size $fileSize (EOF).',
      );
    }
    return bytePosition ~/ chunkSize;
  }
}
