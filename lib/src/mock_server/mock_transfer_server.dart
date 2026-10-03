import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import '../domain/models/enums.dart';
import '../domain/transport/transport_exceptions.dart';
import '../domain/transport/transport_models.dart';
import 'fault_injector.dart';
import 'server_transfer_state.dart';

/// A deterministic, in-memory HTTP server designed for wire protocol and failure-mode testing.
/// Does not depend on any external databases or cloud services.
class MockTransferServer {
  final HttpServer _server;
  final FaultInjector faultInjector = FaultInjector();
  final Map<String, ServerTransferRecord> _transfers = {};

  MockTransferServer._(this._server) {
    _server.listen(_handleHttpRequest);
  }

  /// Starts the mock server bound to an ephemeral port on localhost.
  static Future<MockTransferServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return MockTransferServer._(server);
  }

  /// The root URL of this running mock server.
  Uri get baseUrl =>
      Uri.parse('http://${_server.address.host}:${_server.port}');

  /// Number of active transfers registered in the server.
  int get transferCount => _transfers.length;

  /// Retrieves the in-memory server-side state of a transfer for test assertions.
  ServerTransferRecord? getTransfer(String transferId) =>
      _transfers[transferId];

  /// Seeds a complete file for download testing.
  void seedDownloadTransfer({
    required String transferId,
    required String fileName,
    required List<int> fileBytes,
    required int chunkSize,
  }) {
    final fileSha = sha256.convert(fileBytes).toString();
    final totalChunks = (fileBytes.length + chunkSize - 1) ~/ chunkSize;
    final record = ServerTransferRecord(
      transferId: transferId,
      fileName: fileName,
      fileSize: fileBytes.length,
      direction: TransferDirection.download,
      chunkSize: chunkSize,
      totalChunks: totalChunks == 0 ? 1 : totalChunks,
      expectedFileSha256: fileSha,
      createdAt: DateTime.now().toUtc(),
      isFinalized: true,
    );

    if (fileBytes.isEmpty) {
      record.addOrValidateChunk(
        chunkIndex: 0,
        byteOffset: 0,
        byteLength: 0,
        declaredSha256: sha256.convert([]).toString(),
        idempotencyKey: '$transferId:0:empty',
        payload: [],
      );
    } else {
      for (int i = 0; i < totalChunks; i++) {
        final offset = i * chunkSize;
        final end = (offset + chunkSize > fileBytes.length)
            ? fileBytes.length
            : offset + chunkSize;
        final chunkBytes = fileBytes.sublist(offset, end);
        final chunkSha = sha256.convert(chunkBytes).toString();
        record.addOrValidateChunk(
          chunkIndex: i,
          byteOffset: offset,
          byteLength: chunkBytes.length,
          declaredSha256: chunkSha,
          idempotencyKey: '$transferId:$i:$chunkSha',
          payload: chunkBytes,
        );
      }
    }

    _transfers[transferId] = record;
  }

  /// Closes the server and releases the port.
  Future<void> stop() async {
    await _server.close(force: true);
  }

  // ==========================================
  // REQUEST ROUTER & HANDLERS
  // ==========================================

  Future<void> _handleHttpRequest(HttpRequest request) async {
    final pathSegments = request.uri.pathSegments;

    // Pattern: /api/v1/transfers...
    if (pathSegments.length < 3 ||
        pathSegments[0] != 'api' ||
        pathSegments[1] != 'v1' ||
        pathSegments[2] != 'transfers') {
      _sendJson(request.response, HttpStatus.notFound, {
        'error': 'ENDPOINT_NOT_FOUND',
        'message': 'Resource ${request.uri.path} not found',
      });
      return;
    }

    try {
      if (pathSegments.length == 3) {
        // POST /api/v1/transfers
        if (request.method == 'POST') {
          await _handleCreateTransfer(request);
          return;
        }
      } else if (pathSegments.length == 4) {
        final transferId = pathSegments[3];
        // GET /api/v1/transfers/{id}
        if (request.method == 'GET') {
          await _handleGetTransferStatus(request, transferId);
          return;
        }
      } else if (pathSegments.length == 5) {
        final transferId = pathSegments[3];
        final subResource = pathSegments[4];

        // POST /api/v1/transfers/{id}/finalize
        if (subResource == 'finalize' && request.method == 'POST') {
          await _handleFinalizeTransfer(request, transferId);
          return;
        }
      } else if (pathSegments.length == 6) {
        final transferId = pathSegments[3];
        final subResource = pathSegments[4];
        final chunkIndexStr = pathSegments[5];
        final chunkIndex = int.tryParse(chunkIndexStr);

        if (subResource == 'chunks' && chunkIndex != null) {
          // PUT /api/v1/transfers/{id}/chunks/{index}
          if (request.method == 'PUT') {
            await _handleUploadChunk(request, transferId, chunkIndex);
            return;
          }
          // GET /api/v1/transfers/{id}/chunks/{index}
          if (request.method == 'GET') {
            await _handleDownloadChunk(request, transferId, chunkIndex);
            return;
          }
        }
      }

      _sendJson(request.response, HttpStatus.methodNotAllowed, {
        'error': 'METHOD_NOT_ALLOWED',
        'message': '${request.method} not allowed for ${request.uri.path}',
      });
    } catch (e, stack) {
      if (request.response.connectionInfo != null) {
        _sendJson(request.response, HttpStatus.internalServerError, {
          'error': 'INTERNAL_SERVER_ERROR',
          'message': e.toString(),
          'stack': stack.toString(),
        });
      }
    }
  }

  // --- Handlers ---

  Future<void> _handleCreateTransfer(HttpRequest request) async {
    final fault = faultInjector.consumeFault();
    if (await _evaluatePreProcessingFault(request, fault)) return;

    final bodyStr = await utf8.decodeStream(request);
    final json = jsonDecode(bodyStr) as Map<String, dynamic>;

    final transferId = json['transferId'] as String;
    final fileName = json['fileName'] as String;
    final fileSize = json['fileSize'] as int;
    final directionStr = json['direction'] as String;
    final chunkSize = json['chunkSize'] as int;
    final totalChunks = json['totalChunks'] as int;
    final fileSha256 = json['fileSha256'] as String;

    // Idempotent creation: return existing if matches
    final existing = _transfers[transferId];
    if (existing != null) {
      _sendJson(request.response, HttpStatus.ok, {
        'transferId': existing.transferId,
        'status': existing.isFinalized ? 'COMPLETED' : 'TRANSFERRING',
        'chunkSize': existing.chunkSize,
        'totalChunks': existing.totalChunks,
        'protocolVersion': '1.0',
      });
      return;
    }

    final record = ServerTransferRecord(
      transferId: transferId,
      fileName: fileName,
      fileSize: fileSize,
      direction: TransferDirection.fromString(directionStr),
      chunkSize: chunkSize,
      totalChunks: totalChunks,
      expectedFileSha256: fileSha256,
      createdAt: DateTime.now().toUtc(),
    );

    _transfers[transferId] = record;

    _sendJson(request.response, HttpStatus.created, {
      'transferId': transferId,
      'status': 'CREATED',
      'chunkSize': chunkSize,
      'totalChunks': totalChunks,
      'protocolVersion': '1.0',
    });
  }

  Future<void> _handleUploadChunk(
    HttpRequest request,
    String transferId,
    int chunkIndex,
  ) async {
    final transfer = _transfers[transferId];
    if (transfer == null) {
      _sendJson(request.response, HttpStatus.notFound, {
        'error': 'TRANSFER_NOT_FOUND',
        'message': 'Transfer "$transferId" does not exist.',
      });
      return;
    }

    final fault = faultInjector.consumeFault(
      transferId: transferId,
      chunkIndex: chunkIndex,
    );

    // Evaluate pre-processing faults (e.g. drop connection before parsing, timeout, 500, 429)
    if (await _evaluatePreProcessingFault(request, fault)) return;

    final idempotencyKey = request.headers.value('X-Idempotency-Key') ?? '';
    final declaredSha256 = request.headers.value('X-Chunk-SHA256') ?? '';
    final byteOffsetStr = request.headers.value('X-Byte-Offset') ?? '0';
    final byteLengthStr = request.headers.value('X-Byte-Length') ?? '0';

    final byteOffset = int.tryParse(byteOffsetStr) ?? 0;
    final byteLength = int.tryParse(byteLengthStr) ?? 0;

    final bytes = await request.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (bb, data) => bb..add(data),
    );
    final payload = bytes.takeBytes();

    // Perform server-side validation and storage
    try {
      final status = transfer.addOrValidateChunk(
        chunkIndex: chunkIndex,
        byteOffset: byteOffset,
        byteLength: byteLength,
        declaredSha256: declaredSha256,
        idempotencyKey: idempotencyKey,
        payload: payload,
      );

      // Handle the critical DROP RESPONSE AFTER PROCESSING fault:
      // The chunk is already saved to the transfer, but socket is destroyed before replying!
      if (fault is DropResponseAfterProcessingFault) {
        final socket = await request.response.detachSocket();
        socket.destroy();
        return;
      }

      final httpStatus = status == UploadChunkStatus.accepted
          ? HttpStatus.created
          : HttpStatus.ok;

      _sendJson(request.response, httpStatus, {
        'transferId': transferId,
        'chunkIndex': chunkIndex,
        'status': status == UploadChunkStatus.accepted
            ? 'ACCEPTED'
            : 'IDEMPOTENT_REPLAY',
        'sha256': declaredSha256,
        'bytesReceived': payload.length,
      });
    } on ChecksumRejectionException catch (e) {
      _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'CHECKSUM_REJECTION',
        'message': e.message,
        'expectedSha256': e.expectedSha256,
        'actualSha256': e.actualSha256,
      });
    } on IdempotencyConflictException catch (e) {
      _sendJson(request.response, HttpStatus.conflict, {
        'error': 'IDEMPOTENCY_CONFLICT',
        'message': e.message,
        'transferId': e.transferId,
        'chunkIndex': e.chunkIndex,
        'existingSha256': e.existingSha256,
        'attemptedSha256': e.attemptedSha256,
      });
    } on InvalidChunkException catch (e) {
      _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'INVALID_CHUNK',
        'message': e.message,
        'chunkIndex': e.chunkIndex,
      });
    } on MalformedRequestException catch (e) {
      _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'MALFORMED_REQUEST',
        'message': e.message,
      });
    }
  }

  Future<void> _handleGetTransferStatus(
    HttpRequest request,
    String transferId,
  ) async {
    final fault = faultInjector.consumeFault(transferId: transferId);
    if (await _evaluatePreProcessingFault(request, fault)) return;

    final transfer = _transfers[transferId];
    if (transfer == null) {
      _sendJson(request.response, HttpStatus.notFound, {
        'error': 'TRANSFER_NOT_FOUND',
        'message': 'Transfer "$transferId" does not exist.',
      });
      return;
    }

    _sendJson(request.response, HttpStatus.ok, {
      'transferId': transferId,
      'serverState': transfer.isFinalized
          ? 'COMPLETED'
          : (transfer.completedChunksCount > 0 ? 'TRANSFERRING' : 'QUEUED'),
      'completedChunkIndexes': transfer.chunks.keys.toList(),
      'completedBytes': transfer.completedBytes,
      'totalBytes': transfer.fileSize,
      'isFinalized': transfer.isFinalized,
      'serverFileSha256': transfer.expectedFileSha256,
    });
  }

  Future<void> _handleFinalizeTransfer(
    HttpRequest request,
    String transferId,
  ) async {
    final fault = faultInjector.consumeFault(transferId: transferId);
    if (await _evaluatePreProcessingFault(request, fault)) return;

    final transfer = _transfers[transferId];
    if (transfer == null) {
      _sendJson(request.response, HttpStatus.notFound, {
        'error': 'TRANSFER_NOT_FOUND',
        'message': 'Transfer "$transferId" does not exist.',
      });
      return;
    }

    final bodyStr = await utf8.decodeStream(request);
    final json = jsonDecode(bodyStr) as Map<String, dynamic>;
    final expectedSha256 = json['expectedFileSha256'] as String;

    try {
      final res = transfer.finalizeTransfer(expectedSha256);
      _sendJson(request.response, HttpStatus.ok, {
        'transferId': res.transferId,
        'isVerified': res.isVerified,
        'verifiedBytes': res.verifiedBytes,
        'actualFileSha256': res.actualFileSha256,
      });
    } on ChecksumRejectionException catch (e) {
      _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'CHECKSUM_REJECTION',
        'message': e.message,
        'expectedSha256': e.expectedSha256,
        'actualSha256': e.actualSha256,
      });
    } on MalformedRequestException catch (e) {
      _sendJson(request.response, HttpStatus.badRequest, {
        'error': 'INCOMPLETE_TRANSFER',
        'message': e.message,
      });
    }
  }

  Future<void> _handleDownloadChunk(
    HttpRequest request,
    String transferId,
    int chunkIndex,
  ) async {
    final fault = faultInjector.consumeFault(
      transferId: transferId,
      chunkIndex: chunkIndex,
    );
    if (await _evaluatePreProcessingFault(request, fault)) return;

    final transfer = _transfers[transferId];
    if (transfer == null) {
      _sendJson(request.response, HttpStatus.notFound, {
        'error': 'TRANSFER_NOT_FOUND',
        'message': 'Transfer "$transferId" does not exist.',
      });
      return;
    }

    final chunk = transfer.chunks[chunkIndex];
    if (chunk == null) {
      _sendJson(request.response, HttpStatus.notFound, {
        'error': 'CHUNK_NOT_FOUND',
        'message': 'Chunk $chunkIndex does not exist on server.',
      });
      return;
    }

    request.response.headers
      ..set('X-Chunk-SHA256', chunk.sha256)
      ..set('X-Byte-Offset', chunk.byteOffset.toString())
      ..set('X-Byte-Length', chunk.byteLength.toString())
      ..contentType = ContentType.binary;

    request.response.add(chunk.bytes);
    await request.response.close();
  }

  // --- Helper Methods ---

  Future<bool> _evaluatePreProcessingFault(
    HttpRequest request,
    FaultAction? fault,
  ) async {
    if (fault == null) return false;

    if (fault is DropConnectionBeforeProcessingFault) {
      final socket = await request.response.detachSocket();
      socket.destroy();
      return true;
    }

    if (fault is TimeoutFault) {
      await Future.delayed(fault.delay);
      return false; // Continues after delay (causing client timeout if delay exceeds limit)
    }

    if (fault is HttpStatusFault) {
      _sendJson(request.response, fault.statusCode, {
        'error': fault.statusCode == 429
            ? 'RATE_LIMITED'
            : (fault.statusCode >= 500
                ? 'TEMPORARY_SERVER_FAILURE'
                : 'SERVER_ERROR'),
        'message': fault.message,
      });
      return true;
    }

    return false;
  }

  void _sendJson(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> body,
  ) {
    response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body))
      ..close();
  }
}
