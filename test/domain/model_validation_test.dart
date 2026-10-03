import 'package:resumable_transfer_engine/resumable_transfer_engine.dart';
import 'package:test/test.dart';

void main() {
  group('Transfer Model Invariants (D-1)', () {
    final now = DateTime.now().toUtc();

    test('Valid transfer creates successfully', () {
      final transfer = Transfer(
        id: 't-valid',
        fileName: 'test.bin',
        filePath: '/tmp/test.bin',
        fileSize: 1000,
        bytesTransferred: 500,
        chunkSize: 500,
        totalChunks: 2,
        completedChunks: 1,
        direction: TransferDirection.upload,
        state: TransferState.transferring,
        fileSha256: 'hash123',
        createdAt: now,
        updatedAt: now,
      );

      expect(transfer.id, 't-valid');
      expect(transfer.bytesTransferred, 500);
      expect(transfer.completedChunks, 1);
    });

    test('Throws on negative fileSize', () {
      expect(
        () => Transfer(
          id: 't-neg-total',
          fileName: 'test.bin',
          filePath: '/tmp/test.bin',
          fileSize: -1,
          direction: TransferDirection.upload,
          state: TransferState.queued,
          chunkSize: 100,
          totalChunks: 1,
          fileSha256: 'h',
          createdAt: now,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Throws on negative bytesTransferred', () {
      expect(
        () => Transfer(
          id: 't-neg-transferred',
          fileName: 'test.bin',
          filePath: '/tmp/test.bin',
          fileSize: 100,
          bytesTransferred: -1,
          direction: TransferDirection.upload,
          state: TransferState.queued,
          chunkSize: 100,
          totalChunks: 1,
          fileSha256: 'h',
          createdAt: now,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Throws when bytesTransferred > fileSize', () {
      expect(
        () => Transfer(
          id: 't-transferred-overflow',
          fileName: 'test.bin',
          filePath: '/tmp/test.bin',
          fileSize: 100,
          bytesTransferred: 101,
          direction: TransferDirection.upload,
          state: TransferState.queued,
          chunkSize: 100,
          totalChunks: 1,
          fileSha256: 'h',
          createdAt: now,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Throws on negative chunkSize', () {
      expect(
        () => Transfer(
          id: 't-neg-chunksize',
          fileName: 'test.bin',
          filePath: '/tmp/test.bin',
          fileSize: 100,
          direction: TransferDirection.upload,
          state: TransferState.queued,
          chunkSize: 0,
          totalChunks: 1,
          fileSha256: 'h',
          createdAt: now,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Throws on negative totalChunks', () {
      expect(
        () => Transfer(
          id: 't-neg-total-chunks',
          fileName: 'test.bin',
          filePath: '/tmp/test.bin',
          fileSize: 100,
          direction: TransferDirection.upload,
          state: TransferState.queued,
          chunkSize: 100,
          totalChunks: -1,
          fileSha256: 'h',
          createdAt: now,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Throws on negative completedChunks', () {
      expect(
        () => Transfer(
          id: 't-neg-completed-chunks',
          fileName: 'test.bin',
          filePath: '/tmp/test.bin',
          fileSize: 100,
          direction: TransferDirection.upload,
          state: TransferState.queued,
          chunkSize: 100,
          totalChunks: 1,
          completedChunks: -1,
          fileSha256: 'h',
          createdAt: now,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Throws when completedChunks > totalChunks', () {
      expect(
        () => Transfer(
          id: 't-chunks-overflow',
          fileName: 'test.bin',
          filePath: '/tmp/test.bin',
          fileSize: 100,
          bytesTransferred: 100,
          direction: TransferDirection.upload,
          state: TransferState.transferring,
          chunkSize: 100,
          totalChunks: 1,
          completedChunks: 2,
          fileSha256: 'h',
          createdAt: now,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });
  });

  group('Chunk Model Invariants (D-1, D-2)', () {
    final now = DateTime.now().toUtc();

    test('Valid chunk creates successfully', () {
      final chunk = Chunk(
        transferId: 't-1',
        chunkIndex: 0,
        byteOffset: 0,
        byteLength: 100,
        state: ChunkState.pending,
        retryCount: 0,
        sha256: 'abc123hash',
        updatedAt: now,
      );

      expect(chunk.chunkIndex, 0);
      expect(chunk.idempotencyKey, 't-1:0:abc123hash');
    });

    test('Throws on negative chunkIndex', () {
      expect(
        () => Chunk(
          transferId: 't-1',
          chunkIndex: -1,
          byteOffset: 0,
          byteLength: 100,
          state: ChunkState.pending,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Throws on negative byteOffset', () {
      expect(
        () => Chunk(
          transferId: 't-1',
          chunkIndex: 0,
          byteOffset: -1,
          byteLength: 100,
          state: ChunkState.pending,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Throws on negative byteLength', () {
      expect(
        () => Chunk(
          transferId: 't-1',
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: -1,
          state: ChunkState.pending,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Throws on negative retryCount', () {
      expect(
        () => Chunk(
          transferId: 't-1',
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: 100,
          retryCount: -1,
          state: ChunkState.pending,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test(
        'Throws StateError if accessing idempotencyKey with empty sha256 (D-2)',
        () {
      final chunkWithEmptyHash = Chunk(
        transferId: 't-1',
        chunkIndex: 0,
        byteOffset: 0,
        byteLength: 100,
        state: ChunkState.pending,
        sha256: '',
        updatedAt: now,
      );

      expect(
        () => chunkWithEmptyHash.idempotencyKey,
        throwsStateError,
      );
    });
  });
}
