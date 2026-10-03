import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../../domain/transport/transfer_transport.dart';
import '../../../domain/transport/transport_exceptions.dart';
import '../../../domain/transport/transport_models.dart';

/// Concrete HTTP implementation of [TransferTransport].
/// Communicates over standard HTTP wire protocol and translates network responses
/// into typed [TransportResult]s and [TransportException]s.
///
/// NOTE: Deliberately does NOT encode retry policies or orchestration loops.
class HttpTransferTransport implements TransferTransport {
  final Uri baseUrl;
  final http.Client _client;
  final Duration timeout;

  HttpTransferTransport({
    required this.baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  /// Closes the underlying HTTP client connection.
  void close() {
    _client.close();
  }

  @override
  Future<TransportResult<CreateTransferResponse>> createTransfer(
    CreateTransferRequest request,
  ) async {
    final uri = baseUrl.replace(path: '/api/v1/transfers');
    final body = jsonEncode({
      'transferId': request.transferId,
      'fileName': request.fileName,
      'fileSize': request.fileSize,
      'direction': request.direction.name.toUpperCase(),
      'chunkSize': request.chunkSize,
      'totalChunks': request.totalChunks,
      'fileSha256': request.fileSha256,
    });

    try {
      final response = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(timeout);

      if (response.statusCode == HttpStatus.ok ||
          response.statusCode == HttpStatus.created) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return TransportResult.success(
          CreateTransferResponse(
            transferId: json['transferId'] as String,
            status: json['status'] as String,
            chunkSize: json['chunkSize'] as int,
            totalChunks: json['totalChunks'] as int,
            protocolVersion: (json['protocolVersion'] as String?) ?? '1.0',
          ),
        );
      }

      return TransportResult.failure(
        _mapHttpError(
          statusCode: response.statusCode,
          body: response.body,
          transferId: request.transferId,
        ),
      );
    } catch (e) {
      return TransportResult.failure(_mapClientException(e));
    }
  }

  @override
  Future<TransportResult<UploadChunkResponse>> uploadChunk(
    UploadChunkRequest request,
  ) async {
    final uri = baseUrl.replace(
      path:
          '/api/v1/transfers/${request.transferId}/chunks/${request.chunkIndex}',
    );

    final headers = {
      'Content-Type': 'application/octet-stream',
      'X-Idempotency-Key': request.idempotencyKey,
      'X-Chunk-SHA256': request.sha256,
      'X-Byte-Offset': request.byteOffset.toString(),
      'X-Byte-Length': request.byteLength.toString(),
    };

    try {
      final response = await _client
          .put(
            uri,
            headers: headers,
            body: request.payload,
          )
          .timeout(timeout);

      if (response.statusCode == HttpStatus.ok ||
          response.statusCode == HttpStatus.created) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final statusStr = json['status'] as String;
        final uploadStatus = statusStr == 'IDEMPOTENT_REPLAY'
            ? UploadChunkStatus.idempotentReplay
            : UploadChunkStatus.accepted;

        return TransportResult.success(
          UploadChunkResponse(
            transferId: json['transferId'] as String,
            chunkIndex: json['chunkIndex'] as int,
            status: uploadStatus,
            sha256: json['sha256'] as String,
            bytesReceived: json['bytesReceived'] as int,
          ),
        );
      }

      return TransportResult.failure(
        _mapHttpError(
          statusCode: response.statusCode,
          body: response.body,
          transferId: request.transferId,
          chunkIndex: request.chunkIndex,
        ),
      );
    } catch (e) {
      return TransportResult.failure(_mapClientException(e));
    }
  }

