import 'package:resumable_transfer_engine/resumable_transfer_engine.dart';
import 'package:test/test.dart';

void main() {
  group('ChunkCalculator', () {
    test('Exact division: 10 MB file with 2 MB chunks', () {
      const fileSize = 10 * 1024 * 1024; // 10,485,760 bytes
      const chunkSize = 2 * 1024 * 1024; // 2,097,152 bytes

      final total = ChunkCalculator.calculateTotalChunks(fileSize, chunkSize);
      expect(total, 5);

      final chunks = ChunkCalculator.generateChunks(
        transferId: 't-exact',
        fileSize: fileSize,
        chunkSize: chunkSize,
      );

      expect(chunks.length, 5);
      for (var i = 0; i < 5; i++) {
        expect(chunks[i].chunkIndex, i);
        expect(chunks[i].byteOffset, i * chunkSize);
        expect(chunks[i].byteLength, chunkSize);
        expect(chunks[i].state, ChunkState.pending);
      }
    });

    test('Remainder / uneven file: 10 MB file with 3 MB chunks', () {
      const fileSize = 10 * 1024 * 1024; // 10,485,760 bytes
      const chunkSize = 3 * 1024 * 1024; // 3,145,728 bytes

      final total = ChunkCalculator.calculateTotalChunks(fileSize, chunkSize);
      expect(total, 4); // 3 * 3MB + 1MB remainder

      final chunks = ChunkCalculator.generateChunks(
        transferId: 't-remainder',
        fileSize: fileSize,
        chunkSize: chunkSize,
      );

      expect(chunks.length, 4);

      // Chunks 0, 1, 2 have length = 3 MB
      for (var i = 0; i < 3; i++) {
        expect(chunks[i].byteOffset, i * chunkSize);
        expect(chunks[i].byteLength, chunkSize);
      }

      // Chunk 3 has length = 1 MB (10 MB - 9 MB = 1 MB)
      expect(chunks[3].chunkIndex, 3);
      expect(chunks[3].byteOffset, 3 * chunkSize);
      expect(chunks[3].byteLength, 1 * 1024 * 1024);

      // Sum of lengths strictly equals total file size
      final sum = chunks.fold<int>(0, (acc, c) => acc + c.byteLength);
      expect(sum, fileSize);
    });

    test('Small file: file smaller than chunk size', () {
      const fileSize = 500 * 1024; // 500 KB
      const chunkSize = 2 * 1024 * 1024; // 2 MB

      final total = ChunkCalculator.calculateTotalChunks(fileSize, chunkSize);
      expect(total, 1);

      final chunks = ChunkCalculator.generateChunks(
        transferId: 't-small',
        fileSize: fileSize,
        chunkSize: chunkSize,
      );

      expect(chunks.length, 1);
      expect(chunks[0].chunkIndex, 0);
      expect(chunks[0].byteOffset, 0);
      expect(chunks[0].byteLength, fileSize);
    });

    test('Zero-byte file handling', () {
      const fileSize = 0;
      const chunkSize = 1024 * 1024;

      final total = ChunkCalculator.calculateTotalChunks(fileSize, chunkSize);
      expect(total, 1);

      final chunks = ChunkCalculator.generateChunks(
        transferId: 't-zero',
        fileSize: fileSize,
        chunkSize: chunkSize,
      );

      expect(chunks.length, 1);
      expect(chunks[0].byteOffset, 0);
      expect(chunks[0].byteLength, 0);
    });

    test('getChunkIndexForByte calculation with boundary invariants', () {
      const chunkSize = 1000;
      const fileSize = 2500;

      // First byte
      expect(
        ChunkCalculator.getChunkIndexForByte(
          bytePosition: 0,
          fileSize: fileSize,
          chunkSize: chunkSize,
        ),
        0,
      );

      // End of first chunk
      expect(
        ChunkCalculator.getChunkIndexForByte(
          bytePosition: 999,
          fileSize: fileSize,
          chunkSize: chunkSize,
        ),
        0,
      );

      // Start of second chunk
      expect(
        ChunkCalculator.getChunkIndexForByte(
          bytePosition: 1000,
          fileSize: fileSize,
          chunkSize: chunkSize,
        ),
        1,
      );

      // Last byte of file (fileSize - 1 = 2499)
      expect(
        ChunkCalculator.getChunkIndexForByte(
          bytePosition: 2499,
          fileSize: fileSize,
          chunkSize: chunkSize,
        ),
        2,
      );
    });

    test('getChunkIndexForByte throws on EOF or out of bounds (C-1)', () {
      const chunkSize = 1000;
      const fileSize = 2500;

      // Exactly at EOF
      expect(
        () => ChunkCalculator.getChunkIndexForByte(
          bytePosition: 2500,
          fileSize: fileSize,
          chunkSize: chunkSize,
        ),
        throwsA(isA<RangeError>()),
      );

      // Beyond EOF
      expect(
        () => ChunkCalculator.getChunkIndexForByte(
          bytePosition: 3000,
          fileSize: fileSize,
          chunkSize: chunkSize,
        ),
        throwsA(isA<RangeError>()),
      );

      // Negative byte position
      expect(
        () => ChunkCalculator.getChunkIndexForByte(
          bytePosition: -1,
          fileSize: fileSize,
          chunkSize: chunkSize,
        ),
        throwsArgumentError,
      );

      // Zero-byte file has no addressable bytes
      expect(
        () => ChunkCalculator.getChunkIndexForByte(
          bytePosition: 0,
          fileSize: 0,
          chunkSize: chunkSize,
        ),
        throwsA(isA<RangeError>()),
      );
    });

    test('Invalid arguments throw ArgumentError', () {
      expect(
        () => ChunkCalculator.calculateTotalChunks(-100, 1024),
        throwsArgumentError,
      );
      expect(
        () => ChunkCalculator.calculateTotalChunks(1000, 0),
        throwsArgumentError,
      );
      expect(
        () => ChunkCalculator.calculateTotalChunks(1000, -500),
        throwsArgumentError,
      );
    });
  });
}
