import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:resumable_transfer_engine/resumable_transfer_engine.dart';
import 'package:test/test.dart';

void main() {
  group('MockTransferServer & HttpTransferTransport', () {
    late MockTransferServer server;
    late HttpTransferTransport transport;

    setUp(() async {
      server = await MockTransferServer.start();
      transport = HttpTransferTransport(
        baseUrl: server.baseUrl,
        timeout: const Duration(seconds: 5),
      );
    });

    tearDown(() async {
      transport.close();
      await server.stop();
    });

    // ==========================================
    // 1. CREATE TRANSFER
    // ==========================================
    test('1. create transfer: registers session successfully', () async {
      final req = CreateTransferRequest(
        transferId: 't-create-1',
        fileName: 'sample.iso',
        fileSize: 4000,
        direction: TransferDirection.upload,
        chunkSize: 2000,
        totalChunks: 2,
        fileSha256: 'mock_file_sha',
      );

      final result = await transport.createTransfer(req);

      expect(result.isSuccess, isTrue);
      final data = result.dataOrNull!;
      expect(data.transferId, 't-create-1');
      expect(data.status, 'CREATED');
      expect(data.totalChunks, 2);

      // Verify server in-memory state
      final serverRecord = server.getTransfer('t-create-1');
      expect(serverRecord, isNotNull);
      expect(serverRecord!.fileName, 'sample.iso');
      expect(serverRecord.totalChunks, 2);
    });

    // ==========================================
    // 2. UPLOAD VALID CHUNK
    // ==========================================
    test('2. upload valid chunk: accepted and stored', () async {
      const tId = 't-upload-valid';
      final payload = utf8.encode('Hello World, this is chunk 0');
      final chunkSha = sha256.convert(payload).toString();

      await transport.createTransfer(
        CreateTransferRequest(
          transferId: tId,
          fileName: 'data.txt',
          fileSize: payload.length,
          direction: TransferDirection.upload,
          chunkSize: payload.length,
          totalChunks: 1,
          fileSha256: chunkSha,
        ),
      );

      final uploadResult = await transport.uploadChunk(
        UploadChunkRequest(
          transferId: tId,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: payload.length,
          sha256: chunkSha,
          idempotencyKey: '$tId:0:$chunkSha',
          payload: payload,
        ),
      );

      expect(uploadResult.isSuccess, isTrue);
      final res = uploadResult.dataOrNull!;
      expect(res.status, UploadChunkStatus.accepted);
      expect(res.sha256, chunkSha);
      expect(res.bytesReceived, payload.length);

      // Inspect server record
      final serverRecord = server.getTransfer(tId)!;
      expect(serverRecord.completedChunksCount, 1);
      expect(serverRecord.chunks[0]!.sha256, chunkSha);
      expect(serverRecord.chunks[0]!.bytes, payload);
    });

    // ==========================================
    // 3. REJECT INVALID CHECKSUM
    // ==========================================
    test('3. reject invalid checksum: returns ChecksumRejectionException',
        () async {
      const tId = 't-checksum-err';
      final payload = utf8.encode('Original Payload');
      const bogusSha =
          '0000000000000000000000000000000000000000000000000000000000000000';

      await transport.createTransfer(
        CreateTransferRequest(
          transferId: tId,
          fileName: 'data.bin',
          fileSize: payload.length,
          direction: TransferDirection.upload,
          chunkSize: payload.length,
          totalChunks: 1,
          fileSha256: 'valid_sha',
        ),
      );

      final result = await transport.uploadChunk(
        UploadChunkRequest(
          transferId: tId,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: payload.length,
          sha256: bogusSha,
          idempotencyKey: '$tId:0:$bogusSha',
          payload: payload,
        ),
      );

      expect(result.isFailure, isTrue);
      final error = result.errorOrNull!;
      expect(error, isA<ChecksumRejectionException>());
      expect(error.reason, TransportFailureReason.checksumRejection);

      // Verify server did NOT persist corrupt chunk
      final serverRecord = server.getTransfer(tId)!;
      expect(serverRecord.completedChunksCount, 0);
    });

    // ==========================================
    // 4. REJECT INVALID CHUNK INDEX
    // ==========================================
    test('4. reject invalid chunk index: returns InvalidChunkException',
        () async {
      const tId = 't-invalid-idx';
      final payload = [1, 2, 3, 4];
      final chunkSha = sha256.convert(payload).toString();

      await transport.createTransfer(
        CreateTransferRequest(
          transferId: tId,
          fileName: 'f.bin',
          fileSize: 4,
          direction: TransferDirection.upload,
          chunkSize: 4,
          totalChunks: 1, // Only chunk 0 is valid
          fileSha256: 'h',
        ),
      );

      // Attempt to upload chunk index 5
      final result = await transport.uploadChunk(
        UploadChunkRequest(
          transferId: tId,
          chunkIndex: 5,
          byteOffset: 0,
          byteLength: payload.length,
          sha256: chunkSha,
          idempotencyKey: '$tId:5:$chunkSha',
          payload: payload,
        ),
      );

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull, isA<InvalidChunkException>());
    });

    // ==========================================
    // 5. REJECT INVALID OFFSET / LENGTH
    // ==========================================
    test('5. reject invalid length: payload length mismatch throws locally',
        () async {
      const tId = 't-invalid-len';
      final payload = [1, 2, 3];

      expect(
        () => UploadChunkRequest(
          transferId: tId,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: 10, // Declared 10, actual payload 3
          sha256: 'h',
          idempotencyKey: 'k',
          payload: payload,
        ),
        throwsArgumentError,
      );
    });

    // ==========================================
    // 6. DUPLICATE IDENTICAL CHUNK IS IDEMPOTENT
    // ==========================================
    test(
        '6. duplicate identical chunk: returns IDEMPOTENT_REPLAY without duplicate storage',
        () async {
      const tId = 't-idempotent-replay';
      final payload = utf8.encode('Idempotent Chunk Content');
      final chunkSha = sha256.convert(payload).toString();

      await transport.createTransfer(
        CreateTransferRequest(
          transferId: tId,
          fileName: 'doc.txt',
          fileSize: payload.length,
          direction: TransferDirection.upload,
          chunkSize: payload.length,
          totalChunks: 1,
          fileSha256: chunkSha,
        ),
      );

      final req = UploadChunkRequest(
        transferId: tId,
        chunkIndex: 0,
        byteOffset: 0,
        byteLength: payload.length,
        sha256: chunkSha,
        idempotencyKey: '$tId:0:$chunkSha',
        payload: payload,
      );

      // First upload
      final res1 = await transport.uploadChunk(req);
      expect(res1.isSuccess, isTrue);
      expect(res1.dataOrNull!.status, UploadChunkStatus.accepted);

      // Duplicate upload
      final res2 = await transport.uploadChunk(req);
      expect(res2.isSuccess, isTrue);
      expect(res2.dataOrNull!.status, UploadChunkStatus.idempotentReplay);

      // Verify server storage has exactly ONE chunk
      final serverRecord = server.getTransfer(tId)!;
      expect(serverRecord.completedChunksCount, 1);
      expect(serverRecord.completedBytes, payload.length);
    });

    // ==========================================
    // 7. DUPLICATE CHUNK WITH DIFFERENT CHECKSUM IS CONFLICT
    // ==========================================
    test(
        '7. duplicate chunk with different checksum: returns IdempotencyConflictException',
        () async {
      const tId = 't-conflict';
      final payload1 = utf8.encode('First Payload');
      final sha1 = sha256.convert(payload1).toString();

      final payload2 = utf8.encode('Conflicting Payload');
      final sha2 = sha256.convert(payload2).toString();

      await transport.createTransfer(
        CreateTransferRequest(
          transferId: tId,
          fileName: 'conflict.txt',
          fileSize: 100,
          direction: TransferDirection.upload,
          chunkSize: 100,
          totalChunks: 1,
          fileSha256: 'h',
        ),
      );

      // Upload Chunk 0 original
      await transport.uploadChunk(
        UploadChunkRequest(
          transferId: tId,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: payload1.length,
          sha256: sha1,
          idempotencyKey: '$tId:0:$sha1',
          payload: payload1,
        ),
      );

      // Attempt to overwrite Chunk 0 with different payload & checksum
      final conflictResult = await transport.uploadChunk(
        UploadChunkRequest(
          transferId: tId,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: payload2.length,
          sha256: sha2,
          idempotencyKey: '$tId:0:$sha2',
          payload: payload2,
        ),
      );

      expect(conflictResult.isFailure, isTrue);
      final error = conflictResult.errorOrNull!;
      expect(error, isA<IdempotencyConflictException>());
      expect(error.reason, TransportFailureReason.idempotencyConflict);

      // Verify original chunk remains untouched
      final serverRecord = server.getTransfer(tId)!;
      expect(serverRecord.chunks[0]!.sha256, sha1);
      expect(serverRecord.chunks[0]!.bytes, payload1);
    });

    // ==========================================
    // 8. STATUS QUERY
    // ==========================================
    test('8. status query: returns verified completed chunks and bytes',
        () async {
      const tId = 't-status';
      final p0 = utf8.encode('Chunk 0 data');
      final sha0 = sha256.convert(p0).toString();

      await transport.createTransfer(
        CreateTransferRequest(
          transferId: tId,
          fileName: 'status.bin',
          fileSize: p0.length * 2,
          direction: TransferDirection.upload,
          chunkSize: p0.length,
          totalChunks: 2,
          fileSha256: 'full_hash',
        ),
      );

      await transport.uploadChunk(
        UploadChunkRequest(
          transferId: tId,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: p0.length,
          sha256: sha0,
          idempotencyKey: '$tId:0:$sha0',
          payload: p0,
        ),
      );

      final statusResult = await transport.getTransferStatus(tId);
      expect(statusResult.isSuccess, isTrue);
      final status = statusResult.dataOrNull!;
      expect(status.transferId, tId);
      expect(status.completedChunkIndexes, {0});
      expect(status.completedBytes, p0.length);
      expect(status.isFinalized, isFalse);
    });

    // ==========================================
    // 9. FINALIZE INCOMPLETE TRANSFER
    // ==========================================
    test('9. finalize incomplete transfer: returns MalformedRequestException',
        () async {
      const tId = 't-finalize-incomplete';
      await transport.createTransfer(
        CreateTransferRequest(
          transferId: tId,
          fileName: 'inc.bin',
          fileSize: 200,
          direction: TransferDirection.upload,
          chunkSize: 100,
          totalChunks: 2,
          fileSha256: 'full_hash',
        ),
      );

      // Only chunk 0 is uploaded, chunk 1 is missing
      final res = await transport.finalizeTransfer(
        const FinalizeTransferRequest(
          transferId: tId,
          expectedFileSha256: 'full_hash',
        ),
      );

      expect(res.isFailure, isTrue);
      expect(res.errorOrNull, isA<MalformedRequestException>());
    });

    // ==========================================
    // 10. FINALIZE VALID TRANSFER
    // ==========================================
    test('10. finalize valid transfer: verifies full reassembly and hashes',
        () async {
      const tId = 't-finalize-valid';
      final p0 = utf8.encode('First half ');
      final p1 = utf8.encode('Second half');
      final fullBytes = [...p0, ...p1];
      final fullSha = sha256.convert(fullBytes).toString();

      await transport.createTransfer(
        CreateTransferRequest(
          transferId: tId,
          fileName: 'file.txt',
          fileSize: fullBytes.length,
          direction: TransferDirection.upload,
          chunkSize: p0.length,
          totalChunks: 2,
          fileSha256: fullSha,
        ),
      );

      await transport.uploadChunk(
        UploadChunkRequest(
          transferId: tId,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: p0.length,
          sha256: sha256.convert(p0).toString(),
          idempotencyKey: 'k0',
          payload: p0,
        ),
      );

      await transport.uploadChunk(
        UploadChunkRequest(
          transferId: tId,
          chunkIndex: 1,
          byteOffset: p0.length,
          byteLength: p1.length,
          sha256: sha256.convert(p1).toString(),
          idempotencyKey: 'k1',
          payload: p1,
        ),
      );

      final finalizeRes = await transport.finalizeTransfer(
        FinalizeTransferRequest(
          transferId: tId,
          expectedFileSha256: fullSha,
        ),
      );

      expect(finalizeRes.isSuccess, isTrue);
      final finalData = finalizeRes.dataOrNull!;
      expect(finalData.isVerified, isTrue);
      expect(finalData.verifiedBytes, fullBytes.length);
      expect(finalData.actualFileSha256, fullSha);

      // Verify server record is marked finalized
      final serverRecord = server.getTransfer(tId)!;
      expect(serverRecord.isFinalized, isTrue);
    });

    // ==========================================
    // 11. FINAL CHECKSUM MISMATCH
    // ==========================================
    test('11. final checksum mismatch: returns ChecksumRejectionException',
        () async {
      const tId = 't-finalize-mismatch';
      final p = utf8.encode('Single chunk payload');
      final actualSha = sha256.convert(p).toString();

      await transport.createTransfer(
        CreateTransferRequest(
          transferId: tId,
          fileName: 'mismatch.bin',
          fileSize: p.length,
          direction: TransferDirection.upload,
          chunkSize: p.length,
          totalChunks: 1,
          fileSha256: actualSha,
        ),
      );

      await transport.uploadChunk(
        UploadChunkRequest(
          transferId: tId,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: p.length,
          sha256: actualSha,
          idempotencyKey: 'k',
          payload: p,
        ),
      );

      final finalizeRes = await transport.finalizeTransfer(
        const FinalizeTransferRequest(
          transferId: tId,
          expectedFileSha256: 'bogus_final_checksum',
        ),
      );

      expect(finalizeRes.isFailure, isTrue);
      expect(finalizeRes.errorOrNull, isA<ChecksumRejectionException>());
    });

    // ==========================================
    // 12. DOWNLOAD CHUNK
    // ==========================================
    test('12. download chunk: downloads binary chunk and validates headers',
        () async {
      const tId = 't-download-1';
      final fileData = utf8
          .encode('Downloadable test file content split across two chunks.');
      server.seedDownloadTransfer(
        transferId: tId,
        fileName: 'download.txt',
        fileBytes: fileData,
        chunkSize: 25,
      );

      final downloadResult = await transport.downloadChunk(
        DownloadChunkRequest(
          transferId: tId,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: 25,
        ),
      );

      expect(downloadResult.isSuccess, isTrue);
      final chunkData = downloadResult.dataOrNull!;
      expect(chunkData.chunkIndex, 0);
      expect(chunkData.byteOffset, 0);
      expect(chunkData.byteLength, 25);
      expect(chunkData.payload, fileData.sublist(0, 25));
      expect(chunkData.sha256, sha256.convert(chunkData.payload).toString());
    });

    // ==========================================
    // 13. SIMULATED TIMEOUT
    // ==========================================
    test('13. simulated timeout: returns TimeoutTransportException', () async {
      const tId = 't-timeout';
      final shortTimeoutTransport = HttpTransferTransport(
        baseUrl: server.baseUrl,
        timeout: const Duration(milliseconds: 100),
      );

      // Inject 500ms delay on next request
      server.faultInjector.failNextRequest(
        const FaultAction.timeout(Duration(milliseconds: 500)),
      );

      final res = await shortTimeoutTransport.createTransfer(
        CreateTransferRequest(
          transferId: tId,
          fileName: 't.bin',
          fileSize: 10,
          direction: TransferDirection.upload,
          chunkSize: 10,
          totalChunks: 1,
          fileSha256: 'h',
        ),
      );

      expect(res.isFailure, isTrue);
      expect(res.errorOrNull, isA<TimeoutTransportException>());
      expect(res.errorOrNull!.reason, TransportFailureReason.timeout);

      shortTimeoutTransport.close();
    });

    // ==========================================
    // 14. SIMULATED 500
    // ==========================================
    test('14. simulated 500: returns TemporaryServerFailureException',
        () async {
      server.faultInjector.failNextRequest(
        const FaultAction.httpStatus(500, message: 'Database disk full'),
      );

      final res = await transport.getTransferStatus('any-id');
      expect(res.isFailure, isTrue);
      final err = res.errorOrNull!;
      expect(err, isA<TemporaryServerFailureException>());
      expect(err.reason, TransportFailureReason.temporaryServerFailure);
      expect(err.statusCode, 500);
    });

    // ==========================================
    // 15. SIMULATED 429
    // ==========================================
    test('15. simulated 429: returns RateLimitedException', () async {
      server.faultInjector.failNextRequest(
        const FaultAction.httpStatus(429, message: 'Too many requests'),
      );

      final res = await transport.getTransferStatus('any-id');
      expect(res.isFailure, isTrue);
      final err = res.errorOrNull!;
      expect(err, isA<RateLimitedException>());
      expect(err.reason, TransportFailureReason.rateLimited);
      expect(err.statusCode, 429);
    });

    // ==========================================
    // 16, 17, 18. CRITICAL: DROP RESPONSE AFTER PROCESSING + REPLAY
    // ==========================================
    test(
        '16, 17, 18. Drop response after processing: chunk stored -> connection dropped -> retry yields IDEMPOTENT_REPLAY with ZERO duplicate storage',
        () async {
      const tId = 't-drop-after-process';
      const chunkIdx = 0;
      final payload =
          utf8.encode('Critical chunk content that survives dropped response');
      final chunkSha = sha256.convert(payload).toString();
      final idempotencyKey = '$tId:$chunkIdx:$chunkSha';

      // 1. Create transfer on server
      await transport.createTransfer(
        CreateTransferRequest(
          transferId: tId,
          fileName: 'critical.bin',
          fileSize: payload.length,
          direction: TransferDirection.upload,
          chunkSize: payload.length,
          totalChunks: 1,
          fileSha256: chunkSha,
        ),
      );

      // 2. Configure deterministic fault: Drop response after chunk 0 is persisted
      server.faultInjector.dropResponseAfterChunk(
        transferId: tId,
        chunkIndex: chunkIdx,
      );

      // 3. Client attempts upload
      final uploadReq = UploadChunkRequest(
        transferId: tId,
        chunkIndex: chunkIdx,
        byteOffset: 0,
        byteLength: payload.length,
        sha256: chunkSha,
        idempotencyKey: idempotencyKey,
        payload: payload,
      );

      final firstAttempt = await transport.uploadChunk(uploadReq);

      // 4. Client observes transport connection failure because socket was destroyed
      expect(firstAttempt.isFailure, isTrue);
      expect(firstAttempt.errorOrNull, isA<ConnectionFailureException>());

      // 5. CRITICAL INSPECTION: Server MUST have processed and stored the chunk!
      final serverRecord = server.getTransfer(tId)!;
      expect(serverRecord.completedChunksCount, 1);
      expect(serverRecord.chunks[chunkIdx], isNotNull);
      expect(serverRecord.chunks[chunkIdx]!.bytes, payload);
      expect(serverRecord.chunks[chunkIdx]!.sha256, chunkSha);
      expect(serverRecord.completedBytes, payload.length);

      // 6. Client retries with identical request
      final retryAttempt = await transport.uploadChunk(uploadReq);

      // 7. Server detects idempotency key & checksum -> returns IDEMPOTENT_REPLAY
      expect(retryAttempt.isSuccess, isTrue);
      final retryData = retryAttempt.dataOrNull!;
      expect(retryData.status, UploadChunkStatus.idempotentReplay);
      expect(retryData.chunkIndex, chunkIdx);
      expect(retryData.sha256, chunkSha);

      // 8. CRITICAL INVARIANT: Exactly ONE chunk stored, NO duplicate bytes!
      expect(serverRecord.completedChunksCount, 1);
      expect(serverRecord.completedBytes, payload.length);
      expect(serverRecord.chunks.length, 1);
    });

    // ==========================================
    // 19. DETERMINISTIC FAULT INJECTION TARGETING
    // ==========================================
    test(
        '19. deterministic fault injection: targets specific transfer and chunk only',
        () async {
      const t1 = 't-target-1';
      const t2 = 't-target-2';
      final p = [10, 20, 30];
      final sha = sha256.convert(p).toString();

      await transport.createTransfer(
        CreateTransferRequest(
          transferId: t1,
          fileName: 't1.bin',
          fileSize: 3,
          direction: TransferDirection.upload,
          chunkSize: 3,
          totalChunks: 1,
          fileSha256: sha,
        ),
      );

      await transport.createTransfer(
        CreateTransferRequest(
          transferId: t2,
          fileName: 't2.bin',
          fileSize: 3,
          direction: TransferDirection.upload,
          chunkSize: 3,
          totalChunks: 1,
          fileSha256: sha,
        ),
      );

      // Target t1 chunk 0 with 500 error specifically
      server.faultInjector.failChunk(
        transferId: t1,
        chunkIndex: 0,
        action: const FaultAction.httpStatus(500, message: 'Targeted error'),
      );

      // t2 chunk 0 succeeds without interference
      final t2Res = await transport.uploadChunk(
        UploadChunkRequest(
          transferId: t2,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: 3,
          sha256: sha,
          idempotencyKey: '$t2:0:$sha',
          payload: p,
        ),
      );
      expect(t2Res.isSuccess, isTrue);

      // t1 chunk 0 fails as configured
      final t1Res = await transport.uploadChunk(
        UploadChunkRequest(
          transferId: t1,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: 3,
          sha256: sha,
          idempotencyKey: '$t1:0:$sha',
          payload: p,
        ),
      );
      expect(t1Res.isFailure, isTrue);
      expect(t1Res.errorOrNull!.statusCode, 500);
    });

    // ==========================================
    // 20. UPLOAD / DOWNLOAD PROTOCOL SYMMETRY
    // ==========================================
    test(
        '20. upload/download protocol symmetry: same chunk identity across directions',
        () async {
      const uploadId = 'sym-upload';
      const downloadId = 'sym-download';
      final sampleBytes = utf8.encode('Symmetrical wire transfer payload');
      final fullSha = sha256.convert(sampleBytes).toString();

      // 1. Upload direction
      await transport.createTransfer(
        CreateTransferRequest(
          transferId: uploadId,
          fileName: 'sym.bin',
          fileSize: sampleBytes.length,
          direction: TransferDirection.upload,
          chunkSize: sampleBytes.length,
          totalChunks: 1,
          fileSha256: fullSha,
        ),
      );
      final upRes = await transport.uploadChunk(
        UploadChunkRequest(
          transferId: uploadId,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: sampleBytes.length,
          sha256: fullSha,
          idempotencyKey: '$uploadId:0:$fullSha',
          payload: sampleBytes,
        ),
      );
      expect(upRes.isSuccess, isTrue);

      // 2. Download direction
      server.seedDownloadTransfer(
        transferId: downloadId,
        fileName: 'sym.bin',
        fileBytes: sampleBytes,
        chunkSize: sampleBytes.length,
      );
      final downRes = await transport.downloadChunk(
        DownloadChunkRequest(
          transferId: downloadId,
          chunkIndex: 0,
          byteOffset: 0,
          byteLength: sampleBytes.length,
        ),
      );
      expect(downRes.isSuccess, isTrue);

      // Both directions share identical chunk representation & byte payloads
      expect(upRes.dataOrNull!.bytesReceived, downRes.dataOrNull!.byteLength);
      expect(upRes.dataOrNull!.sha256, downRes.dataOrNull!.sha256);
      expect(downRes.dataOrNull!.payload, sampleBytes);
    });
  });
}