  @override
  Future<TransportResult<TransferStatusResponse>> getTransferStatus(
    String transferId,
  ) async {
    final uri = baseUrl.replace(path: '/api/v1/transfers/$transferId');

    try {
      final response = await _client.get(uri).timeout(timeout);

      if (response.statusCode == HttpStatus.ok) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final completedList =
            (json['completedChunkIndexes'] as List<dynamic>?) ?? [];
        return TransportResult.success(
          TransferStatusResponse(
            transferId: json['transferId'] as String,
            serverState: json['serverState'] as String,
            completedChunkIndexes: completedList.cast<int>().toSet(),
            completedBytes: json['completedBytes'] as int,
            totalBytes: json['totalBytes'] as int,
            isFinalized: json['isFinalized'] as bool,
            serverFileSha256: json['serverFileSha256'] as String,
          ),
        );
      }

      return TransportResult.failure(
        _mapHttpError(
          statusCode: response.statusCode,
          body: response.body,
          transferId: transferId,
        ),
      );
    } catch (e) {
      return TransportResult.failure(_mapClientException(e));
    }
  }

  @override
  Future<TransportResult<FinalizeTransferResponse>> finalizeTransfer(
    FinalizeTransferRequest request,
  ) async {
    final uri = baseUrl.replace(
      path: '/api/v1/transfers/${request.transferId}/finalize',
    );
    final body = jsonEncode({
      'expectedFileSha256': request.expectedFileSha256,
    });

    try {
      final response = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(timeout);

      if (response.statusCode == HttpStatus.ok) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return TransportResult.success(
          FinalizeTransferResponse(
            transferId: json['transferId'] as String,
            isVerified: json['isVerified'] as bool,
            verifiedBytes: json['verifiedBytes'] as int,
            actualFileSha256: json['actualFileSha256'] as String,
          ),
        );
      }

      return TransportResult.failure(
        _mapHttpError(
          statusCode: response.statusCode,
          body: response.body,
          transferId: request.transferId,
        ),
      );
    } catch (e) {
      return TransportResult.failure(_mapClientException(e));
    }
  }

  @override
  Future<TransportResult<DownloadChunkResponse>> downloadChunk(
    DownloadChunkRequest request,
  ) async {
    final uri = baseUrl.replace(
      path:
          '/api/v1/transfers/${request.transferId}/chunks/${request.chunkIndex}',
    );

    try {
      final response = await _client.get(uri).timeout(timeout);

      if (response.statusCode == HttpStatus.ok) {
        final payload = response.bodyBytes;
        final serverSha = response.headers['x-chunk-sha256'] ??
            sha256.convert(payload).toString();

        return TransportResult.success(
          DownloadChunkResponse(
            transferId: request.transferId,
            chunkIndex: request.chunkIndex,
            byteOffset: request.byteOffset,
            byteLength: payload.length,
            sha256: serverSha,
            payload: payload,
          ),
        );
      }

      return TransportResult.failure(
        _mapHttpError(
          statusCode: response.statusCode,
          body: response.body,
          transferId: request.transferId,
          chunkIndex: request.chunkIndex,
        ),
      );
    } catch (e) {
      return TransportResult.failure(_mapClientException(e));
    }
  }

  // ==========================================
  // ERROR TRANSLATION
  // ==========================================

  TransportException _mapHttpError({
    required int statusCode,
    required String body,
    String? transferId,
    int? chunkIndex,
  }) {
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>?;
    } catch (_) {}

    final errorCode = json?['error'] as String?;
    final message = (json?['message'] as String?) ??
        'HTTP $statusCode error occurred: $body';

    switch (statusCode) {
      case HttpStatus.notFound:
        return TransferNotFoundException(
          message: message,
          transferId: transferId ?? 'unknown',
          statusCode: statusCode,
        );

      case HttpStatus.conflict:
        if (errorCode == 'IDEMPOTENCY_CONFLICT') {
          return IdempotencyConflictException(
            message: message,
            transferId: transferId ?? 'unknown',
            chunkIndex: chunkIndex ?? 0,
            existingSha256: (json?['existingSha256'] as String?) ?? '',
            attemptedSha256: (json?['attemptedSha256'] as String?) ?? '',
            statusCode: statusCode,
          );
        }
        return ProtocolException(
          message: message,
          statusCode: statusCode,
        );

      case HttpStatus.tooManyRequests:
        return RateLimitedException(
          message: message,
          statusCode: statusCode,
        );

      case HttpStatus.badRequest:
        if (errorCode == 'CHECKSUM_REJECTION') {
          return ChecksumRejectionException(
            message: message,
            expectedSha256: (json?['expectedSha256'] as String?) ?? '',
            actualSha256: (json?['actualSha256'] as String?) ?? '',
            statusCode: statusCode,
          );
        }
        if (errorCode == 'INVALID_CHUNK') {
          return InvalidChunkException(
            message: message,
            chunkIndex: chunkIndex ?? 0,
            statusCode: statusCode,
          );
        }
        return MalformedRequestException(
          message: message,
          statusCode: statusCode,
        );

      case HttpStatus.requestTimeout:
        return TimeoutTransportException(
          message: message,
          statusCode: statusCode,
        );

      default:
        if (statusCode >= 500) {
          return TemporaryServerFailureException(
            message: message,
            statusCode: statusCode,
          );
        }
        return ProtocolException(
          message: message,
          statusCode: statusCode,
        );
    }
  }

  TransportException _mapClientException(Object error) {
    if (error is TimeoutException) {
      return TimeoutTransportException(
        message: 'Client-side request timeout after ${timeout.inSeconds}s.',
        cause: error,
      );
    }
    if (error is SocketException || error is http.ClientException) {
      return ConnectionFailureException(
        message: 'Network connection failure: $error',
        cause: error,
      );
    }
    return ProtocolException(
      message: 'Unexpected transport exception: $error',
      cause: error,
    );
  }
}
