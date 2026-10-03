import '../models/chunk.dart';
import '../models/enums.dart';

/// Repository interface for persisting and querying individual [Chunk] records.
abstract interface class ChunkRepository {
  /// Inserts a batch of initial chunk records for a transfer.
  Future<void> insertChunks(List<Chunk> chunks);

  /// Retrieves all chunks associated with a specific transfer, ordered by chunkIndex.
  Future<List<Chunk>> getChunksForTransfer(String transferId);

  /// Fetches a specific chunk by transfer ID and index.
  Future<Chunk?> getChunk(String transferId, int chunkIndex);

  /// Retrieves all chunks for a transfer matching a specific chunk state.
  Future<List<Chunk>> getChunksByState(String transferId, ChunkState state);

  /// Updates an individual chunk's state, hash, and retry count.
  Future<void> updateChunk(Chunk chunk);

  /// Resets all chunks in state [fromState] (e.g. UPLOADING) to [toState] (e.g. PENDING) for a transfer.
  /// Returns the number of chunks affected.
  Future<int> resetChunkStates({
    required String transferId,
    required ChunkState fromState,
    required ChunkState toState,
  });
}
