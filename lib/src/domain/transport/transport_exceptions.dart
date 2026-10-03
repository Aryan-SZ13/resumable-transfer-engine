import 'package:meta/meta.dart';

/// Categorical reasons for a transport-level network or protocol failure.
/// Reports what occurred over the transport layer without encoding retry policies.
enum TransportFailureReason {
  /// Physical network connection could not be established or was aborted unexpectedly.
  connectionFailure,

  /// Request or socket timed out waiting for server response.
  timeout,

  /// Server indicated client rate limits were exceeded (e.g. HTTP 429).
  rateLimited,

  /// Server experienced a temporary unrecoverable error (e.g. HTTP 5xx).
  temporaryServerFailure,

  /// The request was rejected due to invalid syntax or format (e.g. HTTP 400).
  malformedRequest,

  /// Server rejected the transmitted chunk because calculated SHA-256 did not match declared hash.
  checksumRejection,

  /// The target transfer session does not exist on the server (e.g. HTTP 404).
  transferNotFound,

  /// Chunk upload conflicted with an already-persisted chunk having a different checksum (HTTP 409).
  idempotencyConflict,

  /// Chunk boundaries (offset, index, length) violated the transfer manifest.
  invalidChunk,

  /// Server returned an unparseable or unexpected response body/status.
  protocolError,
}

/// Base exception class for all transport layer failures.
@immutable
abstract class TransportException implements Exception {
  final String message;
  final TransportFailureReason reason;
  final int? statusCode;
  final Object? cause;

  const TransportException({
    required this.message,
    required this.reason,
    this.statusCode,
    this.cause,
  });

  @override
  String toString() =>
      'TransportException($reason, status: $statusCode): $message${cause != null ? ' (Cause: $cause)' : ''}';
}

/// Thrown when connection establishment fails or socket is broken.
class ConnectionFailureException extends TransportException {
  const ConnectionFailureException({
    required super.message,
    super.statusCode,
    super.cause,
  }) : super(reason: TransportFailureReason.connectionFailure);
}

/// Thrown when a request or response read times out.
class TimeoutTransportException extends TransportException {
  const TimeoutTransportException({
    required super.message,
    super.statusCode,
    super.cause,
  }) : super(reason: TransportFailureReason.timeout);
}

/// Thrown when the server rate limits the client (e.g. HTTP 429).
class RateLimitedException extends TransportException {
  final Duration? retryAfter;

  const RateLimitedException({
    required super.message,
    super.statusCode = 429,
    this.retryAfter,
    super.cause,
  }) : super(reason: TransportFailureReason.rateLimited);
}

/// Thrown when the server returns a 5xx error.
class TemporaryServerFailureException extends TransportException {
  const TemporaryServerFailureException({
    required super.message,
    super.statusCode = 500,
    super.cause,
  }) : super(reason: TransportFailureReason.temporaryServerFailure);
}

/// Thrown when the request is syntactically invalid (e.g. HTTP 400).
class MalformedRequestException extends TransportException {
  const MalformedRequestException({
    required super.message,
    super.statusCode = 400,
    super.cause,
  }) : super(reason: TransportFailureReason.malformedRequest);
}

/// Thrown when the server rejects a payload because its SHA-256 does not match.
class ChecksumRejectionException extends TransportException {
  final String expectedSha256;
  final String actualSha256;

  const ChecksumRejectionException({
    required super.message,
    required this.expectedSha256,
    required this.actualSha256,
    super.statusCode = 400,
    super.cause,
  }) : super(reason: TransportFailureReason.checksumRejection);
}

/// Thrown when the requested transfer does not exist on the remote server (HTTP 404).
class TransferNotFoundException extends TransportException {
  final String transferId;

  const TransferNotFoundException({
    required super.message,
    required this.transferId,
    super.statusCode = 404,
    super.cause,
  }) : super(reason: TransportFailureReason.transferNotFound);
}

/// Thrown when a chunk upload conflicts with an already persisted chunk with a different checksum (HTTP 409).
class IdempotencyConflictException extends TransportException {
  final String transferId;
  final int chunkIndex;
  final String existingSha256;
  final String attemptedSha256;

  const IdempotencyConflictException({
    required super.message,
    required this.transferId,
    required this.chunkIndex,
    required this.existingSha256,
    required this.attemptedSha256,
    super.statusCode = 409,
    super.cause,
  }) : super(reason: TransportFailureReason.idempotencyConflict);
}

/// Thrown when a chunk's index, offset, or length is outside acceptable bounds.
class InvalidChunkException extends TransportException {
  final int chunkIndex;

  const InvalidChunkException({
    required super.message,
    required this.chunkIndex,
    super.statusCode = 400,
    super.cause,
  }) : super(reason: TransportFailureReason.invalidChunk);
}

/// Thrown when the response structure or status code is not recognized by the protocol.
class ProtocolException extends TransportException {
  const ProtocolException({
    required super.message,
    super.statusCode,
    super.cause,
  }) : super(reason: TransportFailureReason.protocolError);
}
